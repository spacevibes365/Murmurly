import AppKit
import AVFoundation
import Combine
import Darwin
import Foundation
import XCTest
@testable import Murmurly

private actor SlowMic: MicCapturing {
    private(set) var starts = 0
    private(set) var stops = 0

    func start() async throws {
        starts += 1
        usleep(starts == 1 ? 150_000 : 10_000)
    }

    func stop() async throws -> URL? {
        stops += 1
        return nil
    }

    func startCount() -> Int { starts }
}

private actor FailingStartMic: MicCapturing {
    enum Failure: Error { case refused }

    func start() async throws { throw Failure.refused }
    func stop() async throws -> URL? { nil }
}

private actor ImmediateMic: MicCapturing {
    func start() async throws {}
    func stop() async throws -> URL? { nil }
}

/// A value a test changes while a closure reads it.
@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor
private final class FeedbackProbe {
    var names: [String] = []
    var beeps = 0

    func play(_ name: NSSound.Name) { names.append(name) }
    func beep() { beeps += 1 }
}

@MainActor
final class PermissionsAndSettingsTests: XCTestCase {
    func testSettingsStoreDefaultsOnEmptySuite() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.EmptySettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.dictationLanguage, "auto")
        XCTAssertEqual(store.dictationEngine, .parakeet)
        XCTAssertEqual(store.snapshot.whisperModelPath, SettingsStore.defaultWhisperModel)
        XCTAssertEqual(store.snapshot.parakeetModelPath, SettingsStore.defaultParakeetModel)
        XCTAssertFalse(store.saveDictationAudio)
        XCTAssertTrue(store.launchAtLogin)
        XCTAssertEqual(store.settingsTab, .dictation)
        XCTAssertEqual(store.hotkeyActivation, .press)
        XCTAssertEqual(store.doubleTapModifier, .rightCommand)
        XCTAssertEqual(store.doubleTapThresholdMS, 250)
        XCTAssertTrue(store.soundOnRecordingStart)
        XCTAssertTrue(store.soundOnInsert)
        XCTAssertTrue(store.overlayEnabled)
        XCTAssertNil(store.overlayPlacement)
        XCTAssertTrue(store.autoRecordMeetings)
        XCTAssertEqual(store.meetingExcludedBundleIDs, [])
        XCTAssertNil(store.systemAudioCheck)
    }

    func testDictationEnginePersistsAndUnknownValueFallsBackToParakeet() throws {
        let name = "io.github.spacevibes365.MurmurlyTests.Engine.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SettingsStore(defaults: defaults)
        store.dictationEngine = .whisper
        XCTAssertEqual(SettingsStore(defaults: defaults).dictationEngine, .whisper)
        defaults.set("future", forKey: "dictation.engine")
        XCTAssertEqual(SettingsStore(defaults: defaults).dictationEngine, .parakeet)
    }

    func testCoordinatorObservesNewEngineDescriptorFromPublishedValues() throws {
        let name = "io.github.spacevibes365.MurmurlyTests.EngineObservation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        let coordinator = DictationCoordinator(
            mic: ImmediateMic(),
            indicator: RecordingIndicator(renderingEnabled: false),
            hotkeyManager: HotkeyManager(installsSystemHandlers: false)
        )
        coordinator.activate(
            settings: settings,
            permissions: PermissionManager(runningTests: true)
        )

        settings.dictationEngine = .whisper

        XCTAssertEqual(
            coordinator.selectedDescriptorForTesting,
            EngineDescriptor(engine: .whisper, modelPath: SettingsStore.defaultWhisperModel)
        )
    }

    /// The junction "string catalog → app bundle → shown count": the catalog
    /// is built into the app with the English base and the Russian
    /// translation, and each picks its plural form; a big count keeps the
    /// locale's digit grouping.
    func testPluralFormsComeFromTheCatalogInEnglishAndRussian() throws {
        func recordings(_ count: Int, bundle: Bundle = .main, locale: Locale) -> String {
            String(localized: "\(count) recordings", bundle: bundle, locale: locale)
        }
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(recordings(1, locale: english), "1 recording")
        XCTAssertEqual(recordings(2, locale: english), "2 recordings")
        XCTAssertEqual(recordings(8_431, locale: english), "8,431 recordings")

        let path = try XCTUnwrap(Bundle.main.path(forResource: "ru", ofType: "lproj"), "no Russian in the app")
        let russianBundle = try XCTUnwrap(Bundle(path: path))
        let russian = Locale(identifier: "ru_RU")
        let cases: [(Int, String)] = [
            (0, "записей"), (1, "запись"), (2, "записи"), (4, "записи"), (5, "записей"),
            (11, "записей"), (12, "записей"), (14, "записей"), (21, "запись"), (22, "записи"),
            (25, "записей"), (101, "запись"), (111, "записей"), (1_000, "записей"), (8_431, "запись"),
        ]
        for (count, form) in cases {
            XCTAssertEqual(
                recordings(count, bundle: russianBundle, locale: russian),
                "\(count.formatted(.number.locale(russian))) \(form)"
            )
        }
        XCTAssertNotEqual(8_431.formatted(.number.locale(russian)), "8431", "the count lost its grouping")
    }

    /// The count of pieces a transcription missed, in the forms of each
    /// language that has them: 1, 2, 5 and 21 tell them all apart.
    /// The deletion and audio-rule questions count meetings and days in each
    /// language's own forms.
    func testDeletionQuestionsTakeEachLanguagesPluralForms() throws {
        func bundle(_ language: String) throws -> Bundle {
            language == "en" ? Bundle.main : try XCTUnwrap(
                Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)), "no \(language)"
            )
        }
        func move(_ count: Int, _ language: String) throws -> String {
            String(localized: "Move \(count) meetings to the Trash?", bundle: try bundle(language), locale: Locale(identifier: language))
        }
        func days(_ count: Int, _ language: String) throws -> String {
            String(localized: "Counting what goes after \(count) days…", bundle: try bundle(language), locale: Locale(identifier: language))
        }
        XCTAssertEqual(try move(1, "en"), "Move 1 meeting to the Trash?")
        XCTAssertEqual(try move(2, "en"), "Move 2 meetings to the Trash?")
        XCTAssertEqual(try move(1, "ru"), "Переместить в Корзину 1 созвон?")
        XCTAssertEqual(try move(3, "ru"), "Переместить в Корзину 3 созвона?")
        XCTAssertEqual(try move(5, "ru"), "Переместить в Корзину 5 созвонов?")
        XCTAssertEqual(try move(21, "ru"), "Переместить в Корзину 21 созвон?")
        XCTAssertEqual(try move(2, "pl"), "Przenieść do Kosza 2 spotkania?")
        XCTAssertEqual(try move(5, "pl"), "Przenieść do Kosza 5 spotkań?")
        XCTAssertEqual(try days(7, "en"), "Counting what goes after 7 days…")
        XCTAssertEqual(try days(30, "ru"), "Считаем, что удалится через 30 дней…")
        XCTAssertEqual(try days(90, "uk"), "Рахуємо, що видалиться через 90 днів…")
    }

    func testMissedPiecesTakeEachLanguagesPluralForms() throws {
        func missed(_ count: Int, _ language: String) throws -> String {
            let bundle = language == "en" ? Bundle.main : try XCTUnwrap(
                Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)), "no \(language)"
            )
            return String(
                localized: "\(count) pieces of the last transcription weren’t recognized.",
                bundle: bundle, locale: Locale(identifier: language)
            )
        }
        let expected: [String: [Int: String]] = [
            "en": [1: "1 piece of the last transcription wasn’t recognized.",
                   2: "2 pieces of the last transcription weren’t recognized.",
                   21: "21 pieces of the last transcription weren’t recognized."],
            "ru": [1: "В последней расшифровке не распознан 1 кусок.",
                   2: "В последней расшифровке не распознаны 2 куска.",
                   5: "В последней расшифровке не распознано 5 кусков.",
                   21: "В последней расшифровке не распознан 21 кусок."],
            "uk": [1: "В останній розшифровці не розпізнано 1 фрагмент.",
                   2: "В останній розшифровці не розпізнано 2 фрагменти.",
                   5: "В останній розшифровці не розпізнано 5 фрагментів.",
                   21: "В останній розшифровці не розпізнано 21 фрагмент."],
            "pl": [1: "W ostatniej transkrypcji nie rozpoznano 1 fragmentu.",
                   2: "W ostatniej transkrypcji nie rozpoznano 2 fragmentów.",
                   5: "W ostatniej transkrypcji nie rozpoznano 5 fragmentów."],
            "de": [1: "Im letzten Transkript wurde 1 Abschnitt nicht erkannt.",
                   2: "Im letzten Transkript wurden 2 Abschnitte nicht erkannt."],
        ]
        for (language, forms) in expected {
            for (count, text) in forms {
                XCTAssertEqual(try missed(count, language), text, "\(language), \(count)")
            }
        }
    }

    func testUnknownSettingsTabFallsBackToDictation() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.SettingsTab.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("unknown", forKey: "ui.settingsTab")

        XCTAssertEqual(SettingsStore(defaults: defaults).settingsTab, .dictation)
    }

    /// History, Dictionary and Files left Settings for the main window: a
    /// tab of theirs stored by an earlier version reads as the default, and
    /// reading does not write the key.
    func testOldSettingsTabsFallBackToDictation() throws {
        for old in ["history", "dictionary", "files"] {
            let suiteName = "io.github.spacevibes365.MurmurlyTests.SettingsTab.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(old, forKey: "ui.settingsTab")

            XCTAssertEqual(SettingsStore(defaults: defaults).settingsTab, .dictation, old)
            XCTAssertEqual(defaults.string(forKey: "ui.settingsTab"), old, "reading \(old) wrote the key")
        }
    }

    func testAppearanceDefaultsToSystemWithoutWritingAndPersists() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.Appearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.appearance, .system)
        XCTAssertNil(defaults.object(forKey: "ui.appearance"), "the default was written")
        store.appearance = .dark
        XCTAssertEqual(SettingsStore(defaults: defaults).appearance, .dark)
        store.appearance = .light
        XCTAssertEqual(SettingsStore(defaults: defaults).appearance, .light)
        defaults.set("sepia", forKey: "ui.appearance")
        XCTAssertEqual(SettingsStore(defaults: defaults).appearance, .system)
    }

    /// The setting reaches the whole app: a choice stored before launch is
    /// applied as soon as the delegate follows it, then every change, and
    /// System hands the look back to macOS.
    func testAppearanceSettingDrivesTheApplicationAppearance() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.AppearanceApplied.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // The test host is the app itself: its own look comes back afterwards.
        let original = NSApp.appearance
        defer { NSApp.appearance = original }
        NSApp.appearance = nil
        defaults.set("dark", forKey: "ui.appearance")
        let settings = SettingsStore(defaults: defaults)
        let delegate = AppDelegate()

        delegate.followAppearance(of: settings)
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua, "the stored choice was not applied")
        settings.appearance = .light
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        settings.appearance = .dark
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        settings.appearance = .system
        XCTAssertNil(NSApp.appearance, "System kept an explicit look")
        // The subscription lives as long as the delegate.
        withExtendedLifetime(delegate) {}
    }

    func testUnknownHotkeyActivationFallsBackToPress() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.HotkeyActivation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("unknown", forKey: "dictation.hotkey.activation")

        XCTAssertEqual(SettingsStore(defaults: defaults).hotkeyActivation, .press)
    }

    func testStoredHoldActivationReadsAsHold() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.StoredHoldActivation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("hold", forKey: "dictation.hotkey.activation")

        XCTAssertEqual(SettingsStore(defaults: defaults).hotkeyActivation, .hold)
    }

    func testMeetingExclusionsHaveNoPersonalSeeds() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.MeetingExclusionSeed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            SettingsStore(defaults: defaults).meetingExcludedBundleIDs,
            []
        )
        XCTAssertFalse(
            SettingsStore(defaults: defaults).meetingExcludedBundleIDs.contains("io.github.spacevibes365.Murmurly")
        )
    }

    /// The menu's "Exclude … from Auto-Recording" and the exclusion list name
    /// an app; a part of macOS without an app says so instead of a bare ID.
    func testExclusionNameIsAnAppOrSaysItIsPartOfMacOS() {
        XCTAssertEqual(MeetingsSettingsView.applicationName("com.apple.finder"), "Finder")
        XCTAssertEqual(
            MeetingsSettingsView.applicationName("com.apple.avconferenced"),
            "macOS process com.apple.avconferenced"
        )
        XCTAssertEqual(
            MeetingsSettingsView.applicationName("com.example.no-such-helper"),
            "com.example.no-such-helper"
        )
    }

    func testEmptyMeetingExclusionsStayEmpty() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.MeetingExclusionEmpty.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        store.meetingExcludedBundleIDs = []

        XCTAssertTrue(SettingsStore(defaults: defaults).meetingExcludedBundleIDs.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: "meeting.excludedBundleIDs"), [])
    }

    func testGettingStartedConsumesMissingPreferenceBeforeShowing() throws {
        let name = "io.github.spacevibes365.MurmurlyTests.GettingStarted.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "meeting.autoRecord"))
        XCTAssertTrue(settings.prepareGettingStarted(isTestProcess: false))
        XCTAssertEqual(defaults.object(forKey: "meeting.autoRecord") as? Bool, true)
        XCTAssertFalse(settings.prepareGettingStarted(isTestProcess: false))
        XCTAssertFalse(SettingsStore(defaults: defaults).prepareGettingStarted(isTestProcess: false))
        settings.autoRecordMeetings = false
        XCTAssertFalse(settings.prepareGettingStarted(isTestProcess: false))
        XCTAssertFalse(defaults.bool(forKey: "meeting.autoRecord"))
    }

    func testTestProcessNeverShowsGettingStartedAndAudioPreferencePersists() throws {
        let name = "io.github.spacevibes365.MurmurlyTests.GettingStartedTestProcess.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.prepareGettingStarted(isTestProcess: true))
        // The stage gate is a test process on the live domain: writing the key
        // there would hide the first-run window from the installed copy.
        XCTAssertNil(defaults.object(forKey: "meeting.autoRecord"))
        XCTAssertFalse(settings.saveDictationAudio)
        settings.saveDictationAudio = true
        XCTAssertTrue(SettingsStore(defaults: defaults).saveDictationAudio)
    }

    func testDoubleTapThresholdIsClampedWithoutRounding() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.DoubleTapThreshold.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(Int.min, forKey: "dictation.hotkey.doubleThresholdMS")
        XCTAssertEqual(SettingsStore(defaults: defaults).doubleTapThresholdMS, 150)
        defaults.set(Int.max, forKey: "dictation.hotkey.doubleThresholdMS")
        XCTAssertEqual(SettingsStore(defaults: defaults).doubleTapThresholdMS, 500)

        let store = SettingsStore(defaults: defaults)
        store.doubleTapThresholdMS = 263
        XCTAssertEqual(store.doubleTapThresholdMS, 263)
        store.doubleTapThresholdMS = 501
        XCTAssertEqual(store.doubleTapThresholdMS, 500)
    }

    func testOverlayPlacementRoundTripAndCorruptDataFallback() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.OverlayPlacement.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let placement = OverlayPlacement(displayID: 42, fractionX: 0.25, fractionY: 0.75)

        let store = SettingsStore(defaults: defaults)
        store.overlayPlacement = placement
        XCTAssertEqual(SettingsStore(defaults: defaults).overlayPlacement, placement)

        defaults.set(Data("not-json".utf8), forKey: "overlay.placement")
        XCTAssertNil(SettingsStore(defaults: defaults).overlayPlacement)
    }

    /// A poll that finds nothing new publishes nothing: the menu bar's menu
    /// observes the permissions and was redrawn every 3 s, open or not.
    func testAPollThatFindsNothingNewPublishesNothing() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionPoll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = folder.appendingPathComponent("settings").path
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let trusted = Box(false)
        let manager = PermissionManager(
            accessibilityStatus: { trusted.value },
            runningTests: true,
            defaults: defaults,
            version: "1"
        )
        var changes = 0
        let watch = manager.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }

        manager.refresh()
        XCTAssertEqual(changes, 0, "a poll that found nothing new published a change")

        trusted.value = true
        manager.refresh()
        XCTAssertGreaterThan(changes, 0, "a change of the grant was not published")
        XCTAssertTrue(manager.axTrusted)
    }

    /// The launch prompt for Accessibility: never on the first launch, once
    /// on the first launch of a new version without the grant, never in a
    /// test process; a button always asks.
    func testAccessibilityLaunchPromptOncePerNewVersionWithoutGrant() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionPrompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = folder.appendingPathComponent("settings").path
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = PermissionManager.promptedVersionKey
        var prompts = 0
        func launch(version: String, trusted: Bool, testing: Bool = false) -> PermissionManager {
            let manager = PermissionManager(
                accessibilityStatus: { trusted },
                accessibilityPrompt: {
                    prompts += 1
                    return trusted
                },
                runningTests: testing,
                defaults: defaults,
                version: version
            )
            manager.activate()
            return manager
        }

        _ = launch(version: "7", trusted: false, testing: true)
        XCTAssertEqual(prompts, 0)
        XCTAssertNil(defaults.object(forKey: key), "a test process writes nothing")

        _ = launch(version: "7", trusted: false)
        XCTAssertEqual(prompts, 0, "the first launch does not ask")
        XCTAssertEqual(defaults.string(forKey: key), "7")

        _ = launch(version: "7", trusted: false)
        XCTAssertEqual(prompts, 0, "the same version does not ask again")

        let updated = launch(version: "8", trusted: false)
        XCTAssertEqual(prompts, 1, "a new version without the grant asks once")
        XCTAssertEqual(defaults.string(forKey: key), "8")
        updated.activate()
        XCTAssertEqual(prompts, 1)
        _ = launch(version: "8", trusted: false)
        XCTAssertEqual(prompts, 1)

        _ = launch(version: "9", trusted: true)
        XCTAssertEqual(prompts, 1, "a new version with the grant does not ask")
        XCTAssertEqual(defaults.string(forKey: key), "9")

        // A button asks whatever the launch did; the next click opens Settings.
        let asked = launch(version: "9", trusted: false)
        XCTAssertFalse(asked.accessibilityPromptAttempted)
        asked.requestOrOpenAccessibility()
        XCTAssertEqual(prompts, 2)
        XCTAssertTrue(asked.accessibilityPromptAttempted)
    }

    func testMicrophoneGateTable() {
        XCTAssertEqual(DictationCoordinator.micGate(.authorized), .proceed)
        XCTAssertEqual(DictationCoordinator.micGate(.notDetermined), .promptViaMenu)
        XCTAssertEqual(DictationCoordinator.micGate(.denied), .openSettings)
        XCTAssertEqual(DictationCoordinator.micGate(.restricted), .openSettings)
    }

    func testDictationLanguageDefaultsToAutoAndKeepsAnyStoredCode() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.DictationLanguage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(SettingsStore(defaults: defaults).dictationLanguage, "auto")
        defaults.set("ja", forKey: "dictation.language")
        XCTAssertEqual(SettingsStore(defaults: defaults).dictationLanguage, "ja")
    }

    /// A language the selected engine does not know shows and works as
    /// "auto", but the setting stays: back on the engine that knows it, it is
    /// there again. Choosing in the picker is what writes it.
    func testPickedLanguageFollowsTheEngineWithoutRewritingTheSetting() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.PickedLanguage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        store.dictationEngine = .whisper
        store.pickedLanguage = "ja"

        store.dictationEngine = .parakeet
        XCTAssertEqual(store.pickedLanguage, "auto")
        XCTAssertEqual(store.snapshot.decodeRequest, .parakeet(nil))
        XCTAssertEqual(SettingsStore(defaults: defaults).dictationLanguage, "ja")

        store.dictationEngine = .whisper
        XCTAssertEqual(store.pickedLanguage, "ja")
        XCTAssertEqual(store.snapshot.decodeRequest, .whisper(WhisperDecodeRequest(language: "ja")))

        store.dictationEngine = .parakeet
        store.pickedLanguage = "pl"
        XCTAssertEqual(SettingsStore(defaults: defaults).dictationLanguage, "pl")
    }

    /// Search in the language picker: by the name shown in this locale
    /// (case and accents ignored) or by code; the current choice stays; a
    /// language found this way is what the engine is asked in.
    func testLanguageSearchFiltersByNameAndCodeAndKeepsTheChoice() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.LanguageSearch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        store.dictationEngine = .whisper
        let choices = DictationEngine.whisper.languageChoices
        let japanese = try XCTUnwrap(Locale.current.localizedString(forLanguageCode: "ja"))
        let codes = { (query: String, keeping: String) in
            DictationSettingsView.filteredLanguages(choices, query: query, keeping: keeping).map(\.code)
        }

        XCTAssertTrue(codes(String(japanese.uppercased().prefix(4)), "auto").contains("ja"))
        XCTAssertTrue(codes("ja", "auto").contains("ja"))
        XCTAssertEqual(codes("", "auto").count, choices.count)
        XCTAssertEqual(codes("zzzz", "auto"), [])
        XCTAssertEqual(codes("zzzz", "de"), ["de"], "the current choice never drops out")

        let found = try XCTUnwrap(codes("ja", "auto").first { $0 == "ja" })
        store.pickedLanguage = found
        XCTAssertEqual(store.snapshot.decodeRequest, .whisper(WhisperDecodeRequest(language: "ja")))
    }

    /// Accents in a name do not hide it from a plain search.
    func testLanguageSearchIgnoresAccents() {
        let choices: [(code: String, name: String)] = [("fr", "Français"), ("de", "Deutsch")]
        XCTAssertEqual(
            DictationSettingsView.filteredLanguages(choices, query: "francais", keeping: "auto").map(\.code),
            ["fr"]
        )
    }

    /// Why Auto is used for a language the engine does not know; the
    /// setting stays and comes back with the engine that knows it.
    func testFallbackNoteExplainsAutoAndTheSettingStays() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.FallbackNote.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)

        let parakeetNote = try XCTUnwrap(DictationSettingsView.fallbackNote(setting: "ja", engine: .parakeet))
        XCTAssertTrue(parakeetNote.contains("Whisper"), parakeetNote)
        XCTAssertTrue(parakeetNote.contains(DictationEngine.languageName("ja")), parakeetNote)
        XCTAssertNil(DictationSettingsView.fallbackNote(setting: "ja", engine: .whisper))
        XCTAssertNil(DictationSettingsView.fallbackNote(setting: "auto", engine: .parakeet))
        let unknown = try XCTUnwrap(DictationSettingsView.fallbackNote(setting: "xx", engine: .whisper))
        XCTAssertTrue(unknown.contains("either engine"), unknown)
        XCTAssertTrue(unknown.contains("xx"), unknown)

        store.dictationEngine = .whisper
        store.pickedLanguage = "ja"
        store.dictationEngine = .parakeet
        XCTAssertNotNil(DictationSettingsView.fallbackNote(setting: store.dictationLanguage, engine: store.dictationEngine))
        store.dictationEngine = .whisper
        XCTAssertEqual(store.dictationLanguage, "ja")
        XCTAssertNil(DictationSettingsView.fallbackNote(setting: store.dictationLanguage, engine: store.dictationEngine))
    }

    func testDictationLanguagePersists() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.LanguagePersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        store.dictationLanguage = "en"

        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.dictationLanguage, "en")
        XCTAssertEqual(restored.snapshot.dictationLanguage, "en")
    }

    func testLaunchAtLoginDefaultsOnAndPersistsSeparately() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.LaunchAtLogin." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.launchAtLogin)
        store.launchAtLogin = false
        XCTAssertFalse(SettingsStore(defaults: defaults).launchAtLogin)
    }

    func testSoundParentTruthTableAndPersistence() throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.SoundParent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)

        let cases: [(start: Bool, insert: Bool, parent: Bool)] = [
            (false, false, false),
            (true, false, true),
            (false, true, true),
            (true, true, true),
        ]
        for testCase in cases {
            store.soundOnRecordingStart = testCase.start
            store.soundOnInsert = testCase.insert
            XCTAssertEqual(store.soundsEnabled, testCase.parent)
        }

        store.soundsEnabled = false
        XCTAssertFalse(store.soundOnRecordingStart)
        XCTAssertFalse(store.soundOnInsert)
        store.soundsEnabled = true
        XCTAssertTrue(store.soundOnRecordingStart)
        XCTAssertTrue(store.soundOnInsert)

        let restored = SettingsStore(defaults: defaults)
        XCTAssertTrue(restored.soundOnRecordingStart)
        XCTAssertTrue(restored.soundOnInsert)
        XCTAssertTrue(restored.soundsEnabled)
    }

    func testDictationSettingsBlockPopBottleAndClipboardFallbackBeep() async throws {
        let suiteName = "io.github.spacevibes365.MurmurlyTests.DictationSounds.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = SettingsStore(defaults: defaults)
        settings.soundsEnabled = false
        let probe = FeedbackProbe()
        let coordinator = DictationCoordinator(
            mic: ImmediateMic(),
            indicator: RecordingIndicator(renderingEnabled: false),
            feedbackPlayer: { probe.play($0) },
            beepPlayer: { probe.beep() }
        )
        coordinator.configureForTesting(settings: settings)

        coordinator.beginCaptureForTesting()
        for _ in 0..<100 where coordinator.state != .recording {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(coordinator.state, .recording)
        XCTAssertTrue(probe.names.isEmpty)
        coordinator.toggle()
        for _ in 0..<100 where coordinator.state != .idle {
            try await Task.sleep(for: .milliseconds(10))
        }

        settings.soundOnRecordingStart = true
        coordinator.beginCaptureForTesting()
        for _ in 0..<100 where coordinator.state != .recording {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(probe.names, ["Pop"])
        coordinator.toggle()
        for _ in 0..<100 where coordinator.state != .idle {
            try await Task.sleep(for: .milliseconds(10))
        }

        probe.names.removeAll()
        settings.soundOnInsert = false
        coordinator.playInsertionSucceededFeedbackForTesting()
        XCTAssertTrue(probe.names.isEmpty)
        settings.soundOnInsert = true
        coordinator.playInsertionSucceededFeedbackForTesting()
        XCTAssertEqual(probe.names, ["Bottle"])

        settings.soundsEnabled = false
        coordinator.playClipboardFallbackFeedbackForTesting()
        XCTAssertEqual(probe.beeps, 0)
        settings.soundOnRecordingStart = true
        coordinator.playClipboardFallbackFeedbackForTesting()
        XCTAssertEqual(probe.beeps, 1)
    }

    func testStaleStartCannotOverwriteNewAttemptState() async throws {
        let mic = SlowMic()
        let coordinator = DictationCoordinator(
            mic: mic,
            indicator: RecordingIndicator(renderingEnabled: false),
            startTimeout: 0.05,
            frontmostApplication: { NSRunningApplication.current },
            ownProcessIdentifier: -1
        )
        coordinator.beginCaptureForTesting()
        XCTAssertTrue(coordinator.hasStartInjectTargetForTesting)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.hasStartInjectTargetForTesting)

        // Let the non-cancellable first start return. Its stale success must be
        // cleaned up without changing idle to recording.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(coordinator.state, .idle)

        coordinator.beginCaptureForTesting()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(coordinator.state, .recording)
        let starts = await mic.startCount()
        XCTAssertEqual(starts, 2)
        coordinator.toggle()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.hasStartInjectTargetForTesting)
    }

    func testInjectionTargetMatrix() {
        let cases: [(String?, String?, String?)] = [
            ("A", "B", "B"),
            ("A", "Murmurly", "A"),
            ("A", nil, "A"),
            ("Murmurly", "B", "B"),
        ]

        for (startedWith, stoppedWith, expected) in cases {
            XCTAssertEqual(
                DictationCoordinator.preferredInjectionTarget(
                    startedWith: startedWith,
                    stoppedWith: stoppedWith,
                    isOwnApplication: { $0 == "Murmurly" }
                ),
                expected,
                "Unexpected target for \(startedWith ?? "nil") → \(stoppedWith ?? "nil")"
            )
        }
    }

    func testStartFailureClearsSavedInjectionTarget() async throws {
        let indicator = RecordingIndicator(renderingEnabled: false)
        let coordinator = DictationCoordinator(
            mic: FailingStartMic(),
            indicator: indicator,
            startTimeout: 1,
            frontmostApplication: { NSRunningApplication.current },
            ownProcessIdentifier: -1
        )

        coordinator.beginCaptureForTesting()
        XCTAssertTrue(coordinator.hasStartInjectTargetForTesting)
        for _ in 0..<100 where coordinator.state != .idle {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.hasStartInjectTargetForTesting)
        guard case .dictationFailure = indicator.presentedState else {
            return XCTFail("Start failure did not produce a dictation failure state")
        }
    }
}
