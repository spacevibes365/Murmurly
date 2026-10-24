import Foundation
import XCTest
@testable import Murmurly

/// Snippets: a dictation-only kind of dictionary entry that fires only when
/// the whole dictation equals one of its trigger phrases, delivering its text
/// as written instead of going through ordinary replacements.
@MainActor
final class SnippetTests: XCTestCase {
    private func snippet(
        _ heard: [String],
        _ written: String,
        isEnabled: Bool = true
    ) -> DictionaryEntry {
        DictionaryEntry(kind: .snippet, heard: heard, written: written, isEnabled: isEnabled)
    }

    func testWholeDictationEqualToTriggerBecomesTheSnippetText() {
        let entry = snippet(["prompt review", "prompt check"], "Line one\nLine two")
        let replacer = DictionaryReplacer(entries: [entry], matchesWordForms: true, includeSnippets: true) {
            XCTFail("a snippet never looks up word forms")
            return { _ in "" }
        }

        let first = replacer.replacing(in: "prompt review")
        XCTAssertEqual(first.text, "Line one\nLine two")
        XCTAssertEqual(first.count, 1)

        // The second trigger phrase from the comma-separated list fires the
        // same way.
        let second = replacer.replacing(in: "prompt check")
        XCTAssertEqual(second.text, "Line one\nLine two")
        XCTAssertEqual(second.count, 1)
    }

    func testTriggerInsideASentenceIsLeftAlone() {
        let entry = snippet(["prompt review"], "Line one\nLine two")
        let replacer = DictionaryReplacer(entries: [entry], matchesWordForms: false, includeSnippets: true)

        let result = replacer.replacing(in: "please do a prompt review now")
        XCTAssertEqual(result.text, "please do a prompt review now")
        XCTAssertEqual(result.count, 0)
    }

    func testExtraWordMeansNoSnippet() {
        let entry = snippet(["prompt review"], "Line one\nLine two")
        let replacer = DictionaryReplacer(entries: [entry], matchesWordForms: false, includeSnippets: true)

        let result = replacer.replacing(in: "prompt review now")
        XCTAssertEqual(result.text, "prompt review now")
        XCTAssertEqual(result.count, 0)
    }

    /// Case and the punctuation between the words or at the edges never tell
    /// the trigger apart from the dictation, checked on a Latin phrase.
    func testCaseYoAndPunctuationDoNotMatter() {
        let entry = snippet(["prompt review"], "All systems green")
        let replacer = DictionaryReplacer(entries: [entry], matchesWordForms: false, includeSnippets: true)

        let result = replacer.replacing(in: "Prompt, REVIEW?")
        XCTAssertEqual(result.text, "All systems green")
        XCTAssertEqual(result.count, 1)

        // The Russian yo/ye spelling, on the literals already used elsewhere
        // in this test target.
        let yo = snippet(["все ок"], "All systems green")
        let yoReplacer = DictionaryReplacer(entries: [yo], matchesWordForms: false, includeSnippets: true)
        let yoResult = yoReplacer.replacing(in: "всё ок")
        XCTAssertEqual(yoResult.text, "All systems green")
        XCTAssertEqual(yoResult.count, 1)

        // A snippet never looks up word forms, even with a Cyrillic trigger
        // and word forms turned on for the job.
        let wordFormsReplacer = DictionaryReplacer(entries: [yo], matchesWordForms: true, includeSnippets: true) {
            XCTFail("a snippet never looks up word forms")
            return { _ in "" }
        }
        let wordFormsResult = wordFormsReplacer.replacing(in: "все ок")
        XCTAssertEqual(wordFormsResult.text, "All systems green")
        XCTAssertEqual(wordFormsResult.count, 1)
    }

