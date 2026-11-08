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
        let model = LiveTranscriptModel()
        model.publishForTesting(lines: madeUpLines(), state: .running)
        meeting.publishLiveTranscriptForTesting(state: .recording, model: model)
    }

    /// Fictional lines only, no owner data: the oldest ("release notes") is
    /// the first a short panel clips, so a UI test checks the newest
    /// ("the menu item") and the line count instead.
    private static func madeUpLines() -> [LiveLine] {
        let now = Date.timeIntervalSinceReferenceDate
        let speakers: [(LiveTranscript.Track, String?, String)] = [
            (.system, "Ada", "Let's start the walkthrough."),
            (.microphone, nil, "Sounds good, go ahead."),
            (.system, "Ada", "First, the release notes."),
            (.microphone, nil, "Got it, thanks."),
            (.system, "Ada", "Next, the menu item.")
        ]
        return speakers.enumerated().map { offset, entry in
            let (track, name, text) = entry
            let start = now + Double(offset) * 2
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
