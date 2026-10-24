import AppKit
import SwiftUI
import XCTest
@testable import Murmurly

/// macOS gives Russian word forms only from its Russian language data, which a
/// fresh Mac (a hosted CI runner) may not have yet. The tests of those forms
/// skip there, naming the reason, rather than fail on a machine that cannot
/// tell; where the data is present they check the forms as before.
enum MacOSRussianWordForms {
    static let available = DictionaryReplacer.macOSWordForms()("клода").lowercased() == "клод"

    static func require() throws {
        try XCTSkipUnless(available, "macOS gives no Russian word forms on this Mac (\"клода\" has no dictionary form): its Russian language data is not here")
    }
}

final class PersonalDictionaryTests: XCTestCase {
    private func entry(_ heard: String, _ written: String, enabled: Bool = true) -> DictionaryEntry {
        DictionaryEntry(heard: DictionaryEntry.variants(fromList: heard), written: written, isEnabled: enabled)
    }

    /// A fixed table of word forms: the algorithm is checked apart from
    /// whatever this macOS knows.
    private func table(_ forms: [String: String]) -> DictionaryReplacer.WordForms {
        { { forms[$0] ?? "" } }
    }

    private func replaced(
        _ text: String,
        _ entries: [DictionaryEntry],
        wordForms: Bool = true,
        forms: [String: String] = [:]
    ) -> String {
        DictionaryReplacer(
            entries: entries, matchesWordForms: wordForms, wordForms: table(forms)
        ).replacing(in: text).text
    }

    private let claudeCode = DictionaryEntry(heard: ["клод код"], written: "Claude Code")

    // MARK: - Spelling

    func testEmptyDictionaryLeavesTheTextByteForByte() {
        let text = "  клод\u{00A0}код,\nе\u{0301} 👋🏽  "
        let empty = DictionaryReplacer(entries: [], matchesWordForms: true, wordForms: table([:]))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(Array(empty.replacing(in: text).text.utf8), Array(text.utf8))

        let unmatched = DictionaryReplacer(
            entries: [entry("гитхаб", "GitHub")], matchesWordForms: true, wordForms: table([:])
        ).replacing(in: text)
        XCTAssertEqual(Array(unmatched.text.utf8), Array(text.utf8))
        XCTAssertEqual(unmatched.count, 0)
    }

    func testCaseAndYoDoNotMatterButShortIDoes() {
        XCTAssertEqual(replaced("КЛОД Код готов", [claudeCode]), "Claude Code готов")
        XCTAssertEqual(replaced("все ок", [entry("всё ок", "OK")]), "OK")
        XCTAssertEqual(replaced("ВСЁ ОК", [entry("все ок", "OK")]), "OK")
        XCTAssertEqual(replaced("мои коды", [entry("мой коды", "My Codes")]), "мои коды")
    }

    func testPunctuationAroundAPhraseStays() {
        XCTAssertEqual(replaced("(клод код)! «Клод код», да?", [claudeCode]), "(Claude Code)! «Claude Code», да?")
    }

    func testPhraseDoesNotCrossAFullStopACommaOrALineBreak() {
        for text in ["…был клод. Код написан…", "клод, код", "клод\nкод", "клод — код", "клод - код"] {
            XCTAssertEqual(replaced(text, [claudeCode]), text)
        }
        XCTAssertEqual(replaced("клод \u{00A0}\tкод", [claudeCode]), "Claude Code")
    }

    func testHyphenJoinsTheWordsOfAVariant() {
        let forms = ["клод": "клод", "код": "код", "кодом": "код"]
        XCTAssertEqual(replaced("клод-код", [claudeCode]), "Claude Code")
        XCTAssertEqual(replaced("с клод-кодом", [claudeCode], forms: forms), "с Claude Code")
        XCTAssertEqual(replaced("клод код", [entry("клод-код", "Claude Code")]), "Claude Code")
    }

    func testLongestVariantWinsAndEveryWordIsUsedOnce() {
        let result = DictionaryReplacer(
            entries: [entry("код", "Code"), claudeCode], matchesWordForms: true, wordForms: table([:])
        ).replacing(in: "клод код и код")
        XCTAssertEqual(result.text, "Claude Code и Code")
        XCTAssertEqual(result.count, 2)
    }

    func testOnePassNeitherChainsNorUndoesASwap() {
        XCTAssertEqual(replaced("альфа", [entry("альфа", "бета"), entry("бета", "гамма")]), "бета")
        XCTAssertEqual(replaced("альфа бета", [entry("альфа", "бета"), entry("бета", "альфа")]), "бета альфа")
    }

    func testWrittenFormAlreadyInPlaceIsLeftAlone() {
        let claude = entry("claude", "Claude Code")
        let result = DictionaryReplacer(entries: [claude], matchesWordForms: true, wordForms: table([:]))
            .replacing(in: "Claude Code готов, а claude нет")
        XCTAssertEqual(result.text, "Claude Code готов, а Claude Code нет")
        XCTAssertEqual(result.count, 1)
        // Only the rule's own written form is protected: another rule still
        // applies inside it.
        XCTAssertEqual(
            replaced("Claude Code", [claude, entry("code", "Code Review")]),
            "Claude Code Review"
        )
    }

    func testCaseOfALatinTermIsFixed() {
        let result = DictionaryReplacer(
            entries: [entry("github", "GitHub")], matchesWordForms: true, wordForms: table([:])
        ).replacing(in: "на github и на GitHub")
        XCTAssertEqual(result.text, "на GitHub и на GitHub")
        XCTAssertEqual(result.count, 1)
    }

