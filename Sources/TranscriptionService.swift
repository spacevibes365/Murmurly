import Foundation

/// One block of the Files tab's transcript.
struct TranscriptSegment: Identifiable, Hashable, Sendable {
    let id = UUID()
    var speaker: String
    var text: String
    var start: Double? = nil   // seconds from start of audio

    init(speaker: String, text: String, start: Double? = nil) {
        self.speaker = speaker
        self.text = text
        self.start = start
    }

    init(_ line: MeetingTranscriber.Utterance) {
        self.init(speaker: line.speaker, text: line.text, start: line.start)
    }

    static func timecode(_ seconds: Double) -> String {
        let t = Int(seconds)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

enum TranscriptionError: LocalizedError, Sendable {
    case engineUnavailable(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .engineUnavailable(let message):
            return message
        case .conversionFailed(let m):
            return String(localized: "Couldn’t convert the audio: \(m)")
        }
    }
}
