#if DEBUG
import Foundation

/// `-UITesting -LiveTranscriptProbe`: feeds the recorder's live-transcript
/// model a few made-up lines and `.recording`, as if a meeting were under
/// way, without a capture or an engine, so `LiveTranscriptPanelUITests` can
/// see the panel. Both arguments are required: `-UITesting` alone must keep
/// behaving as every other UI test expects.
enum LiveTranscriptProbe {
    @MainActor
    static func applyIfRequested(to meeting: MeetingRecorder) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-UITesting"), arguments.contains("-LiveTranscriptProbe") else { return }
        // `-LiveTranscriptProbeManyLines` prepends 80 made-up filler lines, so
        // a UI test can check the feed scrolls and "Jump to bottom" appears;
        // the five lines below and their own order never change, so
        // `LiveTranscriptPanelUITests` stays green either way.
        let manyLines = arguments.contains("-LiveTranscriptProbeManyLines")
        let filler = manyLines ? fillerLines(count: 80) : []
        let lines = filler + madeUpLines(after: filler.last?.end ?? 0)
        let model = LiveTranscriptModel()
        model.publishForTesting(lines: lines, state: .running)
        // `-LiveTranscriptProbeSession`: a session folder (never read or
        // written to for real, like `-NotepadProbe`'s), so ★ reads as
        // recording into it — without it, `currentSession` stays nil and ★
        // stays disabled, as every other `-LiveTranscriptProbe` UI test
        // expects.
        let directory = arguments.contains("-LiveTranscriptProbeSession")
            ? FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString) Meeting")
            : nil
        meeting.publishLiveTranscriptForTesting(state: .recording, model: model, directory: directory)
        // There is no real capture behind this faked `.recording`, so the
        // clock the moment-marking path reads is the newest line's own end:
        // "Next, the menu item." stays fresh for ★/⌥⇧M without a selection.
        meeting.recordingSecondsForTesting = lines.last?.end
    }

    /// Fictional filler only, no owner data: alternating tracks, two seconds
    /// apart, so a UI test has enough rows to scroll through before reaching
    /// the five made-up lines below.
    private static func fillerLines(count: Int) -> [LiveLine] {
        (0..<count).map { index in
            let start = Double(index) * 2
            return LiveLine(
                id: UUID(),
                track: index % 2 == 0 ? .system : .microphone,
                start: start,
                end: start + 2,
                rawText: "Filler line \(index).",
                displayText: "Filler line \(index).",
                name: nil,
                isFinal: true
            )
        }
    }

    /// Fictional lines only, no owner data: the oldest ("release notes") is
    /// the first a short panel clips, so a UI test checks the newest
    /// ("the menu item") and the line count instead. `start` is seconds into
    /// the recording (0, 2, 4, …, offset by `after` when filler lines come
    /// first), never the wall clock: a real line's own scale, which a
    /// recording-time button can show as `m:ss`.
    private static func madeUpLines(after base: Double) -> [LiveLine] {
        let speakers: [(LiveTranscript.Track, String?, String)] = [
            (.system, "Ada", "Let's start the walkthrough."),
            (.microphone, nil, "Sounds good, go ahead."),
            (.system, "Ada", "First, the release notes."),
            (.microphone, nil, "Got it, thanks."),
            (.system, "Ada", "Next, the menu item.")
        ]
        return speakers.enumerated().map { offset, entry in
            let (track, name, text) = entry
            let start = base + Double(offset) * 2
            return LiveLine(
                id: UUID(),
                track: track,
                start: start,
                end: start + 2,
                rawText: text,
                displayText: text,
                name: name,
                isFinal: offset < speakers.count - 1
            )
        }
    }
}
#endif
