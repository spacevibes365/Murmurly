#if DEBUG
import AppKit
import Foundation
import UniformTypeIdentifiers

/// UI-test harness for the Files tab, enabled only with `-FileProbeRoot
/// <dir>`. It hands the real drop handler real item providers that answer only
/// when the test opens their gate, gives a run a stand-in transcription gated
/// the same way, and stands in for the save panel: it records the name the tab
/// suggests and answers when the test opens its gate. With
/// `-FileProbeRealPanels` the real panels open instead, in the root. Every step
/// is acknowledged by a file in the root. It holds no file selection logic.
///
/// Requests: `request-<n>.json` = `{"id": …, "action": "drop", "file": …,
/// "error": "0"|"1"}`. Gates the test opens: `<id>.release`,
/// `run-<file name>.release`. Acknowledgements: `<id>.accepted` (handleDrop's
/// return value), `<id>.delivered`, `<id>.callback` (its drop callback finished),
/// `run-<file name>.started`, `save-<n>.txt` (the suggested name), then
/// the file the tab wrote: `saved-<n>.md`. A gate left closed for 30 s gives no
/// result at all, only `<id>.timeout`, `run-<file name>.timeout` or
/// `save-<n>.timeout`: a timer never stands in for a gate.
@MainActor
enum FileProbe {
    static let dropNotification = Notification.Name("FileProbeDrop")
    nonisolated static var isActive: Bool { root != nil }
    nonisolated static let root: URL? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-FileProbeRoot"),
              index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }()
    nonisolated static let usesRealPanels = ProcessInfo.processInfo.arguments.contains("-FileProbeRealPanels")
    /// Where real panels open under the probe, so a test that answers them
    /// writes nowhere else.
    nonisolated static var panelFolder: URL? { usesRealPanels ? root : nil }
    private static var providerIDs: [ObjectIdentifier: String] = [:]
    private static var saves = 0

    static func startIfRequested() {
        guard let root else { return }
        Task { await serve(root: root) }
    }

    /// Stand-in for the meeting pipeline while the probe runs: no model, no
    /// timecodes, finishes only when the test opens its gate.
    nonisolated static func transcription() -> FileTranscription? {
        guard let root else { return nil }
        return { fileURL, _ in try await probeTranscription(of: fileURL, root: root) }
    }

    /// The request id of a provider this probe handed over, if any.
    static func id(of provider: NSItemProvider) -> String? {
        providerIDs[ObjectIdentifier(provider)]
    }

    static func providers(in notification: Notification) -> [NSItemProvider] {
        (notification.userInfo?["provider"] as? NSItemProvider).map { [$0] } ?? []
    }

    static func recordDropResult(_ notification: Notification, accepted: Bool) {
        guard let root, let id = notification.userInfo?["id"] as? String else { return }
        write(accepted ? "true" : "false", to: root.appendingPathComponent("\(id).accepted"))
    }

    static func dropCallbackFinished(_ id: String?) {
        guard let root, let id else { return }
        write("finished", to: root.appendingPathComponent("\(id).callback"))
    }

    /// The save panel's stand-in, unless real panels were asked for.
    static func saveDestination() -> FilesModel.SaveDestination? {
        guard let root, !usesRealPanels else { return nil }
        return { name in await chooseSaveURL(suggesting: name, root: root) }
    }

    /// Records the suggested name, then waits for `save-<n>.release` the way
    /// the real panel's sheet waits for its answer: without holding the main
    /// thread, so whatever the tab does meanwhile goes on. Answers with a file
    /// in the root for the tab to write.
    private static func chooseSaveURL(suggesting name: String, root: URL) async -> URL? {
        saves += 1
        let number = saves
        write(name, to: root.appendingPathComponent("save-\(number).txt"))
        let gate = root.appendingPathComponent("save-\(number).release")
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !FileManager.default.fileExists(atPath: gate.path), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard FileManager.default.fileExists(atPath: gate.path) else {
            write("timeout", to: root.appendingPathComponent("save-\(number).timeout"))
            return nil
        }
        return root.appendingPathComponent("saved-\(number).md")
    }

    private static func serve(root: URL) async {
        var next = 1
        let deadline = ContinuousClock.now.advanced(by: .seconds(1_800))
        while ContinuousClock.now < deadline {
            let request = root.appendingPathComponent("request-\(next).json")
            if let data = try? Data(contentsOf: request),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let id = json["id"], json["action"] == "drop", let file = json["file"] {
                next += 1
                drop(id: id, file: URL(fileURLWithPath: file), fails: json["error"] == "1", root: root)
            } else {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private static func drop(id: String, file: URL, fails: Bool, root: URL) {
        let provider = makeProvider(id: id, file: file, fails: fails, root: root)
        providerIDs[ObjectIdentifier(provider)] = id
        NotificationCenter.default.post(
            name: dropNotification, object: nil, userInfo: ["id": id, "provider": provider]
        )
    }

    /// Nonisolated: the load handler runs synchronously inside `loadObject`,
    /// on the caller's thread — the main thread for a drop (observed on
    /// macOS 26). It returns at once; the wait for the test's gate and the
    /// answer happen on their own queue, so the drop handler is never held.
    private nonisolated static func makeProvider(
        id: String, file: URL, fails: Bool, root: URL
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        let gate = root.appendingPathComponent("\(id).release")
        let delivered = root.appendingPathComponent("\(id).delivered")
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            let answer = ProbeAnswer(completion)
            DispatchQueue(label: "FileProbe.\(id)").async {
                let waitUntil = Date().addingTimeInterval(30)
                while !FileManager.default.fileExists(atPath: gate.path), Date() < waitUntil {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                guard FileManager.default.fileExists(atPath: gate.path) else {
                    // No answer at all, so nothing in the tab can look like a drop.
                    write("timeout", to: root.appendingPathComponent("\(id).timeout"))
                    return
                }
                if fails {
                    answer.call(nil, CocoaError(.fileReadUnknown))
                } else {
                    answer.call(file.dataRepresentation, nil)
                }
                write("delivered", to: delivered)
            }
            return nil
        }
        return provider
    }

    nonisolated static func write(_ text: String, to url: URL) {
        try? Data(text.utf8).write(to: url, options: .atomic)
    }
}

/// Carries NSItemProvider's completion to the probe's own queue; it is called
/// exactly once, from that queue.
private final class ProbeAnswer: @unchecked Sendable {
    let call: (Data?, (any Error)?) -> Void
    init(_ call: @escaping (Data?, (any Error)?) -> Void) { self.call = call }
}

private struct ProbeGateTimeout: LocalizedError {
    var errorDescription: String? { "probe: the run gate did not open" }
}

private func probeTranscription(of fileURL: URL, root: URL) async throws -> [TranscriptSegment] {
    let name = fileURL.lastPathComponent
    FileProbe.write("started", to: root.appendingPathComponent("run-\(name).started"))
    let gate = root.appendingPathComponent("run-\(name).release")
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while !FileManager.default.fileExists(atPath: gate.path), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    guard FileManager.default.fileExists(atPath: gate.path) else {
        FileProbe.write("timeout", to: root.appendingPathComponent("run-\(name).timeout"))
        throw ProbeGateTimeout()
    }
    return [TranscriptSegment(speaker: "", text: "transcript \(name)")]
}
#endif
