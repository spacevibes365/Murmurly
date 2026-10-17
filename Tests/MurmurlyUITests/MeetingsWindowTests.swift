import AppKit
import CoreGraphics
import CryptoKit
import XCTest

/// The Murmurly window in a live process: opened from the menu over meetings
/// seeded before launch (`-MeetingsProbeRoot`), side by side with Settings,
/// and when the running app is opened again.
@MainActor
final class MeetingsWindowTests: XCTestCase {
    private var root: URL!
    private let meeting = "2026-10-14 10-00-00 Meeting"
    private let brokenOff = "2026-10-14 12-00-00 Meeting"

    override func setUp() async throws {
        continueAfterFailure = false
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetings-window-\(UUID().uuidString)", isDirectory: true)
        // Compressed tracks, so the launch scan finds no work to start.
        let metadata = """
        {"startedAt":"2026-10-14T10:00:00Z","endedAt":"2026-10-14T11:16:00Z","sampleRate":48000,"state":"done",\
        "trigger":"manual","segments":[{"index":0,"system":"system.m4a","mic":"microphone.m4a"}]}
        """
        let transcript = """
        # Meeting 14 October 2026

        Automatic transcript. Engine: Parakeet (parakeet). Language: auto.

        ---

        [0:05] **Me:** Начнём с отчёта.

        [1:02:03] **Others:** Спустя час всё ещё говорим.

        """
        try write([
            "metadata.json": metadata, "system.m4a": "audio", "microphone.m4a": "audio", "transcript.md": transcript,
        ], into: meeting)
        try write(["system.caf": "audio"], into: brokenOff)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: trash)
    }

    func testMenuOpensTheWindowWithSeededMeetingsAndTheirText() throws {
        let app = launch()
        defer { app.terminate() }
        XCTAssertEqual(app.windows.count, 0, "a launch must stay in the menu bar")

        openMainWindow(in: app)

        let row = app.descendants(matching: .any)["meetingRow.\(meeting)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the seeded meeting is not listed")
        let broken = app.descendants(matching: .any)["meetingRow.\(brokenOff)"]
        XCTAssertTrue(broken.waitForExistence(timeout: 5), "the recording that broke off is not listed")
        XCTAssertTrue(
            (broken.label + (broken.value as? String ?? "")).contains(AppLanguage.text("Recording broke off")),
            "“\(broken.label)” does not say it broke off"
        )
        // Transcribed before attempt records: no promise that it is whole.
        let rowText = row.label + (row.value as? String ?? "")
        XCTAssertTrue(rowText.contains(AppLanguage.text("Transcribed, completeness unknown")), "“\(rowText)”")
        XCTAssertFalse(rowText.contains(AppLanguage.text("Fully transcribed")), "“\(rowText)” promises a whole transcript")
        row.click()

        let text = app.textViews["meetingTranscriptText"]
        XCTAssertTrue(text.waitForExistence(timeout: 10), "no transcript text")
        let shown = text.value as? String ?? ""
        XCTAssertTrue(shown.contains("[1:02:03]"), shown)
        XCTAssertTrue(shown.contains("Спустя час всё ещё говорим."), shown)
        XCTAssertTrue(shown.contains("Meeting 14 October 2026"), "the header is not shown: \(shown)")
    }

    /// The star and a name set on the card stay: in the row, under Starred,
    /// after the window closes and opens again, and in the meeting's own
    /// murmurly.json. The name is typed in digits, as no keyboard layout
    /// changes them.
    func testStarAndNameFromTheCardStay() throws {
        let app = launch()
        defer { app.terminate() }
        openMainWindow(in: app)
        let row = app.descendants(matching: .any)["meetingRow.\(meeting)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()

        let star = app.buttons["meetingCardStar"]
        XCTAssertTrue(star.waitForExistence(timeout: 5))
        star.click()
        app.buttons["meetingRename"].click()
        let field = app.textFields["meetingTitleField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("2042")
        field.typeKey(.return, modifierFlags: [])

        let named = app.descendants(matching: .any)["meetingRow.\(meeting)"]
        XCTAssertTrue(waitUntil { (named.label + (named.value as? String ?? "")).contains("2042") }, "the row kept its old title")
        app.descendants(matching: .any)["mainSection.starred"].click()
        XCTAssertTrue(app.descendants(matching: .any)["meetingRow.\(meeting)"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["meetingRow.\(brokenOff)"].exists, "Starred lists a meeting without a star")

        close(mainWindow(in: app))
        openMainWindow(in: app)
        let again = app.descendants(matching: .any)["meetingRow.\(meeting)"]
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        XCTAssertTrue((again.label + (again.value as? String ?? "")).contains("2042"))
        let marks = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent(meeting).appendingPathComponent("murmurly.json"))
        ) as? [String: Any]
        XCTAssertEqual(marks?["title"] as? String, "2042")
        XCTAssertEqual(marks?["starred"] as? Bool, true)
    }

    /// A name is saved as in Finder: a click elsewhere, on the transcript or
    /// on the card's empty part, or another meeting saves it; only Esc drops
    /// it. Typed in digits, as no keyboard layout changes them.
    func testANameIsSavedByAClickElsewhereAndDroppedByEscape() throws {
        let app = launch()
        defer { app.terminate() }
        openMainWindow(in: app)
        let row = app.descendants(matching: .any)["meetingRow.\(meeting)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let field = app.textFields["meetingTitleField"]
        func type(_ digits: String) {
            app.buttons["meetingRename"].click()
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.typeText(digits)
        }
        func shown() -> String { row.label + (row.value as? String ?? "") }

        type("1111")
        field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(field.waitForNonExistence(timeout: 5), "Esc left the name being typed")
        XCTAssertFalse(shown().contains("1111"), "Esc saved the name")

        type("2222")
        app.textViews["meetingTranscriptText"].click()
        XCTAssertTrue(waitUntil { shown().contains("2222") }, "a click on the transcript dropped the name")

        type("3333")
        // The empty stretch right of Transcribe Again…, the last of its row.
        let left = app.buttons["meetingTranscribeAgain"].frame
        let window = mainWindow(in: app)
        window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: left.maxX + 60 - window.frame.minX, dy: left.midY - window.frame.minY))
            .click()
        XCTAssertTrue(waitUntil { shown().contains("3333") }, "a click on the card's empty part dropped the name")

        type("4444")
        app.descendants(matching: .any)["meetingRow.\(brokenOff)"].click()
        XCTAssertTrue(waitUntil { shown().contains("4444") }, "choosing another meeting dropped the name")
        let marks = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent(meeting).appendingPathComponent("murmurly.json"))
        ) as? [String: Any]
        XCTAssertTrue((marks?["title"] as? String)?.hasSuffix("4444") == true, "\(String(describing: marks))")
        XCTAssertFalse((marks?["title"] as? String)?.contains("1111") == true, "Esc saved the name")
    }

    /// Deleting from the window: one meeting's audio from its card, then two
    /// meetings at once from the batch card. Each asks first, names what
    /// else goes, and puts it in the (test's) Trash; the transcript of the
    /// first stays. ⌘⌫ while a name is typed deletes nothing.
    func testDeletingAudioAndMeetingsFromTheWindow() throws {
        let second = "2026-10-14 14-00-00 Meeting"
        let third = "2026-10-14 15-00-00 Meeting"
        let metadata = """
        {"startedAt":"2026-10-14T14:00:00Z","endedAt":"2026-10-14T14:30:00Z","sampleRate":48000,"state":"done",\
        "segments":[{"index":0,"system":"system.m4a","mic":"microphone.m4a"}]}
        """
        try write(["metadata.json": metadata, "system.m4a": "audio", "microphone.m4a": "audio", "tasks.md": "дела"], into: second)
        try write(["metadata.json": metadata, "system.m4a": "audio", "microphone.m4a": "audio"], into: third)
        let app = launch()
        defer { app.terminate() }
        openMainWindow(in: app)
        let row = app.descendants(matching: .any)["meetingRow.\(meeting)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()

        app.descendants(matching: .any)["meetingRename"].click()
        let field = app.textFields["meetingTitleField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("12")
        field.typeKey(.delete, modifierFlags: .command)
        XCTAssertFalse(app.descendants(matching: .any)["removalSheet"].waitForExistence(timeout: 1), "⌘⌫ in the name asked to delete")
        field.typeKey(.escape, modifierFlags: [])

        app.descendants(matching: .any)["meetingDeleteMenu"].click()
        app.menuItems[AppLanguage.text("Delete Audio…")].click()
        XCTAssertTrue(app.descendants(matching: .any)["removalSheet"].waitForExistence(timeout: 5))
        app.buttons["removalConfirm"].click()
        XCTAssertTrue(waitUntil { (row.label + (row.value as? String ?? "")).contains(AppLanguage.text("No audio")) },
                      "the row does not say the audio went")
        let folder = root.appendingPathComponent(meeting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path))

        let secondRow = app.descendants(matching: .any)["meetingRow.\(second)"]
        let thirdRow = app.descendants(matching: .any)["meetingRow.\(third)"]
        secondRow.click()
        XCUIElement.perform(withKeyModifiers: .command) { thirdRow.click() }
        let batch = app.buttons["batchDeleteMeetings"]
        XCTAssertTrue(batch.waitForExistence(timeout: 5), "no card for the two meetings selected")
        batch.click()
        let sheet = app.descendants(matching: .any)["removalSheet"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        XCTAssertTrue(sheet.staticTexts.allElementsBoundByIndex.contains { ($0.label + ($0.value as? String ?? "")).contains("tasks.md") },
                      "the sheet does not name the file that goes too")
        app.buttons["removalConfirm"].click()
        XCTAssertTrue(secondRow.waitForNonExistence(timeout: 10))
        XCTAssertTrue(thirdRow.waitForNonExistence(timeout: 10))
        for name in [second, third] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path), name)
        }
        let trashed = (try? FileManager.default.subpathsOfDirectory(atPath: trash.path)) ?? []
        XCTAssertTrue(trashed.contains { $0.hasSuffix(second) } && trashed.contains { $0.hasSuffix(third) }, "\(trashed)")
    }

    /// The audio rule: choosing one asks first, Cancel keeps the setting,
    /// Continue sets it and the audio of a meeting transcribed in full long
    /// ago goes; its transcript stays.
    func testTheAudioRuleAsksFirstAndThenDeletes() throws {
        let old = "2026-08-01 10-00-00 Meeting"
        let text = "# Meeting\n\n---\n\n[0:05] **Me:** текст\n"
        let bytes = Data(text.utf8)
        let record = """
        {"version":1,"number":1,"result":"complete","startedAt":"2026-08-01T11:00:00Z","endedAt":"2026-08-01T11:01:00Z",\
        "transcript":"transcript.md","engines":[],"languages":[],"failedChunks":0,"cutShort":false,"missingTracks":[],"lines":[],\
        "fingerprint":{"bytes":\(bytes.count),"sha256":"\(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())"}}
        """
        let metadata = """
        {"startedAt":"2026-08-01T10:00:00Z","endedAt":"2026-08-01T10:30:00Z","sampleRate":48000,"state":"done",\
        "segments":[{"index":0,"system":"system.m4a","mic":"microphone.m4a"}]}
        """
        try write([
            "metadata.json": metadata, "system.m4a": "audio", "microphone.m4a": "audio", "transcript.md": text,
            ".attempt 0001 \(UUID().uuidString).murmurly.json": record,
        ], into: old)
        let folder = root.appendingPathComponent(old)
        let app = launch()
        defer { app.terminate() }
        openSettings(in: app)
        app.buttons["settingsTab.meetings"].click()
        let month = app.descendants(matching: .any)["meetingAudioRule.30"]
        XCTAssertTrue(month.waitForExistence(timeout: 5))

        month.click()
        let question = app.descendants(matching: .any)["audioRuleQuestion"]
        XCTAssertTrue(question.waitForExistence(timeout: 10), "no question before the rule")
        app.buttons["audioRuleCancel"].click()
        XCTAssertTrue(question.waitForNonExistence(timeout: 5))
        XCTAssertFalse(month.isSelected, "the rule was set without a yes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.m4a").path))

        // The copy is isolated whatever its environment: the yes goes to its
        // own settings, never the owner's domain.
        let ownersRule = ownersPreference("meeting.audioRetentionDays")
        month.click()
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        app.buttons["audioRuleContinue"].click()
        XCTAssertTrue(waitUntil(seconds: 15) {
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent("system.m4a").path)
                && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("microphone.m4a").path)
        }, "the old audio stayed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("transcript.md").path))
        XCTAssertTrue(month.isSelected)
        assertOwnersPreference("meeting.audioRetentionDays", stays: ownersRule, "the test copy set the owner's audio rule")
    }

    /// The card's player, on the probe's silent tracks: Play, 15 seconds on,
    /// Space in the text pauses.
    func testThePlayerPlaysAndSpaceInTheTextPauses() throws {
        let app = launch()
        defer { app.terminate() }
        openMainWindow(in: app)
        let row = app.descendants(matching: .any)["meetingRow.\(meeting)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()

        let play = app.buttons["meetingPlay"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "no player on the card")
        let time = app.staticTexts["meetingPlayerTime"]
        XCTAssertTrue(time.waitForExistence(timeout: 5))
        // A static text's words are its value on macOS.
        func shown() -> String { (time.value as? String ?? "") + time.label }
        XCTAssertTrue(shown().hasSuffix("1:30"), "the timeline is not the tracks' length: \(shown())")
        play.click()
        XCTAssertTrue(waitUntil { play.value as? String == "playing" }, "Play did not play")
        app.buttons["meetingOn"].click()
        XCTAssertTrue(waitUntil { shown().hasPrefix("0:1") }, "15 seconds on did not move: \(shown())")

        let text = app.textViews["meetingTranscriptText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.click()
        app.typeKey(" ", modifierFlags: [])
        XCTAssertTrue(waitUntil { play.value as? String == "paused" }, "Space in the text did not pause")
    }

    /// The search of all meetings keeps the meeting found, with its count;
    /// the rest of the list goes until the search is cleared. Digits only:
    /// a test types through the active keyboard layout.
    func testSearchKeepsTheMeetingsFound() throws {
        let other = "2026-10-13 10-00-00 Meeting"
        try write([
            "metadata.json": """
            {"startedAt":"2026-10-13T10:00:00Z","endedAt":"2026-10-13T10:30:00Z","sampleRate":48000,"state":"done",\
            "segments":[{"index":0,"system":"system.m4a","mic":"microphone.m4a"}]}
            """,
            "system.m4a": "audio", "microphone.m4a": "audio",
            "transcript.md": "# Meeting\n\n---\n\n[0:05] **Me:** код 4815 и ещё раз 4815\n",
        ], into: other)
        let app = launch()
        defer { app.terminate() }
        openMainWindow(in: app)
        let found = app.descendants(matching: .any)["meetingRow.\(other)"]
        let notFound = app.descendants(matching: .any)["meetingRow.\(meeting)"]
        XCTAssertTrue(found.waitForExistence(timeout: 10))
        XCTAssertTrue(notFound.exists)

        let field = app.textFields["meetingSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search field above the list")
        field.click()
        field.typeText("4815")
        XCTAssertTrue(waitUntil(seconds: 10) { !notFound.exists }, "a meeting without the number stayed in the list")
        XCTAssertTrue(found.exists, "the meeting with the number left the list")
        let count = AppLanguage.text("%lld matches", 2)
        XCTAssertTrue(waitUntil { (found.label + (found.value as? String ?? "")).contains(count) }, "no “\(count)” on the row: \(found.label)")
        app.typeKey(.return, modifierFlags: [])
        let text = app.textViews["meetingTranscriptText"]
        XCTAssertTrue(waitUntil(seconds: 10) { (text.value as? String ?? "").contains("4815") }, "Return did not open the meeting found")
        // Which match of how many, and the way to the next.
        let position = app.staticTexts["meetingMatchPosition"]
        func shown() -> String { (position.value as? String ?? "") + position.label }
        XCTAssertTrue(position.waitForExistence(timeout: 5), "no match position on the card")
        let first = AppLanguage.text("%lld of %lld", 1, 2)
        XCTAssertTrue(waitUntil { shown().contains(first) }, "not “\(first)”: \(shown())")
        app.buttons["meetingMatchNext"].click()
        let second = AppLanguage.text("%lld of %lld", 2, 2)
        XCTAssertTrue(waitUntil { shown().contains(second) }, "the next match was not taken: \(shown())")

        app.buttons["meetingSearchClear"].click()
        XCTAssertTrue(notFound.waitForExistence(timeout: 5), "clearing the search did not bring the list back")
    }

    /// A transcript with the record of its attempt takes the speakers' names
    /// typed in its sheet: the card's text shows them, and Save As writes
    /// them into the file the probe answers with, named after the meeting.
    /// The transcript itself stays byte for byte; the names are in
    /// murmurly.json. A transcript from before records takes no names and
    /// no subtitles. Names in digits, as no keyboard layout changes them.
    func testNamesShowInTheTextAndTheSavedFile() throws {
        let recorded = "2026-10-13 09-00-00 Meeting"
        let markdown = "# Meeting\n\nAutomatic transcript.\n\n---\n\n[0:05] **Me:** Начнём.\n\n[0:09] **Others:** Хорошо.\n"
        let bytes = Data(markdown.utf8)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let attempt = """
            {"version":1,"number":1,"result":"complete","startedAt":"2026-10-13T09:40:00Z","endedAt":"2026-10-13T09:41:00Z",\
            "transcript":"transcript.md","engines":["whisper"],"languages":["auto"],"failedChunks":0,"cutShort":false,\
            "missingTracks":[],"speakers":{"microphone":"Me","system":"Others"},\
            "lines":[{"start":5,"end":7,"source":"microphone"},{"start":9,"end":11,"source":"system"}],\
            "fingerprint":{"bytes":\(bytes.count),"sha256":"\(sha)"}}
            """
        try write([
            "metadata.json": """
            {"startedAt":"2026-10-13T09:00:00Z","endedAt":"2026-10-13T09:30:00Z","sampleRate":48000,"state":"done",\
            "segments":[{"index":0,"system":"system.m4a","mic":"microphone.m4a"}]}
            """,
            "system.m4a": "audio", "microphone.m4a": "audio", "transcript.md": markdown,
            ".attempt 0001 \(UUID().uuidString).murmurly.json": attempt,
        ], into: recorded)
        let probe = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probe) }
        let app = launch(["-FileProbeRoot", probe.path])
        defer { app.terminate() }
        openMainWindow(in: app)
        let row = app.descendants(matching: .any)["meetingRow.\(recorded)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let text = app.textViews["meetingTranscriptText"]
        XCTAssertTrue(waitUntil(seconds: 10) { (text.value as? String ?? "").contains("Хорошо.") }, "no transcript text")

        let names = app.buttons["meetingNames"]
        XCTAssertTrue(names.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { names.isEnabled }, "Names is off for a transcript with its record")
        names.click()
        let microphone = app.textFields["meetingNamesMicrophone"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 5), "no names sheet")
        microphone.click()
        microphone.typeText("11")
        let system = app.textFields["meetingNamesSystem"]
        system.click()
        system.typeText("22")
        app.buttons["meetingNamesSave"].click()
        XCTAssertTrue(app.descendants(matching: .any)["meetingNamesSheet"].waitForNonExistence(timeout: 5), "the sheet stayed")
        XCTAssertTrue(waitUntil { (text.value as? String ?? "").contains("11: Начнём.") }, "the text kept its labels: \(text.value ?? "")")
        XCTAssertTrue((text.value as? String ?? "").contains("22: Хорошо."))

        app.descendants(matching: .any)["meetingSaveAs"].click()
        app.menuItems[AppLanguage.text("Markdown…")].click()
        let saved = probe.appendingPathComponent("meeting-export-1.md")
        XCTAssertTrue(waitUntil(seconds: 10) { FileManager.default.fileExists(atPath: saved.path) }, "nothing was saved")
        let file = try String(contentsOf: saved, encoding: .utf8)
        XCTAssertTrue(file.contains("[0:05] **11:** Начнём."), file)
        XCTAssertTrue(file.contains("[0:09] **22:** Хорошо."), file)
        XCTAssertEqual(try String(contentsOf: probe.appendingPathComponent("meeting-export-1.name"), encoding: .utf8),
                       "2026-10-13 09-00 Meeting.md")
        let folder = root.appendingPathComponent(recorded)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("transcript.md")), bytes, "the transcript changed")
        let marks = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("murmurly.json"))) as? [String: Any]
        XCTAssertEqual(marks?["speakers"] as? [String: String], ["microphone": "11", "system": "22"])

        // From before records: no names, no subtitles.
        let old = app.descendants(matching: .any)["meetingRow.\(meeting)"]
        old.click()
        XCTAssertTrue(waitUntil(seconds: 10) { (text.value as? String ?? "").contains("Спустя час") })
        XCTAssertFalse(app.buttons["meetingNames"].isEnabled, "Names is on for a transcript without its record")
        app.descendants(matching: .any)["meetingSaveAs"].click()
        let subtitles = app.menuItems[AppLanguage.text("SRT Subtitles…")]
        XCTAssertTrue(subtitles.waitForExistence(timeout: 5))
        XCTAssertFalse(subtitles.isEnabled, "subtitles are offered without exact times")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// Save As with its panel held and the window closed meanwhile saves
    /// nothing, and holds no save: the next Save As, with the window open
    /// again, writes its file.
    func testAHeldSaveAsComesNowhereWithItsWindow() throws {
        let probe = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probe) }
        try Data().write(to: probe.appendingPathComponent("present.hold"))
        let app = launch(["-FileProbeRoot", probe.path])
        defer { app.terminate() }
        func saveMarkdown() {
            openMainWindow(in: app)
            let row = app.descendants(matching: .any)["meetingRow.\(meeting)"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.click()
            let text = app.textViews["meetingTranscriptText"]
            XCTAssertTrue(waitUntil(seconds: 10) { (text.value as? String ?? "").contains("Начнём") }, "no transcript text")
            app.descendants(matching: .any)["meetingSaveAs"].click()
            app.menuItems[AppLanguage.text("Markdown…")].click()
        }
        func probeFile(_ name: String) -> URL { probe.appendingPathComponent(name) }

        saveMarkdown()
        XCTAssertTrue(waitUntil(seconds: 10) { FileManager.default.fileExists(atPath: probeFile("present-1.holding").path) }, "the panel was not held")
        close(mainWindow(in: app))
        try Data().write(to: probeFile("present-1.release"))
        XCTAssertTrue(waitUntil(seconds: 10) { FileManager.default.fileExists(atPath: probeFile("present-1.cancelled").path) },
                      "the panel came for a window that was gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: probeFile("meeting-export-1.md").path), "a save went on without its window")

        try FileManager.default.removeItem(at: probeFile("present.hold"))
        saveMarkdown()
        XCTAssertTrue(waitUntil(seconds: 10) { FileManager.default.fileExists(atPath: probeFile("meeting-export-1.md").path) },
                      "the next Save As was held by the one that never came")
    }

    /// The meetings out of sight take no keys: the transcript that had the
    /// focus gives it up, so Space starts no sound; ⌘⌫ asks about no
    /// deletion from the hidden list; the name being typed is saved as by a
    /// click elsewhere. Digits only: a test types through the active
    /// keyboard layout. ⌘F and the find bar: `testAHiddenTranscriptAndItsFindBarTakeNoKeys`.
    func testHiddenMeetingsTakeNoKeys() throws {
        let app = launch()
        defer { app.terminate() }
        openMainWindow(in: app)
        let row = app.descendants(matching: .any)["meetingRow.\(meeting)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let text = app.textViews["meetingTranscriptText"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let play = app.buttons["meetingPlay"]
        XCTAssertTrue(waitUntil(seconds: 10) { play.isEnabled }, "the player did not load")

        text.click()
        guard app.transcribeAFileFromMenuBar() else { return }
        app.typeKey(" ", modifierFlags: [])
        guard app.showMainSection("meetings") else { return }
        XCTAssertEqual(play.value as? String, "paused", "Space started the hidden meeting's sound")

        row.click()
        guard app.transcribeAFileFromMenuBar() else { return }
        app.typeKey(.delete, modifierFlags: .command)
        XCTAssertFalse(app.descendants(matching: .any)["removalSheet"].waitForExistence(timeout: 2), "⌘⌫ asked about the hidden list's meeting")
        guard app.showMainSection("meetings") else { return }

        app.buttons["meetingRename"].click()
        let field = app.textFields["meetingTitleField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("77")
        guard app.transcribeAFileFromMenuBar(), app.showMainSection("meetings") else { return }
        XCTAssertFalse(field.exists, "the name was still being typed on the hidden card")
        let folder = root.appendingPathComponent(meeting)
        XCTAssertTrue(waitUntil(seconds: 5) {
            ((try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("murmurly.json")))) as? [String: Any])?["title"] as? String == "77"
        }, "the name typed was not saved as the card went out of sight")
    }

    /// What ends while its meeting is out of sight is said above whatever
    /// section the window shows: a save that finished while the window was
    /// on Files, and a change of a meeting's marks that failed while it was
    /// on the dictionary. Refresh is the meetings' own: off elsewhere, and
    /// ⌘R there reads nothing.
    func testLateOutcomesShowAboveEverySection() throws {
        let chosen = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-chosen", isDirectory: true)
        let probe = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-probe", isDirectory: true)
        for folder in [chosen, probe] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { for folder in [chosen, probe] { try? FileManager.default.removeItem(at: folder) } }
        let elsewhere = "2026-10-13 09-00-00 Meeting"
        _ = try writeRecorded(elsewhere, lines: [("microphone", "Me", "раз")])
        try FileManager.default.moveItem(at: root.appendingPathComponent(elsewhere), to: chosen.appendingPathComponent(elsewhere))
        func gate(_ name: String) throws { try Data().write(to: probe.appendingPathComponent(name)) }
        func reached(_ name: String) -> Bool {
            waitUntil(seconds: 10) { FileManager.default.fileExists(atPath: probe.appendingPathComponent(name).path) }
        }
        try gate("present.hold")
        try gate("marks-1.hold")
        let app = launch(["-FileProbeRoot", probe.path, "-meeting.storageFolder", chosen.path])
        defer { app.terminate() }
        openMainWindow(in: app)
        let window = mainWindow(in: app)
        let own = app.descendants(matching: .any)["meetingRow.\(meeting)"]
        XCTAssertTrue(own.waitForExistence(timeout: 10))
        own.click()
        let text = app.textViews["meetingTranscriptText"]
        XCTAssertTrue(waitUntil(seconds: 10) { (text.value as? String ?? "").contains("Начнём") }, "no transcript text")
        app.descendants(matching: .any)["meetingSaveAs"].click()
        app.menuItems[AppLanguage.text("Markdown…")].click()
        XCTAssertTrue(reached("present-1.holding"), "the save's panel was not held")
        guard app.transcribeAFileFromMenuBar() else { return }
        XCTAssertFalse(window.buttons["mainRefresh"].isEnabled, "Refresh is on in Files")
        try gate("present-1.release")
        XCTAssertTrue(window.descendants(matching: .any)["meetingExportNotice"].waitForExistence(timeout: 10),
                      "the save that ended in Files was said nowhere in sight")
        window.buttons["meetingExportNoticeHide"].click()

        guard app.showMainSection("meetings") else { return }
        let other = app.descendants(matching: .any)["meetingRow.\(elsewhere)"]
        XCTAssertTrue(other.waitForExistence(timeout: 10), "the meeting in the chosen folder is not listed")
        other.click()
        let star = app.buttons["meetingCardStar"]
        XCTAssertTrue(waitUntil(seconds: 10) { star.isEnabled })
        star.click()
        XCTAssertTrue(reached("marks-1.writing"), "the star's write was not held")
        guard app.showMainSection("dictionary") else { return }
        try gate("marks-1.fail")
        XCTAssertTrue(window.descendants(matching: .any)["meetingMarkNotice"].waitForExistence(timeout: 10),
                      "the star that failed while the dictionary showed was said nowhere in sight")

    }

    /// ⌘R away from the meetings reads nothing: a meeting added meanwhile
    /// shows only once the meetings read again. The key goes through the
    /// active keyboard layout: on another than a Latin one the check is
    /// skipped, never passed without the key.
    func testCommandRReadsNothingAwayFromTheMeetings() throws {
        let key = physicalCharacter(of: 15)  // kVK_ANSI_R
        try XCTSkipUnless(key == "r", "⌘R through typeKey depends on the keyboard layout: the physical key gives \(key.map { "“\($0)”" } ?? "an unknown character"), not an r")
        let app = launch()
        defer { app.terminate() }
        openMainWindow(in: app)
        let window = mainWindow(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["meetingRow.\(meeting)"].waitForExistence(timeout: 10))
        guard app.showMainSection("files") else { return }
        XCTAssertFalse(window.buttons["mainRefresh"].isEnabled, "Refresh is on in Files")
        let added = "2026-10-15 09-00-00 Meeting"
        try write(["metadata.json": """
            {"startedAt":"2026-10-15T09:00:00Z","endedAt":"2026-10-15T09:30:00Z","sampleRate":48000,"state":"done",\
            "trigger":"manual","segments":[{"index":0,"system":"system.m4a","mic":"microphone.m4a"}]}
            """, "system.m4a": "audio", "microphone.m4a": "audio"], into: added)
        app.typeKey("r", modifierFlags: .command)
        guard app.showMainSection("meetings") else { return }
        let new = app.descendants(matching: .any)["meetingRow.\(added)"]
        XCTAssertFalse(new.waitForExistence(timeout: 2), "⌘R read the meetings from another section")
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(new.waitForExistence(timeout: 10), "⌘R on the meetings read nothing — the check proves nothing")
    }

    /// A transcript out of sight takes no find keys: with the focus in the
    /// text, ⌘F opens no find bar in it; with its find bar open and the
    /// cursor in the bar's field, the field gives up the focus, so typing
    /// does not reach it and ⌘G does not move the text's selection. (In the
    /// find bar ⌘G and Return highlight without moving the selection even
    /// on screen; that the Find handlers do nothing while hidden is checked
    /// in `MeetingListeningTests`.) ⌘F and ⌘G go through the active keyboard
    /// layout: on another than a Latin one the check is skipped.
    func testAHiddenTranscriptAndItsFindBarTakeNoKeys() throws {
        let keys = (physicalCharacter(of: 3), physicalCharacter(of: 5))  // kVK_ANSI_F, kVK_ANSI_G
        try XCTSkipUnless(keys == ("f", "g"), "⌘F and ⌘G through typeKey depend on the keyboard layout: the physical keys give \(String(describing: keys))")
        let found = "2026-10-13 10-00-00 Meeting"
        try write([
            "metadata.json": """
            {"startedAt":"2026-10-13T10:00:00Z","endedAt":"2026-10-13T10:30:00Z","sampleRate":48000,"state":"done",\
            "segments":[{"index":0,"system":"system.m4a","mic":"microphone.m4a"}]}
            """,
            "system.m4a": "audio", "microphone.m4a": "audio",
            "transcript.md": "# Meeting\n\n---\n\n[0:05] **Me:** код 4815\n\n[0:10] **Others:** ещё 4815\n\n[0:15] **Me:** и 4815\n",
        ], into: found)
        let app = launch()
        defer { app.terminate() }
        openMainWindow(in: app)
        let window = mainWindow(in: app)
        let row = app.descendants(matching: .any)["meetingRow.\(found)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let text = app.textViews["meetingTranscriptText"]
        XCTAssertTrue(waitUntil(seconds: 10) { (text.value as? String ?? "").contains("4815") }, "no transcript text")
        let selection = app.buttons["meetingAddToDictionary"]
        func selected() -> String { selection.value as? String ?? "" }

        // The focus in the text: ⌘F away from the meetings opens nothing there.
        text.click()
        guard app.transcribeAFileFromMenuBar() else { return }
        app.typeKey("f", modifierFlags: .command)
        guard app.showMainSection("meetings") else { return }
        let bar = window.searchFields.firstMatch
        XCTAssertFalse(bar.waitForExistence(timeout: 2), "⌘F opened a find bar in the hidden transcript")

        // The find bar open, the cursor in its field: typing reaches it on
        // screen, and nothing once it is hidden.
        text.click()
        app.typeKey("f", modifierFlags: .command)
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "no find bar")
        bar.typeText("48")
        app.typeKey("1", modifierFlags: [])
        app.typeKey("5", modifierFlags: [])
        XCTAssertEqual(bar.value as? String, "4815", "typing did not reach the find bar on screen — the check proves nothing")
        let shown = selected()
        guard app.transcribeAFileFromMenuBar() else { return }
        app.typeKey("9", modifierFlags: [])
        app.typeKey("g", modifierFlags: .command)
        app.typeKey("g", modifierFlags: .command)
        guard app.showMainSection("meetings") else { return }
        XCTAssertEqual(bar.value as? String, "4815", "typing went into the hidden find bar")
        XCTAssertEqual(selected(), shown, "⌘G moved the hidden text's selection")
    }

    /// Return in the search opens the meeting found at its first match once
    /// its text is read; read late, while the window shows another section
    /// and the person types in that section's field, the text takes no
    /// focus: the typing stays in the field, and the card's selection is
    /// not moved to the match. Digits only: a test types through the active
    /// keyboard layout.
    func testATextReadLateTakesNoFocusFromAnotherSection() throws {
        let found = "2026-10-13 10-00-00 Meeting"
        try write([
            "metadata.json": """
            {"startedAt":"2026-10-13T10:00:00Z","endedAt":"2026-10-13T10:30:00Z","sampleRate":48000,"state":"done",\
            "segments":[{"index":0,"system":"system.m4a","mic":"microphone.m4a"}]}
            """,
            "system.m4a": "audio", "microphone.m4a": "audio",
            "transcript.md": "# Meeting\n\n---\n\n[0:05] **Me:** код 4815 и ещё раз 4815\n",
        ], into: found)
        let probe = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probe) }
        func reached(_ name: String) -> Bool {
            waitUntil(seconds: 10) { FileManager.default.fileExists(atPath: probe.appendingPathComponent(name).path) }
        }
        let app = launch(["-FileProbeRoot", probe.path])
        defer { app.terminate() }
        openMainWindow(in: app)
        let window = mainWindow(in: app)
        let row = app.descendants(matching: .any)["meetingRow.\(found)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let search = app.textFields["meetingSearchField"]
        search.click()
        search.typeText("4815")
        let count = AppLanguage.text("%lld matches", 2)
        XCTAssertTrue(waitUntil(seconds: 10) { (row.label + (row.value as? String ?? "")).contains(count) }, "no “\(count)” on the row")

        // The texts the search wanted are read: only the card's read waits.
        try Data().write(to: probe.appendingPathComponent("text.hold"))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(reached("text.reading"), "the card's read was not held")
        XCTAssertEqual(try String(contentsOf: probe.appendingPathComponent("text.reading"), encoding: .utf8), found)
        guard app.showMainSection("dictations") else { return }
        let field = window.textFields["historySearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        try FileManager.default.removeItem(at: probe.appendingPathComponent("text.hold"))
        XCTAssertTrue(reached("text.released"), "the read was not let go")
        // The answer, then a turn for a focus it might still take.
        Thread.sleep(forTimeInterval: 1)
        app.typeKey("7", modifierFlags: [])
        app.typeKey("7", modifierFlags: [])
        XCTAssertEqual(field.value as? String, "77", "the typing left the field shown")

        guard app.showMainSection("meetings") else { return }
        let text = app.textViews["meetingTranscriptText"]
        XCTAssertTrue(waitUntil(seconds: 10) { (text.value as? String ?? "").contains("4815") }, "the text read late is not on the card — the check proves nothing")
        let selection = app.buttons["meetingAddToDictionary"]
        XCTAssertTrue((selection.value as? String ?? "").hasSuffix("+0"), "the hidden text took its first match: \(selection.value ?? "")")
    }

    /// Words found in a transcript go to the dictionary from the card: the
    /// search selects the match, "Add to Dictionary…" opens the entry sheet
    /// with the line's words and the selection as the spelling, and the
    /// entry saved is on the Dictionary tab. The transcript stays as it was.
    /// Digits only: a test types through the active keyboard layout.
    func testAddToDictionaryFromTheTranscript() throws {
        let other = "2026-10-13 10-00-00 Meeting"
        let markdown = "# Meeting\n\n---\n\n[0:05] **Me:** код 4815 и ещё раз\n"
        try write([
            "metadata.json": """
            {"startedAt":"2026-10-13T10:00:00Z","endedAt":"2026-10-13T10:30:00Z","sampleRate":48000,"state":"done",\
            "segments":[{"index":0,"system":"system.m4a","mic":"microphone.m4a"}]}
            """,
            "system.m4a": "audio", "microphone.m4a": "audio", "transcript.md": markdown,
        ], into: other)
        let app = launch()
        defer { app.terminate() }
        openMainWindow(in: app)
        let add = app.buttons["meetingAddToDictionary"]
        let field = app.textFields["meetingSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("4815")
        let found = app.descendants(matching: .any)["meetingRow.\(other)"]
        XCTAssertTrue(waitUntil(seconds: 10) { !app.descendants(matching: .any)["meetingRow.\(meeting)"].exists && found.exists })
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add to Dictionary on the card")
        XCTAssertTrue(waitUntil(seconds: 10) { add.isEnabled }, "the match the search selected does not count as a selection")
        add.click()

        let heard = app.textFields["dictionaryHeardField"]
        XCTAssertTrue(heard.waitForExistence(timeout: 5), "no entry sheet")
        XCTAssertEqual(heard.value as? String, "4815")
        XCTAssertEqual(app.textViews["dictionarySourceText"].value as? String, "код 4815 и ещё раз", "the sheet got another text")
        let written = app.textFields["dictionaryWrittenField"]
        written.click()
        written.typeText("42")
        app.buttons["dictionarySave"].click()
        XCTAssertTrue(heard.waitForNonExistence(timeout: 5), "the sheet stayed")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(other).appendingPathComponent("transcript.md"), encoding: .utf8), markdown)

        guard app.showMainSection("dictionary") else { return }
        let entry = mainWindow(in: app).descendants(matching: .any)["dictionaryEntry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "no entry in the Dictionary section")
        XCTAssertTrue(entry.staticTexts["42"].exists && entry.staticTexts["4815"].exists, "the entry is not the one saved")
    }

    /// At the window's least width, and at the size it opens with, nothing
    /// is cut: the card ends inside the window and the player's row inside
    /// the card, the sidebar keeps its labels and Settings…, the time of the
    /// player shows whole; folding the sidebar and opening it again keeps it so.
    func testNothingIsCutAtTheWindowsLeastWidth() throws {
        let app = launch()
        defer { app.terminate() }
        openMainWindow(in: app)
        let row = app.descendants(matching: .any)["meetingRow.\(meeting)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let window = mainWindow(in: app)
        let card = app.descendants(matching: .any)["meetingCard"].firstMatch
        let time = app.staticTexts["meetingPlayerTime"]
        let track = app.descendants(matching: .any)["meetingPlayerTrack.system"]
        XCTAssertTrue(time.waitForExistence(timeout: 10), "no player on the card")
        XCTAssertTrue(track.waitForExistence(timeout: 10), "no track buttons on the card")
        func check(_ when: String) {
            let edge = window.frame.maxX
            XCTAssertLessThanOrEqual(card.frame.maxX, edge + 0.5, "\(when): the card goes past the window: \(card.frame) in \(window.frame)")
            XCTAssertLessThanOrEqual(time.frame.maxX, edge - 8, "\(when): the player's time is cut: \(time.frame) in \(window.frame)")
            XCTAssertLessThanOrEqual(track.frame.maxX, card.frame.maxX - 8, "\(when): the player's row goes past the card: \(track.frame) in \(card.frame)")
        }
        check("at the size the window opens with")
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.3, thenDragTo: corner.withOffset(CGVector(dx: -800, dy: 0)))
        Thread.sleep(forTimeInterval: 0.5)
        check("at the least width")
        let settings = app.buttons["mainSidebarSettings"]
        XCTAssertGreaterThanOrEqual(settings.frame.minX, window.frame.minX, "Settings… is cut on the left: \(settings.frame)")
        let meetings = app.descendants(matching: .any)["mainSection.meetings"]
        XCTAssertGreaterThanOrEqual(meetings.frame.minX, window.frame.minX + 4, "the sidebar's rows are squeezed: \(meetings.frame)")

        toggleSidebar(of: window)
        XCTAssertTrue(waitUntil { !meetings.exists }, "the sidebar did not fold")
        check("with the sidebar folded")
        toggleSidebar(of: window)
        XCTAssertTrue(waitUntil { meetings.exists && meetings.isHittable }, "the sidebar did not open again")
        check("with the sidebar opened again")
    }

    /// AppKit keeps a window's layout (a split view's widths and folding, a
    /// window's frame, a table's columns, a toolbar) in the app's own
    /// preferences, the owner's on their Mac: a test copy that resizes the
    /// window and folds and opens its sidebar leaves every such key as it
    /// was. It only reads them: nothing here writes the owner's domain.
    func testATestCopyWritesNoWindowLayoutOfTheOwners() throws {
        let owners = ownersLayout()
        let app = launch()
        openMainWindow(in: app)
        let window = mainWindow(in: app)
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.3, thenDragTo: corner.withOffset(CGVector(dx: -300, dy: 0)))
        let meetings = app.descendants(matching: .any)["mainSection.meetings"]
        XCTAssertTrue(meetings.waitForExistence(timeout: 5))
        toggleSidebar(of: window)
        XCTAssertTrue(waitUntil { !meetings.exists }, "the sidebar did not fold")
        toggleSidebar(of: window)
        XCTAssertTrue(meetings.waitForExistence(timeout: 5), "the sidebar did not open again")
        app.terminate()
        let changed = waitUntil(seconds: 5) { ownersLayout() != owners }
        XCTAssertFalse(changed, "the test copy wrote a window's layout into the owner's preferences: \(ownersLayout()), was \(owners)")
    }

    /// The sidebar's own button in the window's toolbar.
    private func toggleSidebar(of window: XCUIElement) {
        let button = window.buttons["mainSidebarToggle"]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no button to fold the sidebar")
        button.click()
    }

    /// A meeting with a transcript and the record of its attempt that
    /// matches it: each line's track, and the file's size and SHA-256.
    private func writeRecorded(_ name: String, lines: [(source: String, label: String, words: String)]) throws -> String {
        let rows = lines.enumerated().map { "[0:0\($0.offset * 2 + 1)] **\($0.element.label):** \($0.element.words)" }
        let markdown = "# Meeting\n\nAutomatic transcript.\n\n---\n\n" + rows.joined(separator: "\n\n") + "\n"
        let bytes = Data(markdown.utf8)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let spans = lines.enumerated().map { #"{"start":\#($0.offset * 2 + 1),"end":\#($0.offset * 2 + 2),"source":"\#($0.element.source)"}"# }
        let attempt = """
            {"version":1,"number":1,"result":"complete","startedAt":"2026-10-13T09:40:00Z","endedAt":"2026-10-13T09:41:00Z",\
            "transcript":"transcript.md","engines":["whisper"],"languages":["auto"],"failedChunks":0,"cutShort":false,\
            "missingTracks":[],"speakers":{"microphone":"Me","system":"Others"},"lines":[\(spans.joined(separator: ","))],\
            "fingerprint":{"bytes":\(bytes.count),"sha256":"\(sha)"}}
            """
        try write([
            "metadata.json": """
            {"startedAt":"2026-10-13T09:00:00Z","endedAt":"2026-10-13T09:30:00Z","sampleRate":48000,"state":"done",\
            "segments":[{"index":0,"system":"system.m4a","mic":"microphone.m4a"}]}
            """,
            "system.m4a": "audio", "microphone.m4a": "audio", "transcript.md": markdown,
            ".attempt 0001 \(UUID().uuidString).murmurly.json": attempt,
        ], into: name)
        return markdown
    }

    /// The search's match selected, so Add to Dictionary is on; Return in
    /// the search field selects the first match of the meeting found.
    private func selectMatch(_ digits: String, in app: XCUIApplication, typing: Bool = true) {
        let field = app.textFields["meetingSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        if typing { field.typeText(digits) }
        app.typeKey(.return, modifierFlags: [])
    }

    /// The names sheet over a meeting in the chosen meetings folder, its
    /// write held by the probe as a slow network volume would: Save keeps
    /// the sheet up with both fields off; the write done, it closes. A write
    /// that fails keeps it up with the names as typed and the fields on
    /// again. Cancel during a write closes it, and the write still lands.
    func testTheNamesSheetHoldsItsFieldsUntilItsWriteEnds() throws {
        let chosen = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-chosen", isDirectory: true)
        let probe = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-probe", isDirectory: true)
        for folder in [chosen, probe] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        defer { for folder in [chosen, probe] { try? FileManager.default.removeItem(at: folder) } }
        let recorded = "2026-10-13 09-00-00 Meeting"
        _ = try writeRecorded(recorded, lines: [("microphone", "Me", "раз"), ("system", "Others", "два")])
        try FileManager.default.moveItem(at: root.appendingPathComponent(recorded), to: chosen.appendingPathComponent(recorded))
        let marks = chosen.appendingPathComponent(recorded).appendingPathComponent("murmurly.json")
        func written() -> [String: String]? {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: marks)) as? [String: Any])?["speakers"] as? [String: String]
        }
        func gate(_ name: String) throws { try Data().write(to: probe.appendingPathComponent(name)) }
        func reached(_ name: String) -> Bool {
            waitUntil(seconds: 10) { FileManager.default.fileExists(atPath: probe.appendingPathComponent(name).path) }
        }
        let app = launch(["-FileProbeRoot", probe.path, "-meeting.storageFolder", chosen.path])
        defer { app.terminate() }
        openMainWindow(in: app)
        let row = app.descendants(matching: .any)["meetingRow.\(recorded)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the meeting in the chosen folder is not listed")
        row.click()
        let names = app.buttons["meetingNames"]
        XCTAssertTrue(waitUntil(seconds: 10) { names.isEnabled }, "Names is off")
        let sheet = app.descendants(matching: .any)["meetingNamesSheet"]
        let microphone = app.textFields["meetingNamesMicrophone"]
        let system = app.textFields["meetingNamesSystem"]
        func type(_ microphoneName: String, _ systemName: String) {
            names.click()
            XCTAssertTrue(microphone.waitForExistence(timeout: 5), "no names sheet")
            microphone.click()
            microphone.typeText(microphoneName)
            system.click()
            system.typeText(systemName)
        }

        // Saved: up, fields off, while the write is held; closed once it is done.
        type("11", "22")
        try gate("marks-1.hold")
        app.buttons["meetingNamesSave"].click()
        XCTAssertTrue(reached("marks-1.writing"), "the write was not held")
        XCTAssertTrue(sheet.exists, "the sheet closed before its names were on disk")
        XCTAssertTrue(waitUntil { !microphone.isEnabled && !system.isEnabled }, "a field takes typing while the names are written")
        try gate("marks-1.release")
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "the sheet stayed after its names were written")
        XCTAssertEqual(written(), ["microphone": "11", "system": "22"])

        // Refused: still up, the names as typed, the fields on again.
        type("3", "4")
        try gate("marks-2.hold")
        app.buttons["meetingNamesSave"].click()
        XCTAssertTrue(reached("marks-2.writing"))
        XCTAssertTrue(waitUntil { !microphone.isEnabled && !system.isEnabled })
        try gate("marks-2.fail")
        XCTAssertTrue(app.staticTexts["meetingNamesRefusal"].waitForExistence(timeout: 10), "the refusal is not in the sheet")
        XCTAssertTrue(sheet.exists, "a refusal closed the sheet")
        XCTAssertTrue(waitUntil { microphone.isEnabled && system.isEnabled }, "the fields stayed off after the refusal")
        XCTAssertEqual(microphone.value as? String, "113")
        XCTAssertEqual(system.value as? String, "224")
        XCTAssertEqual(written(), ["microphone": "11", "system": "22"])

        // Cancel during the write: closed, and the write still lands.
        try gate("marks-3.hold")
        app.buttons["meetingNamesSave"].click()
        XCTAssertTrue(reached("marks-3.writing"))
        app.buttons["meetingNamesCancel"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), "Cancel did not close the sheet")
        try gate("marks-3.release")
        XCTAssertTrue(waitUntil(seconds: 10) { written() == ["microphone": "113", "system": "224"] }, "the write was dropped with the sheet")
    }

    /// A selection of no words takes no entry: the caret moved to the end of
    /// a line turns Add to Dictionary off, and so does the line break after
    /// it selected alone; the words of the search's match turned it on.
    func testAddToDictionaryNeedsWordsSelected() throws {
        let recorded = "2026-10-13 09-00-00 Meeting"
        _ = try writeRecorded(recorded, lines: [("microphone", "Me", "код 4815 и ещё"), ("system", "Others", "дальше")])
        let app = launch()
        defer { app.terminate() }
        openMainWindow(in: app)
        selectMatch("4815", in: app)
        let add = app.buttons["meetingAddToDictionary"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add to Dictionary on the card")
        XCTAssertTrue(waitUntil(seconds: 10) { add.isEnabled }, "the match the search selected does not count")

        // The text has the focus: to the end of the line, then its line
        // break. Each time the card has taken that very selection (a test
        // process says which, "start+length") before the button is looked at.
        func held() -> (start: Int, length: Int)? {
            let parts = (add.value as? String ?? "").split(separator: "+").compactMap { Int($0) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        let match = try XCTUnwrap(held(), "the card says no selection: \(add.value ?? "")")
        XCTAssertEqual(match.length, 4, "the card holds another selection than the match")
        app.typeKey(.rightArrow, modifierFlags: .command)
        XCTAssertTrue(waitUntil { held().map { $0.length == 0 && $0.start > match.start } == true }, "the caret's move did not reach the card")
        let caret = try XCTUnwrap(held())
        XCTAssertFalse(add.isEnabled, "on with nothing selected")
        app.typeKey(.rightArrow, modifierFlags: .shift)
        XCTAssertTrue(waitUntil { held().map { $0.start == caret.start && $0.length == 1 } == true },
                      "the line break selected did not reach the card: \(add.value ?? "")")
        XCTAssertFalse(add.isEnabled, "on for a line break selected alone")
    }

    /// A selection is read in the text it was made in: the speakers' names
    /// changed after it, the card's text is the new one, with longer labels,
    /// and the old selection takes nothing; selected again, its words are
    /// what the entry sheet gets.
    func testANameChangedAfterASelectionTakesNoStaleWords() throws {
        let recorded = "2026-10-13 09-00-00 Meeting"
        _ = try writeRecorded(recorded, lines: [("microphone", "Me", "код 4815 и ещё"), ("system", "Others", "дальше")])
        let app = launch()
        defer { app.terminate() }
        openMainWindow(in: app)
        selectMatch("4815", in: app)
        let add = app.buttons["meetingAddToDictionary"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil(seconds: 10) { add.isEnabled })

        app.buttons["meetingNames"].click()
        let microphone = app.textFields["meetingNamesMicrophone"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 5), "no names sheet")
        microphone.click()
        microphone.typeText("1234567890123")
        app.buttons["meetingNamesSave"].click()
        XCTAssertTrue(app.descendants(matching: .any)["meetingNamesSheet"].waitForNonExistence(timeout: 5))
        let text = app.textViews["meetingTranscriptText"]
        XCTAssertTrue(waitUntil { (text.value as? String ?? "").contains("1234567890123: код 4815") },
                      "the card kept the text from before the names: \(text.value ?? "")")
        XCTAssertTrue(waitUntil { !add.isEnabled }, "the selection made in the text before the names still counts")

        selectMatch("4815", in: app, typing: false)
        XCTAssertTrue(waitUntil(seconds: 10) { add.isEnabled }, "the match selected in the new text does not count")
        add.click()
        let heard = app.textFields["dictionaryHeardField"]
        XCTAssertTrue(heard.waitForExistence(timeout: 5), "no entry sheet")
        XCTAssertEqual(heard.value as? String, "4815", "the sheet took other words than the ones selected")
        XCTAssertEqual(app.textViews["dictionarySourceText"].value as? String, "код 4815 и ещё")
        app.buttons["dictionaryCancel"].click()
    }

    /// A row the search left out comes back whole once the search is
    /// cleared: as tall as before, its time, source and state shown, not
    /// only its name. Measured on the window's picture: asking the row
    /// itself through accessibility has the table measure it again, which
    /// would hide the fault, and so does a look for its search's status
    /// lines. Each attempt waits until the picture no longer shows the row
    /// (the search took it away) and, once cleared, until it shows it
    /// again, so an attempt never compares the list with itself before the
    /// search reached it. Digits only: a test types through the layout.
    func testARowComesBackWholeAfterASearch() throws {
        let app = launch()
        defer { app.terminate() }
        openMainWindow(in: app)
        let row = app.descendants(matching: .any)["meetingRow.\(meeting)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let window = mainWindow(in: app)
        // At the window's least width, as the shots that showed it were.
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.3, thenDragTo: corner.withOffset(CGVector(dx: -800, dy: 0)))
        row.click()
        Thread.sleep(forTimeInterval: 0.5)
        let frame = row.frame
        let windowFrame = window.frame
        let column = frame.midX - windowFrame.minX
        let top = frame.minY - windowFrame.minY
        let before = selectedRowHeight(in: window, column: column, from: top)
        // The highlight reaches a little past the row's own frame; before and
        // after are measured alike.
        XCTAssertGreaterThan(before, frame.height - 4, "the picture does not show the row's highlight: \(before) for \(frame)")
        let field = app.textFields["meetingSearchField"]
        let query = "90210"

        for attempt in 1...6 {
            field.click()
            field.typeText(query)
            // Nothing asked of the list through accessibility: that has the
            // table measure its rows again. Only its picture.
            XCTAssertTrue(waitUntil(seconds: 10) { selectedRowHeight(in: window, column: column, from: top) < 8 },
                          "attempt \(attempt): the picture still shows the row the search left out")
            for _ in query { app.typeKey(.delete, modifierFlags: []) }
            XCTAssertTrue(waitUntil(seconds: 10) { selectedRowHeight(in: window, column: column, from: top) > 8 },
                          "attempt \(attempt): the row did not come back in the picture")
            Thread.sleep(forTimeInterval: 0.5)
            let after = selectedRowHeight(in: window, column: column, from: top)
            XCTAssertEqual(after, before, accuracy: 4, "attempt \(attempt): the row came back \(after) tall, was \(before)")
        }
    }

    /// The selection stays in sight across a search: the list made anew as
    /// the search ends would start at its top, the selected rows far below
    /// out of view. One row, then two (the upper one shown); typing goes on
    /// in the search field without a click.
    func testTheSelectionStaysInViewAfterASearch() throws {
        // Forty meetings a day apart, newest first, all older than setUp's;
        // each its own start, so the list's order never changes on a read.
        let starts = (0..<40).map { Date(timeIntervalSince1970: 1_790_000_000 - Double($0) * 86_400) }
        let names = starts.map { DateFormatter.meetingFolder.string(from: $0) + " Meeting" }
        for (name, start) in zip(names, starts) {
            let iso = ISO8601DateFormatter()
            try write([
                "metadata.json": """
                {"startedAt":"\(iso.string(from: start))","endedAt":"\(iso.string(from: start.addingTimeInterval(1800)))",\
                "sampleRate":48000,"state":"done",\
                "trigger":"manual","segments":[{"index":0,"system":"system.m4a","mic":"microphone.m4a"}]}
                """,
                "system.m4a": "audio", "microphone.m4a": "audio",
                "transcript.md": "# Meeting\n\nAutomatic transcript.\n\n---\n\n[0:05] **Me:** Повестка встречи.\n",
            ], into: name)
        }
        let app = launch()
        defer { app.terminate() }
        openMainWindow(in: app)
        let list = app.outlines["meetingList"]
        let first = list.descendants(matching: .any)["meetingRow.\(brokenOff)"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        // Rows looked for in the list itself, as it shows them.
        let oldest = list.descendants(matching: .any)["meetingRow.\(names[39])"]
        let above = list.descendants(matching: .any)["meetingRow.\(names[38])"]
        func inView(_ row: XCUIElement) -> Bool {
            row.exists && row.frame.height > 0 && list.frame.contains(CGPoint(x: row.frame.midX, y: row.frame.midY))
        }
        // Down to the last row by the keyboard: the list follows its selection.
        first.click()
        for _ in 0..<45 { app.typeKey(.downArrow, modifierFlags: []) }
        XCTAssertTrue(waitUntil { inView(oldest) }, "the last row is not in view after going down to it: \(oldest.frame) in \(list.frame)")
        XCTAssertFalse(inView(first), "the list is too short to leave its top out of view")
        let field = app.textFields["meetingSearchField"]
        let nothing = noMatches(in: app)
        func searchAndClear() {
            field.click()
            field.typeText("90210")
            XCTAssertTrue(nothing.waitForExistence(timeout: 10), "the search did not settle on no matches")
            for _ in 0..<5 { app.typeKey(.delete, modifierFlags: []) }
            XCTAssertTrue(nothing.waitForNonExistence(timeout: 10), "the search did not end")
        }

        searchAndClear()
        XCTAssertTrue(waitUntil { inView(oldest) }, "the selected row is out of view after the search: \(oldest.frame) in \(list.frame)")

        oldest.click()
        app.typeKey(.upArrow, modifierFlags: .shift)
        XCTAssertTrue(app.buttons["batchDeleteMeetings"].waitForExistence(timeout: 5), "two rows are not selected")
        searchAndClear()
        XCTAssertTrue(waitUntil { inView(above) }, "the upper of the two selected rows is out of view after the search: \(above.frame) in \(list.frame)")
        XCTAssertTrue(app.buttons["batchDeleteMeetings"].exists, "the search lost the selection of two rows")

        field.typeText("12")
        XCTAssertEqual(field.value as? String, "12", "typing after the search did not go on in its field")
        XCTAssertTrue(waitUntil(seconds: 10) { !oldest.exists }, "the list was not searched for what was typed")
    }

    /// "No matches" under the search field: one of the search's status lines.
    private func noMatches(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "meetingSearchStatus")
            .matching(NSPredicate(format: "value == %@", AppLanguage.text("No matches"))).firstMatch
    }

    /// How tall the selection's highlight is in the window's picture, in
    /// points, at `column` from the row's top `from` down.
    private func selectedRowHeight(in window: XCUIElement, column: CGFloat, from top: CGFloat) -> CGFloat {
        guard let image = window.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let bitmap = NSBitmapImageRep(cgImage: image)
        let scale = CGFloat(bitmap.pixelsWide) / window.frame.width
        let x = Int(column * scale)
        // The list's background, below the rows.
        guard let background = bitmap.colorAt(x: x, y: bitmap.pixelsHigh - Int(60 * scale))?.usingColorSpace(.deviceRGB) else { return 0 }
        func differs(_ y: Int) -> Bool {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return abs(color.redComponent - background.redComponent) + abs(color.greenComponent - background.greenComponent)
                + abs(color.blueComponent - background.blueComponent) > 0.05
        }
        var y = Int((top + 4) * scale)
        let start = y
        while y < bitmap.pixelsHigh, differs(y) { y += 1 }
        return CGFloat(y - start) / scale + 4
    }

    /// ⌘F in a transcript opens the find bar: the window's text view takes
    /// the Find items of the Edit menu.
    func testFindInTheTranscript() throws {
        let app = launch()
        defer { app.terminate() }
        openMainWindow(in: app)
        let row = app.descendants(matching: .any)["meetingRow.\(meeting)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        let text = app.textViews["meetingTranscriptText"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        let key = physicalCharacter(of: 3)  // kVK_ANSI_F
        try XCTSkipUnless(
            key == "f",
            "The ⌘F check through typeKey depends on the keyboard layout: the physical key gives "
                + "\(key.map { "“\($0)”" } ?? "an unknown character"), not an f"
        )

        text.click()
        app.typeKey("f", modifierFlags: .command)

        XCTAssertTrue(mainWindow(in: app).searchFields.firstMatch.waitForExistence(timeout: 5), "no find bar")
    }

    /// Two windows, closed in either order: each goes alone, and opening one
    /// again makes no second copy of it.
    func testTwoWindowsCloseInEitherOrder() throws {
        let app = launch()
        defer { app.terminate() }

        openMainWindow(in: app)
        openSettings(in: app)
        XCTAssertEqual(app.windows.count, 2)

        close(mainWindow(in: app))
        XCTAssertTrue(settingsContent(in: app).exists, "Settings went with the main window")
        XCTAssertEqual(app.windows.count, 1)

        openMainWindow(in: app)
        openMainWindow(in: app)
        XCTAssertEqual(app.windows.count, 2, "opening the main window again made another")
        // The larger main window may cover Settings' close button: Settings
        // forward first, as a person would bring it.
        openSettings(in: app)
        XCTAssertEqual(app.windows.count, 2, "opening Settings again made another")
        close(app.windows["settings"])
        XCTAssertTrue(app.descendants(matching: .any)["meetingList"].exists, "the main window went with Settings")
        XCTAssertEqual(app.windows.count, 1)
        close(mainWindow(in: app))
        XCTAssertEqual(app.windows.count, 0)
    }

    func testCommandCommaWithTheMainWindowOpen() throws {
        let app = launch()
        defer { app.terminate() }
        openMainWindow(in: app)
        let commaCharacter = physicalCommaCharacter()
        try XCTSkipUnless(
            commaCharacter == ",",
            "The ⌘, check through typeKey depends on the keyboard layout: the physical key gives "
                + "\(commaCharacter.map { "“\($0)”" } ?? "an unknown character"), not a comma"
        )

        app.typeKey(",", modifierFlags: .command)

        XCTAssertTrue(settingsContent(in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.count, 2)
    }

    /// Opening the app while it runs (Finder, Launchpad) shows the main
    /// window, even with Settings on screen; again, no second copy.
    func testReopeningTheRunningAppShowsTheMainWindow() async throws {
        let app = launch()
        defer { app.terminate() }
        openSettings(in: app)
        XCTAssertEqual(app.windows.count, 1)

        try await reopen()
        XCTAssertTrue(app.descendants(matching: .any)["meetingList"].waitForExistence(timeout: 10), "no main window")
        XCTAssertEqual(app.windows.count, 2)

        try await reopen()
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(app.windows.count, 2, "opening the app again made another main window")
    }

    // MARK: - Helpers

    /// A key of the app's own domain, the owner's, read from disk: the runner
    /// is sandboxed, so CFPreferences would read its own container.
    /// The owner's value of `key` stays `value`. The preferences daemon
    /// writes the file when it likes: read at once, a change on its way
    /// passes for none, so a change is given 5 s to land first.
    private func assertOwnersPreference(
        _ key: String, stays value: String, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let changed = waitUntil(seconds: 5) { ownersPreference(key) != value }
        XCTAssertFalse(changed, "\(message): \(ownersPreference(key)), was \(value)", file: file, line: line)
    }

    private func ownersPreference(_ key: String) -> String {
        guard let domain = ownersDomain() else { return "<no domain>" }
        return domain[key].map { String(describing: $0) } ?? "<none>"
    }

    /// The keys AppKit writes for a window's layout, as the owner has them.
    private func ownersLayout() -> String {
        let prefixes = ["NSSplitView", "NSWindow Frame", "NSTableView", "NSToolbar", "NSOutlineView"]
        let layout = (ownersDomain() ?? [:]).filter { key, _ in prefixes.contains { key.hasPrefix($0) } }
        return layout.keys.sorted().map { "\($0) = \(String(describing: layout[$0]!))" }.joined(separator: "; ")
    }

    /// The owner's domain as it is on disk; nil while there is none.
    private func ownersDomain() -> [String: Any]? {
        guard let home = getpwuid(getuid())?.pointee.pw_dir else {
            XCTFail("could not find the home folder")
            return nil
        }
        let url = URL(fileURLWithPath: String(cString: home))
            .appendingPathComponent("Library/Preferences/io.github.spacevibes365.Murmurly.plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // A domain that is there but can't be read proves nothing.
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            XCTFail("the app's domain exists but cannot be read: \(url.path)")
            return nil
        }
        return plist
    }

    /// The app's Trash in these tests: a folder of the test's own.
    private var trash: URL { root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-trash") }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // The player's probe: silent tracks, no sound from a test copy.
        app.launchArguments = ["-UITesting", "-UITestSettingsStore", "-MeetingsProbeRoot", root.path,
                               "-RemovalProbeTrash", trash.path, "-PlayerProbe"]
            + extra + AppLanguage.launchArguments
        app.launch()
        return app
    }

    private func write(_ files: [String: String], into name: String) throws {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (file, text) in files {
            try Data(text.utf8).write(to: folder.appendingPathComponent(file))
        }
    }

    private func openMainWindow(in app: XCUIApplication) {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "no Murmurly item in the menu bar")
        statusItem.click()
        let item = statusItem.menus.firstMatch.menuItems[AppLanguage.text("Open Murmurly")]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the menu has no Open Murmurly")
        item.click()
        XCTAssertTrue(app.descendants(matching: .any)["meetingList"].waitForExistence(timeout: 10), "no main window")
    }

    /// Settings stays third from the end of the menu.
    private func openSettings(in app: XCUIApplication) {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        let items = statusItem.menus.firstMatch.children(matching: .menuItem)
        XCTAssertGreaterThanOrEqual(items.count, 3)
        items.element(boundBy: items.count - 3).click()
        XCTAssertTrue(settingsContent(in: app).waitForExistence(timeout: 10), "no Settings")
    }

    private func settingsContent(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["settingsWindowContent"]
    }

    private func mainWindow(in app: XCUIApplication) -> XCUIElement {
        app.windows["main"]
    }

    private func close(_ window: XCUIElement) {
        XCTAssertTrue(window.exists, "no such window to close")
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 5), "the window stayed")
    }

    /// What Finder does when the app is opened again: LaunchServices finds it
    /// running and sends it the reopen event.
    private func reopen() async throws {
        let bundle = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Murmurly.app")
        XCTAssertTrue(NSWorkspace.shared.open(bundle), "LaunchServices refused to open \(bundle.path)")
    }

    private func waitUntil(seconds: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }

    private func physicalCommaCharacter() -> String? {
        physicalCharacter(of: 43)  // kVK_ANSI_Comma
    }

    /// What the key at this physical place types in the active layout.
    private func physicalCharacter(of virtualKey: CGKeyCode) -> String? {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true) else { return nil }
        var count = 0
        var characters = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &count, unicodeString: &characters)
        return String(utf16CodeUnits: characters, count: count)
    }
}

private extension DateFormatter {
    /// A meeting folder's name, as the recorder writes it.
    static let meetingFolder: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter
    }()
}
