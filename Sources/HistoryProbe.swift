#if DEBUG
import Foundation

/// UI-test harness for the open history window, enabled only together with
/// `-HistoryProbeRoot <dir>` (which also moves the shared archive there). For
/// each `append-request.json` holding `{"id": …, "text": …}`, optionally with
/// `"raw_text"`, it appends one dictation through `DictationHistoryStore.shared` and confirms with
/// `appended-<id>.json`. For each `change-request` it announces a change of
/// the archive without making one, as the store does after every change, and
/// removes the request once announced: the open window reads and counts
/// again while the index stays as the test left it. It holds no UI refresh
/// logic, so the very same file also builds on the tree before the fix for
/// the red check.
@MainActor
enum HistoryProbe {
    static func startIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-HistoryProbeRoot") else { return }
        let root = DictationHistoryStore.defaultRoot()
        Task { await serve(root: root) }
    }

    private static func serve(root: URL) async {
        let request = root.appendingPathComponent("append-request.json")
        let change = root.appendingPathComponent("change-request")
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: request),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let id = json["id"].flatMap(UUID.init(uuidString:)),
               let text = json["text"] {
                try? FileManager.default.removeItem(at: request)
                await append(id: id, text: text, rawText: json["raw_text"], root: root)
            }
            if FileManager.default.fileExists(atPath: change.path) {
                await DictationHistoryStore.shared.notifyChange()
                try? FileManager.default.removeItem(at: change)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func append(id: UUID, text: String, rawText: String?, root: URL) async {
        let entry = DictationHistoryEntry(
            id: id,
            at: Date(),
            duration: 1,
            selectedLanguage: "auto",
            actualLanguage: "ru",
            targetBundleID: nil,
            targetApplicationName: "History probe",
            audioPath: "probe/\(id.uuidString).caf",
            text: text,
            rawText: rawText
        )
        var result: [String: String] = ["id": id.uuidString]
        do {
            try await DictationHistoryStore.shared.append(entry)
            result["appended"] = "true"
        } catch {
            result["error"] = error.localizedDescription
        }
        let marker = root.appendingPathComponent("appended-\(id.uuidString).json")
        if let data = try? JSONSerialization.data(withJSONObject: result) {
            try? data.write(to: marker, options: .atomic)
        }
    }
}
#endif