    func testSnippetsApplyOnlyToDictation() throws {
        let entry = snippet(["prompt review"], "Line one\nLine two")
        let risks = DictionaryEntry(heard: ["risks"], written: "RISKS")
        let snapshot = DictionarySnapshot(
            entries: [entry, risks],
            uses: [.dictation, .meetings, .files],
            matchesWordForms: false
        )

        let dictation = try XCTUnwrap(snapshot.replacer(for: .dictation))
        let dictationResult = dictation.replacing(in: "prompt review")
        XCTAssertEqual(dictationResult.text, "Line one\nLine two")
        XCTAssertEqual(dictationResult.count, 1)

        let meetings = try XCTUnwrap(snapshot.replacer(for: .meetings))
        let meetingsOnTrigger = meetings.replacing(in: "prompt review")
        XCTAssertEqual(meetingsOnTrigger.text, "prompt review")
        XCTAssertEqual(meetingsOnTrigger.count, 0)
        // An ordinary replacement still applies for meetings.
        XCTAssertEqual(meetings.replacing(in: "risks ahead").text, "RISKS ahead")

        let files = try XCTUnwrap(snapshot.replacer(for: .files))
        let filesOnTrigger = files.replacing(in: "prompt review")
        XCTAssertEqual(filesOnTrigger.text, "prompt review")
        XCTAssertEqual(filesOnTrigger.count, 0)
    }

    func testSwitchedOffSnippetDoesNothing() throws {
        let entry = snippet(["prompt review"], "Line one\nLine two")

        let on = DictionarySnapshot(entries: [entry], uses: [.dictation], matchesWordForms: false)
        let onReplacer = try XCTUnwrap(on.replacer(for: .dictation))
        XCTAssertEqual(onReplacer.replacing(in: "prompt review").text, "Line one\nLine two")

        // `dictionary.inDictation` switched off: no more `.dictation` in `uses`.
        let switchedOff = DictionarySnapshot(entries: [entry], uses: [], matchesWordForms: false)
        XCTAssertNil(switchedOff.replacer(for: .dictation))

        // The entry itself switched off.
        let entryOff = snippet(["prompt review"], "Line one\nLine two", isEnabled: false)
        let entryOffSnapshot = DictionarySnapshot(entries: [entryOff], uses: [.dictation], matchesWordForms: false)
        XCTAssertNil(entryOffSnapshot.replacer(for: .dictation))
    }

    func testSnippetTextIsNotTouchedByReplacements() {
        let entry = snippet(["prompt review"], "Line one\nLine two")
        let replacement = DictionaryEntry(heard: ["two"], written: "CHANGED")
        let replacer = DictionaryReplacer(entries: [entry, replacement], matchesWordForms: false, includeSnippets: true)

        let result = replacer.replacing(in: "prompt review")
        XCTAssertEqual(result.text, "Line one\nLine two")
        XCTAssertEqual(result.count, 1)

        // The replacement rule itself still works outside the snippet.
        XCTAssertEqual(replacer.replacing(in: "chapter two").text, "chapter CHANGED")
    }