    func testWrittenFormIsInsertedLiterally() {
        XCTAssertEqual(replaced("клод код", [entry("клод код", #"$1 \0 \(x) $&"#)]), #"$1 \0 \(x) $&"#)
    }

    func testDisabledEntryIsNotApplied() {
        XCTAssertEqual(replaced("клод код", [entry("клод код", "Claude Code", enabled: false)]), "клод код")
    }

    func testEmojiAndComposedCharactersNextToAReplacementStay() {
        let result = replaced("привет 👋🏽 клод код 👍🏻, cafe\u{0301} 🇷🇺", [claudeCode])
        let expected = "привет 👋🏽 Claude Code 👍🏻, cafe\u{0301} 🇷🇺"
        XCTAssertEqual(result, expected)
        // String equality accepts a composed "é" too; the untouched slices
        // must keep their own bytes.
        XCTAssertEqual(Array(result.utf8), Array(expected.utf8))
    }

    // MARK: - Word forms (a fixed table)

    private let claudeForms = [
        "клод": "Клод", "клода": "Клод", "клоду": "Клод",
        "код": "код", "кода": "код", "коду": "код",
    ]

    func testWordFormsMatchTheirDictionaryForm() {
        let forms = claudeForms
        XCTAssertEqual(replaced("у клода кода", [claudeCode], forms: forms), "у Claude Code")
        XCTAssertEqual(replaced("Клоду Коду", [claudeCode], forms: forms), "Claude Code")
    }

    func testExactSpellingWinsOverAWordFormOfEqualLength() {
        let forms = ["коды": "код", "кода": "код"]
        XCTAssertEqual(replaced("кода", [entry("коды", "Codes"), entry("кода", "Code")], forms: forms), "Code")
    }

    func testEmptyFormsNeverMatchEachOther() {
        // Neither word is known: both forms are empty, and empty is no form.
        let forms = ["гитхаб": "", "гитхабе": ""]
        XCTAssertEqual(replaced("на гитхабе", [entry("гитхаб", "GitHub")], forms: forms), "на гитхабе")
    }

    /// The first word matches by form; the second has no form on either
    /// side, and two empty forms are no match.
    func testEmptyFormInsideAPhraseIsNoMatch() {
        let forms = ["клод": "клод", "клода": "клод"]
        XCTAssertEqual(
            replaced("клода мармурли", [entry("клод мюрмурли", "Claude Murmurly")], forms: forms),
            "клода мармурли"
        )
    }

    func testYoInFormsDoesNotMatter() {
        let forms = ["ёлки": "ёлка", "елка": "елка"]
        XCTAssertEqual(replaced("ёлки", [entry("елка", "Tree")], forms: forms), "Tree")
    }

    func testSameAlphabetWrittenFormMatchesOnlyExactly() {
        let forms = ["андрюшин": "андрюшин", "андрюшину": "андрюшин"]
        let surname = entry("андрюшин", "Андрюшкин")
        XCTAssertEqual(replaced("андрюшину", [surname], forms: forms), "андрюшину")
        XCTAssertEqual(replaced("андрюшин", [surname], forms: forms), "Андрюшкин")
    }

    func testCyrillicInTheWrittenFormMeansExactOnly() {
        let forms = ["яндекс": "яндекс", "яндекса": "яндекс", "гпт": "гпт"]
        let yandex = entry("яндекс гпт", "Яндекс GPT")
        XCTAssertEqual(replaced("у яндекса гпт", [yandex], forms: forms), "у яндекса гпт")
        XCTAssertEqual(replaced("яндекс гпт", [yandex], forms: forms), "Яндекс GPT")
    }

    func testVariantMixingAlphabetsOrDigitsMatchesOnlyExactly() {
        let forms = ["клод": "клод", "клода": "клод", "с": "с", "1с": "1с", "1са": "1с"]
        XCTAssertEqual(replaced("клода api", [entry("клод api", "Claude API")], forms: forms), "клода api")
        XCTAssertEqual(replaced("клод API", [entry("клод api", "Claude API")], forms: forms), "Claude API")
        XCTAssertEqual(replaced("1са", [entry("1с", "1C")], forms: forms), "1са")
    }

    func testAnotherLanguageMatchesOnlyExactlyAndNeverTags() {
        let replacer = DictionaryReplacer(entries: [claudeCode], matchesWordForms: false) {
            XCTFail("word forms looked up for a job in another language")
            return { _ in "" }
        }
        XCTAssertEqual(replacer.replacing(in: "клода кода").text, "клода кода")
        XCTAssertEqual(replacer.replacing(in: "клод код").text, "Claude Code")
    }

    // MARK: - macOS word forms (must hold on every supported macOS)

    func testMacOSFormsOfClaudeCode() throws {
        try MacOSRussianWordForms.require()
        let real = DictionaryReplacer(entries: [claudeCode], matchesWordForms: true)
        XCTAssertEqual(real.replacing(in: "у клода кода").text, "у Claude Code")
        XCTAssertEqual(real.replacing(in: "клоду коду").text, "Claude Code")
        XCTAssertEqual(real.replacing(in: "клод кода").text, "Claude Code")
        XCTAssertEqual(real.replacing(in: "привет. клода кода").text, "привет. Claude Code")
    }

    /// Without the language set on the tagger these two words get no form.
    func testMacOSFormsOfAShortDictation() throws {
        try MacOSRussianWordForms.require()
        let real = DictionaryReplacer(entries: [claudeCode], matchesWordForms: true)
        XCTAssertEqual(real.replacing(in: "клода кода").text, "Claude Code")
    }

    /// Tagged in a sentence, a capitalised "Кода" is its own form.
    func testMacOSFormsOfCapitalisedWords() throws {
        try MacOSRussianWordForms.require()
        let real = DictionaryReplacer(entries: [claudeCode], matchesWordForms: true)
        XCTAssertEqual(real.replacing(in: "Клода Кода").text, "Claude Code")
    }

    func testMacOSFormsLeaveLongerWordsAlone() {
        let real = DictionaryReplacer(entries: [entry("код", "Code")], matchesWordForms: true)
        XCTAssertEqual(real.replacing(in: "кодекс, кодекса и код").text, "кодекс, кодекса и Code")
    }

    func testExactPhraseNeedsNoForms() {
        let real = DictionaryReplacer(entries: [claudeCode], matchesWordForms: true)
        XCTAssertEqual(real.replacing(in: "клод код").text, "Claude Code")
    }

    func testListedFormsOfALoanword() {
        let real = DictionaryReplacer(entries: [entry("гитхаб, гитхабе, гитхаба", "GitHub")], matchesWordForms: true)
        XCTAssertEqual(real.replacing(in: "на гитхабе, с гитхаба").text, "на GitHub, с GitHub")
    }

    // MARK: - What the sheet accepts

    func testCommaListKeepsEmptyPiecesForTheCheck() {
        XCTAssertEqual(DictionaryEntry.variants(fromList: " клод код,клауд код "), ["клод код", "клауд код"])
        XCTAssertEqual(DictionaryEntry.variants(fromList: "клод,"), ["клод", ""])
    }

    func testSheetRefusesEmptySidesAndStrayCommas() {
        XCTAssertEqual(entry("", "Claude").problem(among: []), .noHeard)
        XCTAssertEqual(entry("клод, ,код", "Claude").problem(among: []), .emptyVariant)
        XCTAssertEqual(entry("клод,", "Claude").problem(among: []), .emptyVariant)
        XCTAssertEqual(entry("клод", "  ").problem(among: []), .noWritten)
    }

    func testSheetRefusesOneLetterAndPunctuation() {
        XCTAssertEqual(entry("и", "and").problem(among: []), .tooShort("и"))
        XCTAssertEqual(entry("т.е.", "i.e.").problem(among: []), .punctuation("т.е."))
        XCTAssertEqual(entry("don't", "do not").problem(among: []), .punctuation("don't"))
        XCTAssertNil(entry("клод-код, 1с", "Claude").problem(among: []))
    }

    func testSheetRefusesASpellingTakenByAnotherEnabledEntry() {
        let taken = claudeCode
        XCTAssertEqual(entry("Клод-Код", "Claude").problem(among: [taken]), .duplicate("Клод-Код"))
        XCTAssertEqual(entry("клод код, клод  код", "Claude").problem(among: []), .repeated("клод  код"))
        XCTAssertEqual(entry("клёд", "x").problem(among: [entry("клед", "y")]), .duplicate("клёд"))
        XCTAssertNil(entry("клод код", "Claude").problem(among: [entry("клод код", "x", enabled: false)]))
        XCTAssertNil(entry("клод код", "Claude", enabled: false).problem(among: [taken]))
        var edited = taken
        edited.written = "Claude Code!"
        XCTAssertNil(edited.problem(among: [taken]))
    }

    /// A spelling twice in one list is a fault of the entry itself: switched
    /// off, it could not be switched on again, and its exported file would
    /// not import.
    func testSpellingRepeatedInOneEntryIsRefusedEvenSwitchedOff() {
        XCTAssertEqual(entry("клод код, Клод-Код", "Claude", enabled: false).problem(among: []), .repeated("Клод-Код"))
        XCTAssertNil(entry("клод код", "Claude", enabled: false).problem(among: [claudeCode]))
    }

    func testCaseFixOfTheWrittenFormIsAccepted() {
        XCTAssertNil(entry("github", "GitHub").problem(among: []))
    }

    func testTypedSpellingOnTwoLinesIsRefused() {
        XCTAssertEqual(entry("клод\nкод", "Claude Code").problem(among: []), .lineBreak)
    }

    // MARK: - A selection in a dictation

    func testSelectionIsOneSpellingWithItsEdgesTrimmed() {
        XCTAssertEqual(DictionaryEntry.variant(fromSelection: "клод код"), .success("клод код"))
        XCTAssertEqual(DictionaryEntry.variant(fromSelection: " клод код \n"), .success("клод код"))
        XCTAssertEqual(DictionaryEntry.variant(fromSelection: "клод-код"), .success("клод-код"))
    }

    /// A comma is not taken as a list separator nor dropped, and nothing
    /// that the replacement would never cross is cut away.
    func testSelectionWithPunctuationOrALineBreakIsRefused() {
        XCTAssertEqual(DictionaryEntry.variant(fromSelection: "клод, код"), .failure(.punctuation("клод, код")))
        XCTAssertEqual(DictionaryEntry.variant(fromSelection: "клод код."), .failure(.punctuation("клод код.")))
        XCTAssertEqual(DictionaryEntry.variant(fromSelection: "клод\nкод"), .failure(.lineBreak))
        XCTAssertEqual(DictionaryEntry.variant(fromSelection: " и "), .failure(.tooShort("и")))
    }

    /// Selection → the "heard as" field → the saved entry: one selected
    /// phrase stays one spelling all the way.
    func testSelectedPhraseIsSavedAsOneSpelling() throws {
        let source = "вот клод код работает"
        let selected = source[source.range(of: "клод код ")!]
        let field = try DictionaryEntry.variant(fromSelection: selected).get()

        let saved = DictionaryEntry(heard: DictionaryEntry.variants(fromList: field), written: "Claude Code")

        XCTAssertNil(saved.problem(among: []))
        XCTAssertEqual(saved.heard, ["клод код"])
        XCTAssertEqual(
            DictionaryReplacer(entries: [saved], matchesWordForms: false).replacing(in: source).text,
            "вот Claude Code работает"
        )
    }
}

/// The dictionary in the settings: what is stored, what a job gets, and what
/// never happens to the stored data.
@MainActor
final class DictionaryStorageTests: XCTestCase {
    private static let key = "dictionary.entries"
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "io.github.spacevibes365.MurmurlyTests.Dictionary.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let claudeCode = DictionaryEntry(heard: ["клод код", "клауд код"], written: "Claude Code")

    func testFirstLaunchHasAnEmptyDictionaryEverywhereAndWritesNothing() {
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.dictionary, [])
        XCTAssertFalse(store.dictionaryUnreadable)
        XCTAssertTrue(store.dictionaryInDictation)
        XCTAssertTrue(store.dictionaryInMeetings)
        XCTAssertTrue(store.dictionaryInFiles)
        XCTAssertEqual(store.dictionarySnapshot.uses, [.dictation, .meetings, .files])
        XCTAssertNil(store.dictionarySnapshot.replacer(for: .dictation))
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName)?.keys.filter { $0.hasPrefix("dictionary.") } ?? [], [])
    }

    func testSavedDictionaryAndItsSwitchesComeBack() throws {
        let store = SettingsStore(defaults: defaults)
        let off = DictionaryEntry(heard: ["гитхаб"], written: "GitHub", isEnabled: false)

        try store.saveDictionary([claudeCode, off])
        store.dictionaryInMeetings = false

        let reopened = SettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.dictionary, [claudeCode, off])
        XCTAssertTrue(reopened.dictionaryInDictation)
        XCTAssertFalse(reopened.dictionaryInMeetings)
        XCTAssertTrue(reopened.dictionaryInFiles)
        let stored = try JSONSerialization.jsonObject(with: try XCTUnwrap(defaults.data(forKey: Self.key)))
        XCTAssertEqual((stored as? [String: Any])?["version"] as? Int, 1)
    }

    func testUnreadableDictionaryIsKeptBlocksEditingAndJobsRunWithout() throws {
        let newer = try JSONSerialization.data(withJSONObject: ["version": 3, "entries": []])
        for stored in [Data("not json".utf8) as Any, "a string", newer] {
            defaults.set(stored, forKey: Self.key)
            let before = defaults.object(forKey: Self.key) as? NSObject

            let store = SettingsStore(defaults: defaults)

            XCTAssertTrue(store.dictionaryUnreadable)
            XCTAssertEqual(store.dictionary, [])
            XCTAssertNil(store.dictionarySnapshot.replacer(for: .dictation))
            XCTAssertThrowsError(try store.saveDictionary([claudeCode]))
            XCTAssertEqual(defaults.object(forKey: Self.key) as? NSObject, before, "the unread data was overwritten")

            store.clearDictionary()
            XCTAssertFalse(store.dictionaryUnreadable)
            XCTAssertNil(defaults.object(forKey: Self.key))
            XCTAssertNoThrow(try store.saveDictionary([claudeCode]))
            XCTAssertEqual(SettingsStore(defaults: defaults).dictionary, [claudeCode])
        }
    }

    func testFailedEncodingKeepsTheStoredDataTheEntriesAndTheSnapshot() throws {
        struct Refused: Error {}
        let refuse = Locked(false)
        let store = SettingsStore(defaults: defaults) { entries in
            if refuse.value { throw Refused() }
            return try SettingsStore.encodedDictionary(entries)
        }
        try store.saveDictionary([claudeCode])
        let data = defaults.data(forKey: Self.key)
        let snapshot = store.dictionarySnapshot

        refuse.value = true
        XCTAssertThrowsError(try store.saveDictionary([]))

        XCTAssertEqual(defaults.data(forKey: Self.key), data)
        XCTAssertEqual(store.dictionary, [claudeCode])
        XCTAssertEqual(store.dictionarySnapshot, snapshot)
    }

    func testSnapshotStaysAsTakenAfterAnEdit() throws {
        let store = SettingsStore(defaults: defaults)
        try store.saveDictionary([claudeCode])
        let taken = store.dictionarySnapshot

        try store.saveDictionary([DictionaryEntry(heard: ["гитхаб"], written: "GitHub")])
        store.dictionaryInDictation = false

        XCTAssertEqual(taken.entries, [claudeCode])
        XCTAssertTrue(taken.applies(to: .dictation))
        XCTAssertEqual(store.dictionarySnapshot.entries.map(\.written), ["GitHub"])
        XCTAssertFalse(store.dictionarySnapshot.applies(to: .dictation))
    }