    func testDictionaryWithoutSnippetsIsVersionOneByteForByte() throws {
        let entries = [DictionaryEntry(heard: ["term"], written: "Term")]
        let data = try SettingsStore.encodedDictionary(entries)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        let entryJSON = try XCTUnwrap((json["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(entryJSON.keys), ["id", "heard", "written", "enabled"])
    }

    func testDictionaryWithASnippetIsVersionTwoAndReadsBack() throws {
        let entry = snippet(["prompt review"], "Line one\nLine two")
        let data = try SettingsStore.encodedDictionary([entry])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 2)

        let imported = SettingsStore.importedDictionary(from: data)
        switch imported {
        case .success(let entries):
            XCTAssertEqual(entries, [entry])
        case .failure(let failure):
            XCTFail("expected the snippet to read back, got \(failure)")
        }

        // A mixed dictionary with a disabled snippet is version 2 too, and a
        // fresh SettingsStore loaded from its own suite reads it back with
        // the same kind, text and switch.
        let suiteName = "io.github.spacevibes365.MurmurlyTests.Snippets.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let disabledSnippet = snippet(["prompt check"], "Other text", isEnabled: false)
        let replacement = DictionaryEntry(heard: ["risks"], written: "RISKS")
        let store = SettingsStore(defaults: defaults)
        try store.saveDictionary([replacement, disabledSnippet])
        let storedData = try XCTUnwrap(defaults.data(forKey: "dictionary.entries"))
        let storedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: storedData) as? [String: Any])
        XCTAssertEqual(storedJSON["version"] as? Int, 2)

        let reopened = SettingsStore(defaults: defaults)
        XCTAssertEqual(reopened.dictionary, [replacement, disabledSnippet])
        let reopenedSnippet = try XCTUnwrap(reopened.dictionary.first { $0.id == disabledSnippet.id })
        XCTAssertEqual(reopenedSnippet.kind, .snippet)
        XCTAssertEqual(reopenedSnippet.written, "Other text")
        XCTAssertFalse(reopenedSnippet.isEnabled)

        // An unknown kind is never silently read as a replacement: the whole
        // document is refused, as any other unreadable entry is.
        let unknownKind: [String: Any] = [
            "version": 2,
            "entries": [[
                "id": UUID().uuidString, "heard": ["x"], "written": "y", "enabled": true, "kind": "macro",
            ]],
        ]
        let badData = try JSONSerialization.data(withJSONObject: unknownKind)
        XCTAssertEqual(SettingsStore.importedDictionary(from: badData), .failure(.unreadableEntry(1)))

        // Stored as such, the original bytes are kept, editing is blocked,
        // and a job runs with no replacements at all.
        let unknownSuiteName = "io.github.spacevibes365.MurmurlyTests.Snippets.\(UUID().uuidString)"
        let unknownDefaults = try XCTUnwrap(UserDefaults(suiteName: unknownSuiteName))
        defer { unknownDefaults.removePersistentDomain(forName: unknownSuiteName) }
        unknownDefaults.set(badData, forKey: "dictionary.entries")
        let before = unknownDefaults.data(forKey: "dictionary.entries")
        let unknownStore = SettingsStore(defaults: unknownDefaults)
        XCTAssertTrue(unknownStore.dictionaryUnreadable)
        XCTAssertEqual(unknownStore.dictionary, [])
        XCTAssertNil(unknownStore.dictionarySnapshot.replacer(for: .dictation))
        XCTAssertThrowsError(try unknownStore.saveDictionary([entry]))
        XCTAssertEqual(unknownDefaults.data(forKey: "dictionary.entries"), before)
    }

    func testSnippetTriggerTakenByAnotherEntryIsRefused() {
        let existingReplacement = DictionaryEntry(heard: ["prompt review"], written: "Something")
        let newSnippet = snippet(["prompt review"], "Line one\nLine two")
        XCTAssertEqual(newSnippet.problem(among: [existingReplacement]), .duplicate("prompt review"))

        let existingSnippet = snippet(["prompt review"], "Line one\nLine two")
        let newReplacement = DictionaryEntry(heard: ["prompt review"], written: "Something")
        XCTAssertEqual(newReplacement.problem(among: [existingSnippet]), .duplicate("prompt review"))
    }

    /// Regression: a blank or whitespace-only snippet text, saved straight to
    /// the settings without going through the sheet's own validation
    /// (`saveDictionary` itself does not call `problem(besides:)`), must
    /// never erase the dictation it matched.
    func testEmptyOrBlankSnippetTextLeavesTheDictationUnchanged() async throws {
        for blank in ["", "   \n  "] {
            let fixture = try DictationPipelineFixture(text: "prompt review")
            defer { fixture.cleanup() }
            try fixture.settings.saveDictionary([snippet(["prompt review"], blank)])

            try await fixture.dictate()

            let delivered = await fixture.probe.deliveredTexts
            XCTAssertEqual(delivered, ["prompt review"])
            let recent = try await fixture.store.recent()
            let entry = try XCTUnwrap(recent.first)
            XCTAssertEqual(entry.text, "prompt review")
        }
    }

    func testDictatedTriggerIsDeliveredAsTheSnippetAndHistoryKeepsTheTrigger() async throws {
        let fixture = try DictationPipelineFixture(text: "prompt review")
        defer { fixture.cleanup() }
        try fixture.settings.saveDictionary([snippet(["prompt review"], "Line one\nLine two")])

        try await fixture.dictate()

        let delivered = await fixture.probe.deliveredTexts
        XCTAssertEqual(delivered, ["Line one\nLine two"])
        let recent = try await fixture.store.recent()
        let entry = try XCTUnwrap(recent.first)
        XCTAssertEqual(entry.text, "Line one\nLine two")
        XCTAssertEqual(entry.rawText, "prompt review")
    }
}