    func testSwitchesDecideWhereTheDictionaryApplies() throws {
        let store = SettingsStore(defaults: defaults)
        try store.saveDictionary([claudeCode])
        store.dictionaryInDictation = false
        store.dictionaryInFiles = false

        let snapshot = store.dictionarySnapshot
        XCTAssertNil(snapshot.replacer(for: .dictation))
        XCTAssertNil(snapshot.replacer(for: .files))
        XCTAssertEqual(snapshot.replacer(for: .meetings)?.replacing(in: "клауд код").text, "Claude Code")

        try store.saveDictionary([DictionaryEntry(heard: ["клод код"], written: "Claude Code", isEnabled: false)])
        XCTAssertNil(store.dictionarySnapshot.replacer(for: .meetings))
    }

    /// The flag comes from the same answer as the engine request: Auto, an
    /// empty code and one the engine does not know all mean "auto".
    func testWordFormsFollowTheLanguageTheEngineIsAskedFor() throws {
        try MacOSRussianWordForms.require()
        let store = SettingsStore(defaults: defaults)
        let cases: [(DictationEngine, String, Bool)] = [
            (.parakeet, "auto", true), (.parakeet, "ru", true), (.parakeet, "", true),
            (.parakeet, "ja", true),   // Parakeet does not know it: Auto
            (.parakeet, "uk", false), (.parakeet, "en", false),
            (.whisper, "auto", true), (.whisper, "ru", true), (.whisper, "xx", true),
            (.whisper, "uk", false), (.whisper, "ja", false),
        ]
        for (engine, language, expected) in cases {
            store.dictationEngine = engine
            store.dictationLanguage = language
            XCTAssertEqual(store.dictionarySnapshot.matchesWordForms, expected, "\(engine) \(language)")
        }
        try? store.saveDictionary([claudeCode])
        store.dictationLanguage = "uk"
        XCTAssertEqual(store.dictionarySnapshot.replacer(for: .dictation)?.replacing(in: "у клода кода").text, "у клода кода")
        store.dictationLanguage = "auto"
        XCTAssertEqual(store.dictionarySnapshot.replacer(for: .dictation)?.replacing(in: "у клода кода").text, "у Claude Code")
    }

    /// The test host's default store keeps the dictionary in this process's
    /// own settings, never in the app's live domain.
    func testTestProcessKeepsItsDictionaryInItsOwnSettings() throws {
        let isolated = try XCTUnwrap(UserDefaults(suiteName: TestIsolation.settingsSuiteName))
        let standardBefore = UserDefaults.standard.object(forKey: Self.key) as? NSObject
        defer { isolated.removeObject(forKey: Self.key) }

        try SettingsStore().saveDictionary([claudeCode])

        XCTAssertNotNil(isolated.data(forKey: Self.key))
        XCTAssertEqual(UserDefaults.standard.object(forKey: Self.key) as? NSObject, standardBefore)
        XCTAssertEqual(SettingsStore().dictionary, [claudeCode])
    }
}

/// Export and import: the file is the settings' own document, an import
/// takes only a whole dictionary this app could have saved, and adding never
/// undoes an edit made since the file was written.
@MainActor
final class DictionaryTransferTests: XCTestCase {
    private static let key = "dictionary.entries"
    private var suites: [String] = []
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictionary-transfer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
        try? FileManager.default.removeItem(at: folder)
    }

    /// The settings of one Mac.
    private func makeDefaults() throws -> UserDefaults {
        let name = "io.github.spacevibes365.MurmurlyTests.DictionaryTransfer.\(UUID().uuidString)"
        suites.append(name)
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func entry(_ number: Int, _ heard: [String], _ written: String, enabled: Bool = true) -> DictionaryEntry {
        DictionaryEntry(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!,
            heard: heard, written: written, isEnabled: enabled
        )
    }

    private func document(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private var exportURL: URL { folder.appendingPathComponent("Murmurly Dictionary.json") }

    /// The file is open: indented, its keys in a fixed order, the letters as
    /// they are, and the same bytes the settings hold.
    func testExportedFileIsTheSettingsDocumentByteForByte() async throws {
        let defaults = try makeDefaults()
        let store = SettingsStore(defaults: defaults)
        try store.saveDictionary([
            entry(1, ["клод код", "клауд код"], "Claude Code"),
            entry(2, ["си ай си ди"], "CI/CD", enabled: false),
        ])

        let count = try await store.exportDictionary(to: exportURL)

        XCTAssertEqual(count, 2)
        let written = try Data(contentsOf: exportURL)
        XCTAssertEqual(written, defaults.data(forKey: Self.key))
        XCTAssertEqual(String(decoding: written, as: UTF8.self), """
        {
          "entries" : [
            {
              "enabled" : true,
              "heard" : [
                "клод код",
                "клауд код"
              ],
              "id" : "00000000-0000-0000-0000-000000000001",
              "written" : "Claude Code"
            },
            {
              "enabled" : false,
              "heard" : [
                "си ай си ди"
              ],
              "id" : "00000000-0000-0000-0000-000000000002",
              "written" : "CI/CD"
            }
          ],
          "version" : 1
        }
        """)
    }

    /// Another Mac with an empty dictionary gets the entries, their order,
    /// switches and ids, and stores the very same bytes.
    func testExportImportsIntoAnEmptyDictionaryAsItWas() async throws {
        let myDefaults = try makeDefaults()
        let mine = SettingsStore(defaults: myDefaults)
        // A switched-off entry may share a spelling with one switched on.
        let entries = [
            entry(1, ["клод код"], "Claude Code"),
            entry(2, ["гитхаб"], "GitHub", enabled: false),
            entry(3, ["клод код", "клауд код"], "Claude", enabled: false),
        ]
        for (index, entry) in entries.enumerated() {
            XCTAssertNil(entry.problem(among: Array(entries[..<index])), "the sheet would refuse \(entry.written)")
        }
        try mine.saveDictionary(entries)
        _ = try await mine.exportDictionary(to: exportURL)

        let otherDefaults = try makeDefaults()
        let other = SettingsStore(defaults: otherDefaults)
        let read = try await SettingsStore.importedDictionary(at: exportURL).get()
        let result = try other.importDictionary(read, replacing: false)

        XCTAssertEqual(result, .added(3, turnedOff: 0, matched: 0, kept: 0))
        XCTAssertEqual(result.summary, "Added: 3.")
        XCTAssertEqual(other.dictionary, entries)
        XCTAssertEqual(other.dictionarySnapshot.entries, entries)
        XCTAssertEqual(otherDefaults.data(forKey: Self.key), myDefaults.data(forKey: Self.key))
        XCTAssertEqual(SettingsStore(defaults: otherDefaults).dictionary, entries)
    }

    func testFileThatIsNotThisVersionsDictionaryIsRefusedWithItsReason() throws {
        let good: [String: Any] = [
            "id": "00000000-0000-0000-0000-000000000001", "heard": ["клод код"], "written": "Claude Code", "enabled": true,
        ]
        // id and enabled are required, so an entry typed in by hand needs them.
        let noSwitch: [String: Any] = [
            "id": "00000000-0000-0000-0000-000000000002", "heard": ["гитхаб"], "written": "GitHub",
        ]
        let badID = good.merging(["id": "not an id"]) { $1 }
        let badSpelling = good.merging(["heard": [1]]) { $1 }
        let notADictionary = "This file is not a Murmurly dictionary."
        let cases: [(Data, SettingsStore.DictionaryFileFailure, String)] = try [
            (Data("not json".utf8), .notADictionary, notADictionary),
            (JSONSerialization.data(withJSONObject: [good]), .notADictionary, notADictionary),
            (document(["entries": [good]]), .notADictionary, notADictionary),
            (document(["version": 1, "entries": "клод код"]), .notADictionary, notADictionary),
            // Read as a newer version, not as a damaged file, whatever it holds.
            (document(["version": 3, "words": ["клод код"]]), .version(3),
             "This dictionary is in a format this version of Murmurly can’t read (version 3)."),
            (document(["version": 1, "entries": [[String: Any]]()]), .noEntries, "The file has no entries."),
            (document(["version": 1, "entries": [good, noSwitch]]), .unreadableEntry(2), "Entry 2 can’t be read."),
            (document(["version": 1, "entries": [good, badID]]), .unreadableEntry(2), "Entry 2 can’t be read."),
            (document(["version": 1, "entries": [good, good, badSpelling]]), .unreadableEntry(3), "Entry 3 can’t be read."),
        ]
        for (data, failure, message) in cases {
            XCTAssertEqual(SettingsStore.importedDictionary(from: data), .failure(failure), message)
            XCTAssertEqual(failure.message, message)
        }
    }

    func testFileThatCannotBeReadIsRefused() async {
        guard case .failure(.unreadableFile(let reason)) = await SettingsStore.importedDictionary(
            at: folder.appendingPathComponent("missing.json")
        ) else { return XCTFail("a missing file was not refused as unreadable") }
        XCTAssertFalse(reason.isEmpty)
    }

    /// Two entries with one id would be switched and deleted together.
    func testSameIDTwiceInAFileIsRefusedSwitchedOffToo() throws {
        let first = entry(1, ["клод код"], "Claude Code", enabled: false)
        var copy = first
        copy.heard = ["клауд код"]
        copy.written = "Claude"

        let data = try SettingsStore.encodedDictionary([entry(2, ["гитхаб"], "GitHub"), first, copy])

        XCTAssertEqual(SettingsStore.importedDictionary(from: data), .failure(.sameID(2, 3)))
        XCTAssertEqual(SettingsStore.DictionaryFileFailure.sameID(2, 3).message, "Entries 2 and 3 have the same id.")
    }

    /// Nothing is imported in part: one entry the sheet would refuse, even
    /// a switched-off one, refuses the file, and so does a file of bad ones.
    func testOneBadEntryRefusesTheWholeFileEvenSwitchedOff() throws {
        let good = entry(1, ["клод код"], "Claude Code")
        let cases: [([DictionaryEntry], SettingsStore.DictionaryFileFailure)] = [
            ([good, entry(2, ["т.е."], "i.e.", enabled: false)], .entry(2, .punctuation("т.е."))),
            ([good, entry(2, ["гитхаб"], " ", enabled: false)], .entry(2, .noWritten)),
            ([good, entry(2, ["и"], "and", enabled: false)], .entry(2, .tooShort("и"))),
            ([good, entry(2, ["гитхаб", "Гитхаб"], "GitHub", enabled: false)], .entry(2, .repeated("Гитхаб"))),
            ([entry(1, [""], "Claude"), entry(2, ["т.е."], "i.e.")], .entry(1, .noHeard)),
            // Two enabled entries of the file itself: which one wins would be their order.
            ([good, entry(2, ["Клод-Код"], "Claude")], .entry(2, .duplicate("Клод-Код"))),
        ]
        for (entries, failure) in cases {
            XCTAssertEqual(
                SettingsStore.importedDictionary(from: try SettingsStore.encodedDictionary(entries)), .failure(failure)
            )
        }
        XCTAssertEqual(
            SettingsStore.DictionaryFileFailure.entry(2, .punctuation("т.е.")).message,
            "Entry 2: “т.е.” may hold only letters, digits, spaces and hyphens."
        )
    }

    /// The id says where an entry came from, not which copy is newer: an
    /// old file never undoes an edit or a switch made since.
    func testAddingKeepsYourEntriesAndSkipsTheSameOnes() throws {
        let store = SettingsStore(defaults: try makeDefaults())
        let claude = entry(1, ["клод код"], "Claude Code")
        let github = entry(2, ["гитхаб"], "GitHub")
        let vscode = entry(3, ["вскод"], "VS Code")
        var edited = claude
        edited.written = "Claude"
        var switchedOff = github
        switchedOff.isEnabled = false
        try store.saveDictionary([edited, switchedOff, vscode])

        let result = try store.importDictionary([claude, github, vscode], replacing: false)

        XCTAssertEqual(result, .added(0, turnedOff: 0, matched: 1, kept: 2))
        XCTAssertEqual(result.summary, "Added: 0. Already in your dictionary: 1. Kept as you changed them: 2.")
        XCTAssertEqual(store.dictionary, [edited, switchedOff, vscode])
    }

    /// Someone else's entry with a spelling one of yours already has comes in
    /// switched off, after yours and in the file's order; the result is a
    /// dictionary the sheet would take as a whole.
    func testForeignEntryWithYourSpellingIsAddedSwitchedOff() throws {
        let store = SettingsStore(defaults: try makeDefaults())
        let mine = entry(1, ["клод код"], "Claude Code")
        let mineOff = entry(2, ["гитхаб"], "GitHub", enabled: false)
        try store.saveDictionary([mine, mineOff])
        let theirs = [
            entry(10, ["Клод-Код", "клауд"], "Claude"),
            entry(11, ["гитхаб"], "Github"),
            entry(12, ["вскод"], "VS Code", enabled: false),
        ]

        let result = try store.importDictionary(theirs, replacing: false)

        var turnedOff = theirs[0]
        turnedOff.isEnabled = false
        XCTAssertEqual(store.dictionary, [mine, mineOff, turnedOff, theirs[1], theirs[2]])
        XCTAssertEqual(result, .added(3, turnedOff: 1, matched: 0, kept: 0))
        XCTAssertEqual(result.summary, "Added: 3. Switched off, as you already have their spelling: 1.")
        for entry in store.dictionary {
            XCTAssertNil(entry.problem(among: store.dictionary), "\(entry.written) would be refused")
        }
        XCTAssertEqual(
            store.dictionarySnapshot.replacer(for: .dictation)?.replacing(in: "клод код и гитхаб").text,
            "Claude Code и Github"
        )
    }

    /// Replacing is for moving a dictionary one to one; what the receiving
    /// Mac decides for itself, where it applies and the language, stays.
    func testReplacingTakesTheFileAsItIsAndLeavesTheSwitchesAndTheLanguage() throws {
        let defaults = try makeDefaults()
        let store = SettingsStore(defaults: defaults)
        store.dictionaryInMeetings = false
        store.dictationLanguage = "uk"
        try store.saveDictionary([entry(1, ["клод код"], "Claude"), entry(2, ["гитхаб"], "GitHub")])
        func others() -> NSDictionary {
            (defaults.persistentDomain(forName: suites[0]) ?? [:]).filter { $0.key != Self.key } as NSDictionary
        }
        let before = others()
        let file = [entry(3, ["вскод"], "VS Code"), entry(1, ["клод код"], "Claude Code", enabled: false)]

        let result = try store.importDictionary(file, replacing: true)

        XCTAssertEqual(result, .replaced(2))
        XCTAssertEqual(result.summary, "Dictionary replaced. Entries: 2.")
        XCTAssertEqual(store.dictionary, file)
        XCTAssertEqual(SettingsStore(defaults: defaults).dictionary, file)
        XCTAssertEqual(others(), before)
        XCTAssertFalse(store.dictionaryInMeetings)
        XCTAssertEqual(store.dictationLanguage, "uk")

        _ = try store.importDictionary([entry(4, ["зум"], "Zoom")], replacing: false)
        XCTAssertEqual(others(), before)
    }

    /// The file is read first and the merge starts from the dictionary as it
    /// is when the user answers: an edit made meanwhile stays.
    func testEditMadeWhileTheFileWasReadIsKept() async throws {
        let store = SettingsStore(defaults: try makeDefaults())
        let claude = entry(1, ["клод код"], "Claude Code")
        try store.saveDictionary([claude])
        _ = try await store.exportDictionary(to: exportURL)

        let read = try await SettingsStore.importedDictionary(at: exportURL).get()
        var edited = claude
        edited.written = "Claude"
        let github = entry(2, ["гитхаб"], "GitHub")
        try store.saveDictionary([edited, github])
        let result = try store.importDictionary(read, replacing: false)

        XCTAssertEqual(result, .added(0, turnedOff: 0, matched: 0, kept: 1))
        XCTAssertEqual(store.dictionary, [edited, github])
    }

    func testFailedSaveImportsNothing() throws {
        struct Refused: Error {}
        let defaults = try makeDefaults()
        let refuse = Locked(false)
        let store = SettingsStore(defaults: defaults) { entries in
            if refuse.value { throw Refused() }
            return try SettingsStore.encodedDictionary(entries)
        }
        let claude = entry(1, ["клод код"], "Claude Code")
        try store.saveDictionary([claude])
        let data = defaults.data(forKey: Self.key)
        let snapshot = store.dictionarySnapshot

        refuse.value = true
        for replacing in [false, true] {
            XCTAssertThrowsError(try store.importDictionary([entry(2, ["гитхаб"], "GitHub")], replacing: replacing))
            XCTAssertEqual(defaults.data(forKey: Self.key), data)
            XCTAssertEqual(store.dictionary, [claude])
            XCTAssertEqual(store.dictionarySnapshot, snapshot)
        }
    }

    /// The export ends only when its write does, failed or not: the tab
    /// holds Export and Import until then, so one that returned early would
    /// let a second write race the first.
    func testExportEndsOnlyWhenItsWriteDoes() async throws {
        struct Refused: Error {}
        let defaults = try makeDefaults()
        let store = SettingsStore(defaults: defaults)
        try store.saveDictionary([entry(1, ["клод код"], "Claude Code")])
        for fails in [false, true] {
            let handed = AsyncStream<Data>.makeStream()
            let gate = AsyncStream<Void>.makeStream()
            let returned = Locked(false)
            let export = Task {
                defer { returned.value = true }
                return try await store.exportDictionary(to: exportURL) { data, url in
                    handed.continuation.yield(data)
                    for await _ in gate.stream { break }
                    if fails { throw Refused() }
                    try await SettingsStore.writeWhole(data, url)
                }
            }
            defer { export.cancel(); gate.continuation.finish() }
            var held = handed.stream.makeAsyncIterator()
            let data = await held.next()
            XCTAssertEqual(data, defaults.data(forKey: Self.key), "the write was not handed the settings' bytes")
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertFalse(returned.value, "the export returned while its write was held")

            gate.continuation.yield()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !returned.value, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(returned.value, "the export did not end after its write")
            switch await export.result {
            case .success(let count): XCTAssertFalse(fails, "a failed write passed for an export of \(count)")
            case .failure(let error): XCTAssertTrue(fails && error is Refused, "\(error)")
            }
            try? FileManager.default.removeItem(at: exportURL)
        }
    }

    func testFailedExportChangesNothing() async throws {
        let defaults = try makeDefaults()
        let store = SettingsStore(defaults: defaults)
        try store.saveDictionary([entry(1, ["клод код"], "Claude Code")])
        let data = defaults.data(forKey: Self.key)
        let url = folder.appendingPathComponent("missing", isDirectory: true).appendingPathComponent("Murmurly Dictionary.json")

        do {
            _ = try await store.exportDictionary(to: url)
            XCTFail("a file was written into a folder that is not there")
        } catch {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(defaults.data(forKey: Self.key), data)
    }

    /// Its data is kept as it is: an export would write an empty dictionary,
    /// an import would overwrite what may yet be read by a newer version.
    func testUnreadableDictionaryIsNeitherExportedNorImportedInto() async throws {
        let defaults = try makeDefaults()
        defaults.set(Data("damaged".utf8), forKey: Self.key)
        let store = SettingsStore(defaults: defaults)
        XCTAssertTrue(store.dictionaryUnreadable)

        do {
            _ = try await store.exportDictionary(to: exportURL)
            XCTFail("an unreadable dictionary was exported")
        } catch {}
        for replacing in [false, true] {
            XCTAssertThrowsError(try store.importDictionary([entry(1, ["клод код"], "Claude Code")], replacing: replacing))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
        XCTAssertEqual(defaults.data(forKey: Self.key), Data("damaged".utf8))
    }
}

/// A value a `@Sendable` closure in a test can read while the test changes it.
private final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func dictionaryHistoryLines(in root: URL) throws -> [[String: Any]] {
    let url = root.appendingPathComponent(DictationHistoryStore.historyFileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try Data(contentsOf: url)
        .split(separator: DictationHistoryStore.newline)
        .map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]) }
}

/// Settings → dictation → history and paste, with the real coordinator,
/// store, cache and macOS tagger; only the microphone, the engine and the
/// paste itself are stand-ins.
@MainActor
final class DictationDictionaryTests: XCTestCase {
    private let claudeCode = DictionaryEntry(heard: ["клод код"], written: "Claude Code")

    func testDictationSavesAndPastesTheReplacedTextAndKeepsTheRecognizedOne() async throws {
        try MacOSRussianWordForms.require()
        let fixture = try DictationPipelineFixture(text: " у клода кода готово ")
        defer { fixture.cleanup() }
        try fixture.settings.saveDictionary([claudeCode])

        try await fixture.dictate()

        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["у Claude Code готово"])
        let line = try XCTUnwrap(dictionaryHistoryLines(in: fixture.root).first)
        XCTAssertEqual(line["text"] as? String, "у Claude Code готово")
        XCTAssertEqual(line["raw_text"] as? String, "у клода кода готово")
        let recent = try await fixture.store.recent()
        XCTAssertEqual(recent.map(\.rawText), ["у клода кода готово"])
    }

    /// Without saved audio the line still carries both texts.
    func testRecognizedTextIsKeptWithDictationAudioOff() async throws {
        try MacOSRussianWordForms.require()
        let fixture = try DictationPipelineFixture(text: "у клода кода")
        defer { fixture.cleanup() }
        fixture.settings.saveDictationAudio = false
        try fixture.settings.saveDictionary([claudeCode])

        try await fixture.dictate()

        let line = try XCTUnwrap(dictionaryHistoryLines(in: fixture.root).first)
        XCTAssertEqual(line["audio_path"] as? String, "")
        XCTAssertEqual(line["text"] as? String, "у Claude Code")
        XCTAssertEqual(line["raw_text"] as? String, "у клода кода")
        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["у Claude Code"])
    }

    func testDictationWithoutAReplacementWritesTheLineAsBefore() async throws {
        let fixture = try DictationPipelineFixture(text: "привет мир")
        defer { fixture.cleanup() }
        try fixture.settings.saveDictionary([claudeCode])

        try await fixture.dictate()

        let line = try XCTUnwrap(dictionaryHistoryLines(in: fixture.root).first)
        XCTAssertEqual(line["text"] as? String, "привет мир")
        XCTAssertEqual(Set(line.keys), [
            "schema_version", "id", "source", "at", "duration_seconds", "selected_language",
            "actual_language", "engine", "target_bundle_id", "target_app_name", "audio_path", "text",
        ])
    }

    func testUncheckedDictationKeepsTheRecognizedText() async throws {
        let fixture = try DictationPipelineFixture(text: "у клода кода")
        defer { fixture.cleanup() }
        try fixture.settings.saveDictionary([claudeCode])
        fixture.settings.dictionaryInDictation = false

        try await fixture.dictate()

        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["у клода кода"])
        XCTAssertNil(try XCTUnwrap(dictionaryHistoryLines(in: fixture.root).first)["raw_text"])
    }

    func testDictionaryEditedDuringADictationAppliesToTheNextOne() async throws {
        let fixture = try DictationPipelineFixture(text: "клод код")
        defer { fixture.cleanup() }
        try fixture.settings.saveDictionary([claudeCode])
        fixture.coordinator.beginCaptureForTesting()
        try await waitForDictation { fixture.coordinator.state == .recording }

        try fixture.settings.saveDictionary([DictionaryEntry(heard: ["клод код"], written: "Claude")])
        fixture.coordinator.toggle()
        try await waitForDictation(timeout: .seconds(30)) { fixture.coordinator.state == .idle }
        try await fixture.dictate()

        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["Claude Code", "Claude"])
    }

    func testInterruptedDictationIsReplacedButNotPasted() async throws {
        let fixture = try DictationPipelineFixture(text: "клод код", makeMic: { AdoptedFailingMic(template: $0) })
        defer { fixture.cleanup() }
        try fixture.settings.saveDictionary([claudeCode])

        try await fixture.dictate()

        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, [])
        let line = try XCTUnwrap(dictionaryHistoryLines(in: fixture.root).first)
        XCTAssertEqual(line["interrupted"] as? Bool, true)
        XCTAssertEqual(line["text"] as? String, "Claude Code")
        XCTAssertEqual(line["raw_text"] as? String, "клод код")
    }

    func testUnsavedDictationShowsThePastedText() async throws {
        let fixture = try DictationPipelineFixture(text: "клод код")
        defer { fixture.cleanup() }
        try fixture.settings.saveDictionary([claudeCode])
        try Data("not a directory".utf8).write(to: fixture.root)

        try await fixture.dictate()

        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["Claude Code"])
        XCTAssertEqual(fixture.coordinator.unsavedDictations.map(\.text), ["Claude Code"])
    }

    func testFailedRecognitionHasNoTextToReplace() async throws {
        let fixture = try DictationPipelineFixture(text: "клод код")
        defer { fixture.cleanup() }
        try fixture.settings.saveDictionary([claudeCode])
        await fixture.engine.failNextDecode()

        try await fixture.dictate()

        let line = try XCTUnwrap(dictionaryHistoryLines(in: fixture.root).first)
        XCTAssertEqual(line["recognition_failed"] as? Bool, true)
        XCTAssertEqual(line["text"] as? String, "")
        XCTAssertNil(line["raw_text"])
    }

    // MARK: - The history line

    func testRawTextIsWrittenOnlyWhenSetAndOldLinesStillRead() throws {
        func entry(raw: String?) -> DictationHistoryEntry {
            DictationHistoryEntry(
                id: UUID(), at: Date(timeIntervalSince1970: 1_700_000_000), duration: 1,
                selectedLanguage: "auto", actualLanguage: "ru", targetBundleID: nil,
                targetApplicationName: nil, audioPath: "", text: "Claude Code", rawText: raw
            )
        }
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry(raw: nil))) as? [String: Any]
        XCTAssertNil(plain?["raw_text"])
        let replaced = entry(raw: "клод код")
        let data = try JSONEncoder().encode(replaced)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["raw_text"] as? String, "клод код")
        XCTAssertEqual(try JSONDecoder().decode(DictationHistoryEntry.self, from: data), replaced)

        let old = #"{"schema_version":1,"id":"6F1C9E6A-5B0C-4F55-9C64-1D1B0B8F2A10","source":"dictation","#
            + #""at":1.0,"duration_seconds":1,"selected_language":"auto","actual_language":"ru","#
            + #""audio_path":"","text":"клод код"}"#
        XCTAssertNil(try JSONDecoder().decode(DictationHistoryEntry.self, from: Data(old.utf8)).rawText)
    }

    func testDeletingANeighbourKeepsTheRecognizedText() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Dictations", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let store = DictationHistoryStore(root: root)
        func entry(_ text: String, raw: String) -> DictationHistoryEntry {
            DictationHistoryEntry(
                id: UUID(), at: Date(), duration: 1, selectedLanguage: "auto", actualLanguage: "ru",
                targetBundleID: nil, targetApplicationName: nil, audioPath: "", text: text, rawText: raw
            )
        }
        let kept = entry("Claude Code", raw: "клод код")
        try await store.append(kept)
        try await store.append(entry("GitHub", raw: "гитхаб"))
        let before = try Data(contentsOf: root.appendingPathComponent(DictationHistoryStore.historyFileName))
            .split(separator: DictationHistoryStore.newline).first

        let neighbour = try await store.recent().first { $0.text == "GitHub" }
        _ = try await store.delete(id: XCTUnwrap(neighbour).id)

        let lines = try Data(contentsOf: root.appendingPathComponent(DictationHistoryStore.historyFileName))
            .split(separator: DictationHistoryStore.newline)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first, before, "the remaining line is copied as it was")
        let remaining = try await store.recent()
        XCTAssertEqual(remaining.map(\.rawText), ["клод код"])
    }
}

/// The entry sheet as SwiftUI builds it in a window that is never shown,
/// with the real store: what its preview shows while settings change
/// outside the sheet.
@MainActor
final class DictionarySheetTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        suiteName = "io.github.spacevibes365.MurmurlyTests.DictionarySheet.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil }
        windows = []
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func host(_ view: some View, _ settings: SettingsStore) -> NSView {
        let hosting = NSHostingView(rootView: view.environmentObject(settings))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        windows.append(window)
        return hosting
    }

    /// The preview is the sheet's one text that can be selected but not
    /// edited, and SwiftUI keeps selectable text in a text field of its own.
    /// Accessibility elements, which UI tests read, are built only for an
    /// assistive client, so here the view tree is what can be read.
    private func previewText(in view: NSView) -> String? {
        if let field = view as? NSTextField {
            return field.isEditable ? nil : field.stringValue
        }
        return view.subviews.lazy.compactMap { self.previewText(in: $0) }.first
    }

    /// SwiftUI builds and updates on later turns of the main actor; nil
    /// when nothing came within 5 s.
    private func eventually<T>(_ read: () -> T?) async throws -> T? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let value = read() { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        return read()
    }

    func testPreviewFollowsALanguageChosenWhileTheSheetIsOpen() async throws {
        try MacOSRussianWordForms.require()
        let settings = SettingsStore(defaults: defaults)
        // Ukrainian turns Russian word forms off: the example stays as it is.
        settings.dictationLanguage = "uk"
        let sheet = host(DictionaryEntrySheet(
            entry: DictionaryEntry(heard: ["клод код"], written: "Claude Code"),
            example: "у клода кода"
        ), settings)
        let before = try await eventually { previewText(in: sheet) }
        XCTAssertEqual(before, "у клода кода", "no preview")

        // As the menu bar's language menu does, with no field touched.
        settings.dictationLanguage = "auto"

        let after = try await eventually { previewText(in: sheet).flatMap { $0 == before ? nil : $0 } }
        XCTAssertEqual(after, "у Claude Code", "the preview kept the answer for the language before")
    }

    // MARK: - From the history

    private func dictation(text: String, rawText: String?) -> DictationHistoryEntry {
        DictationHistoryEntry(
            id: UUID(), at: Date(), duration: 1, selectedLanguage: "auto", actualLanguage: "ru",
            targetBundleID: nil, targetApplicationName: nil, audioPath: "", text: text, rawText: rawText
        )
    }

    /// The dictation's copy: TextEditor keeps it in a text view of its own.
    private func sourceText(in view: NSView) -> String? {
        if let textView = view as? NSTextView, !textView.isFieldEditor { return textView.string }
        return view.subviews.lazy.compactMap { self.sourceText(in: $0) }.first
    }

    private func editableFields(in view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField { return field.isEditable ? [field] : [] }
        return view.subviews.flatMap { editableFields(in: $0) }
    }

    /// The history row shows the text after the dictionary; the sheet shows
    /// what the engine wrote, and tries the entry on it.
    func testSheetFromADictationShowsItsTextAsRecognized() async throws {
        let settings = SettingsStore(defaults: defaults)
        let replaced = host(DictionaryEntrySheet(
            dictation: dictation(text: "Claude Code готов", rawText: "клод код готов")
        ), settings)
        let source = try await eventually { sourceText(in: replaced) }
        XCTAssertEqual(source, "клод код готов")
        XCTAssertTrue(editableFields(in: replaced).contains { $0.stringValue == "клод код готов" }, "“Try it” holds another text")
        let preview = try await eventually { previewText(in: replaced) }
        XCTAssertEqual(preview, "клод код готов", "nothing is in the dictionary yet")

        let plain = host(DictionaryEntrySheet(dictation: dictation(text: "просто текст", rawText: nil)), settings)
        let plainSource = try await eventually { sourceText(in: plain) }
        XCTAssertEqual(plainSource, "просто текст")
    }

    /// Every text of the view that can be selected but not edited.
    private func selectableTexts(in view: NSView) -> [String] {
        if let field = view as? NSTextField { return field.isEditable ? [] : [field.stringValue] }
        return view.subviews.flatMap { selectableTexts(in: $0) }
    }

    /// From a transcript the sheet gets plain text, no history line: the
    /// line the selection began in, to select in and to try the entry on,
    /// and the selection in "Heard as" when it is one spelling. One that is
    /// not (a comma, a line break, several stretches) leaves the field
    /// empty and says why. While the dictionary cannot be read, nothing.
    func testSheetFromATranscriptTakesThePlainTextAndItsSelection() async throws {
        let settings = SettingsStore(defaults: defaults)
        let line = "Открываем клод код и смотрим"
        let sheet = host(DictionaryEntrySheet(transcript: line, selected: " клод код "), settings)
        let source = try await eventually { sourceText(in: sheet) }
        XCTAssertEqual(source, line)
        let fields = try await eventually { editableFields(in: sheet).count == 3 ? editableFields(in: sheet).map(\.stringValue) : nil }
        XCTAssertEqual(fields?.first, "клод код", "the selection is not the spelling")
        XCTAssertTrue(fields?.contains(line) == true, "“Try it” holds another text: \(fields ?? [])")
        let preview = try await eventually { previewText(in: sheet) }
        XCTAssertEqual(preview, line)

        let refusals: [(String?, String)] = [
            ("клод, код", DictionaryEntry.Problem.punctuation("клод, код").message),
            ("код\n\n[0:07]  Me: дальше", DictionaryEntry.Problem.lineBreak.message),
            (nil, String(localized: "Select one stretch of words: several were selected.")),
        ]
        for (selected, reason) in refusals {
            let refused = host(DictionaryEntrySheet(transcript: line, selected: selected), settings)
            let empty = try await eventually { editableFields(in: refused).count == 3 ? editableFields(in: refused).first?.stringValue : nil }
            XCTAssertEqual(empty, "", "\(selected ?? "several"): the field took what the rule refuses")
            let shown = try await eventually { selectableTexts(in: refused).contains(reason) ? reason : nil }
            XCTAssertEqual(shown, reason, "\(selected ?? "several"): the reason is not shown")
        }

        defaults.set("not a dictionary", forKey: "dictionary.entries")
        let locked = SettingsStore(defaults: defaults)
        let unreadable = host(DictionaryEntrySheet(transcript: line, selected: "клод код"), locked)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(editableFields(in: unreadable).count, 0, "the sheet offers fields it could not save")
    }

    /// The tab locks editing until the dictionary is cleared there; a way in
    /// from the history gets the same lock from the sheet itself.
    func testSheetFromADictationTakesNoEntryWhileTheDictionaryCannotBeRead() async throws {
        defaults.set("not a dictionary", forKey: "dictionary.entries")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.dictionaryUnreadable)
        let sheet = host(DictionaryEntrySheet(dictation: dictation(text: "клод код", rawText: nil)), settings)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(editableFields(in: sheet).count, 0, "the sheet offers fields it could not save")
        XCTAssertNil(sourceText(in: sheet))

        // The same sheet, once cleared, takes an entry: the check above saw
        // a built view, not an empty one.
        settings.clearDictionary()
        let fields = try await eventually { editableFields(in: sheet).count == 3 ? 3 : nil }
        XCTAssertEqual(fields, 3)
    }
}
