#if DEBUG
import AppKit
import Foundation
import UniformTypeIdentifiers

/// UI-test harness for the Files tab, enabled only with `-FileProbeRoot
/// <dir>`. It hands the real drop handler real item providers that answer only
/// when the test opens their gate, gives a run a stand-in transcription gated
/// the same way, and answers every panel of the app's windows in their place:
/// a test process never opens a real one (`FilesModel.panelBackend`). Every
/// step is acknowledged by a file in the root. It holds no file selection logic.
///
/// Every panel asked for is the n-th: while `present.hold` is in the root it
/// says `present-<n>.holding` and waits for `present-<n>.release` (30 s, then
/// `present-<n>.timeout` and no panel). Then `present-<n>.owner` names the
/// window it goes on (its identifier), or `present-<n>.cancelled` says that
/// window was gone. The open panel of Files answers with the path in
/// `choose-file-<n>.txt`, as if cancelled while there is none.
///
/// Requests: `request-<n>.json` = `{"id": …, "action": "drop", "file": …,
/// "error": "0"|"1"}`. Gates the test opens: `<id>.release`,
/// `run-<file name>.release`. Acknowledgements: `<id>.accepted` (handleDrop's
/// return value), `<id>.delivered`, `<id>.callback` (its drop callback finished),
/// `run-<file name>.choice` (the run's engine and language, `engine:code`, or
/// `as dictation`) and then `run-<file name>.started`, `save-<n>.txt` (the
/// suggested name), then
/// the file the tab wrote: `saved-<n>.md`. A gate left closed for 30 s gives no
/// result at all, only `<id>.timeout`, `run-<file name>.timeout` or
/// `save-<n>.timeout`: a timer never stands in for a gate.
///
/// The Dictionary tab's panels answer at once: the n-th import reads
/// `dictionary-import-<n>.json` in the root, as if cancelled while there is
/// none, and the n-th export goes to `dictionary-export-<n>.json` there. Only
/// an import's panel the test holds with `dictionary-import-<n>.hold` waits:
/// it says `dictionary-import-<n>.choosing` and answers once
/// `dictionary-import-<n>.chosen` is there; held for 30 s, it answers as
/// cancelled and leaves `dictionary-import-<n>.timeout`. The reading and the
/// writing have gates. A read says
/// `dictionary-import-<n>.reading`, then waits for `dictionary-import-<n>.release`;
/// once the tab has handled its answer, whatever it did with it, there is
/// `dictionary-import-<n>.handled`. A write says `dictionary-export-<n>.writing`,
/// then waits for `dictionary-export-<n>.release` to write or
/// `dictionary-export-<n>.fail` to fail. A gate left closed for 30 s fails the
/// read or write and leaves `<name>.timeout`.
///
/// A meeting's transcript saved as a file answers at once too: the n-th
/// save goes to `meeting-export-<n>.<ext>`
/// in the root, the name the window suggested in `meeting-export-<n>.name`.
/// Only into a root that is a temporary folder, checked before anything is
/// written there.
///
/// A meeting's marks are written as usual unless the test holds the n-th
/// write with `marks-<n>.hold`: it then says `marks-<n>.writing` and waits
/// for `marks-<n>.release` to write or `marks-<n>.fail` to fail; held for
/// 30 s, it fails and leaves `marks-<n>.timeout`. Only a write off the main
/// actor (a meeting in the chosen meetings folder) may be held.
@MainActor
enum FileProbe {
    static let dropNotification = Notification.Name("FileProbeDrop")
    nonisolated static var isActive: Bool { root != nil }
    nonisolated static let root: URL? = root(in: ProcessInfo.processInfo.arguments)

    /// The probe's root, only a temporary folder: every file the probe
    /// writes, a panel's markers and answers included, and every file the
    /// app writes where the probe tells it, is inside it. Any other root
    /// leaves the probe off, with nothing written anywhere.
    nonisolated static func root(in arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "-FileProbeRoot"),
              index + 1 < arguments.count else { return nil }
        let root = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        return isTemporary(root) ? root : nil
    }
    private static var providerIDs: [ObjectIdentifier: String] = [:]
    /// Panels asked for, by root: a test's root counts from 1.
    private static var presents: [String: Int] = [:]
    private static var fileChoices = 0
    private static var saves = 0
    private static var dictionaryImports = 0
    private static var dictionaryExports = 0
    private static var meetingExports = 0

    static func startIfRequested() {
        guard let root else { return }
        Task { await serve(root: root) }
    }

    /// Stand-in for the meeting pipeline while the probe runs: no model, no
    /// timecodes, finishes only when the test opens its gate. It says what
    /// the run was started with, the argument itself, not the menu.
    nonisolated static func transcription(choice: SettingsSnapshot.Choice?) -> FileTranscription? {
        guard let root else { return nil }
        let asked = choice.map { "\($0.engine.rawValue):\($0.language)" } ?? "as dictation"
        return { fileURL, _ in try await probeTranscription(of: fileURL, asked: asked, root: root) }
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

    /// One panel asked for, by its number, from its hold to where it went:
    /// a panel answered while another waits says nothing for that one.
    struct Shown {
        let number: Int
        let root: URL
        var name: String { "present-\(number)" }
    }

    /// Numbers the panel and holds it while the test asks. `comes` false:
    /// held for 30 s, no panel at all.
    static func holdPresent(root: URL?) async -> (shown: Shown?, comes: Bool) {
        guard let root else { return (nil, true) }
        let number = presents[root.path, default: 0] + 1
        presents[root.path] = number
        let shown = Shown(number: number, root: root)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("present.hold").path) else { return (shown, true) }
        write("holding", to: root.appendingPathComponent("\(shown.name).holding"))
        let gate = root.appendingPathComponent("\(shown.name).release")
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !FileManager.default.fileExists(atPath: gate.path), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard FileManager.default.fileExists(atPath: gate.path) else {
            write("timeout", to: root.appendingPathComponent("\(shown.name).timeout"))
            return (shown, false)
        }
        return (shown, true)
    }

    /// The window that very panel goes on, or none.
    static func presented(_ shown: Shown?, on owner: NSWindow?) {
        guard let shown else { return }
        if let owner {
            write(owner.identifier?.rawValue ?? "", to: shown.root.appendingPathComponent("\(shown.name).owner"))
        } else {
            write("cancelled", to: shown.root.appendingPathComponent("\(shown.name).cancelled"))
        }
    }

    /// A panel's answer in a test process, by what it is for.
    static func answer(_ panel: NSSavePanel, for purpose: FilesModel.PanelPurpose, root: URL) async -> URL? {
        switch purpose {
        case .fileToTranscribe:
            fileChoices += 1
            let path = try? String(contentsOf: root.appendingPathComponent("choose-file-\(fileChoices).txt"), encoding: .utf8)
            return path.map { URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        case .filesTranscript:
            return await chooseSaveURL(suggesting: panel.nameFieldStringValue, root: root)
        case .dictionaryImport:
            return await dictionaryFile(opening: true, root: root)
        case .dictionaryExport:
            return await dictionaryFile(opening: false, root: root)
        case .meetingTranscript:
            return meetingExport(suggesting: panel.nameFieldStringValue, root: root)
        }
    }

    /// The Dictionary tab's open (`opening`) or save panel. A held one waits
    /// the way the real sheet does, without holding the main thread, so a
    /// change of tab meanwhile goes through the tab as it would.
    private static func dictionaryFile(opening: Bool, root: URL) async -> URL? {
        if opening {
            dictionaryImports += 1
            let name = "dictionary-import-\(dictionaryImports)"
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("\(name).hold").path) {
                write("choosing", to: root.appendingPathComponent("\(name).choosing"))
                let gate = root.appendingPathComponent("\(name).chosen")
                let deadline = ContinuousClock.now.advanced(by: .seconds(30))
                while !FileManager.default.fileExists(atPath: gate.path), ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                guard FileManager.default.fileExists(atPath: gate.path) else {
                    write("timeout", to: root.appendingPathComponent("\(name).timeout"))
                    return nil
                }
            }
            let url = root.appendingPathComponent("\(name).json")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        dictionaryExports += 1
        return root.appendingPathComponent("dictionary-export-\(dictionaryExports).json")
    }

    /// A meeting transcript's save panel, answered at once with a file in the
    /// root, the name suggested beside it.
    static func meetingExport(suggesting name: String, root: URL) -> URL? {
        meetingExports += 1
        let stem = "meeting-export-\(meetingExports)"
        write(name, to: root.appendingPathComponent(stem + ".name"))
        return root.appendingPathComponent(stem + "." + (name as NSString).pathExtension)
    }

    /// The window's write of a meeting's marks, held when the test asks.
    nonisolated static func marksWrite() -> MeetingLibrary.Reader.MarksWrite? {
        guard let root else { return nil }
        let count = ProbeCount()
        return { change, folder, identity in
            let name = "marks-\(count.next())"
            func mark(_ suffix: String) -> URL { root.appendingPathComponent("\(name).\(suffix)") }
            if FileManager.default.fileExists(atPath: mark("hold").path) {
                write("writing", to: mark("writing"))
                let deadline = Date().addingTimeInterval(30)
                while ![mark("release"), mark("fail")].contains(where: { FileManager.default.fileExists(atPath: $0.path) }),
                      Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if FileManager.default.fileExists(atPath: mark("fail").path) { throw CocoaError(.fileWriteVolumeReadOnly) }
                guard FileManager.default.fileExists(atPath: mark("release").path) else {
                    write("timeout", to: mark("timeout"))
                    throw ProbeGateTimeout()
                }
            }
            return try MeetingMarks.write(change, in: folder, expecting: identity)
        }
    }

    /// The window's read of a transcript, held while the test keeps
    /// `text.hold` in the root, as a slow network volume would: `text.reading`
    /// says a read waits, `text.released` that it goes on.
    nonisolated static func textRead() -> (@Sendable (URL) throws -> String)? {
        guard let root else { return nil }
        return { file in
            let hold = root.appendingPathComponent("text.hold")
            if FileManager.default.fileExists(atPath: hold.path) {
                write(file.deletingLastPathComponent().lastPathComponent, to: root.appendingPathComponent("text.reading"))
                let deadline = Date().addingTimeInterval(30)
                while FileManager.default.fileExists(atPath: hold.path), Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                write("released", to: root.appendingPathComponent("text.released"))
            }
            return try String(contentsOf: file, encoding: .utf8)
        }
    }

    /// Inside this process's temporary folder, `/tmp`, or the temporary
    /// folder of a sandboxed app's container (the UI test runner's own,
    /// where its tests make their roots), links followed.
    nonisolated static func isTemporary(_ folder: URL) -> Bool {
        func resolved(_ url: URL) -> [String] { url.resolvingSymlinksInPath().standardizedFileURL.pathComponents }
        let path = resolved(folder)
        func inside(_ parent: [String]) -> Bool { path.count > parent.count && Array(path.prefix(parent.count)) == parent }
        if inside(resolved(FileManager.default.temporaryDirectory)) || inside(resolved(URL(fileURLWithPath: "/tmp"))) {
            return true
        }
        let containers = resolved(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers"))
        return inside(containers) && path.count > containers.count + 3
            && path[containers.count + 1] == "Data" && path[containers.count + 2] == "tmp"
    }

    /// The Dictionary tab's import read while the probe answers its panels.
    nonisolated static func dictionaryRead() -> SettingsStore.FileRead? {
        guard let root else { return nil }
        return { url in
            let name = url.deletingPathExtension().lastPathComponent
            let gate = root.appendingPathComponent("\(name).release")
            write("reading", to: root.appendingPathComponent("\(name).reading"))
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !FileManager.default.fileExists(atPath: gate.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard FileManager.default.fileExists(atPath: gate.path) else {
                write("timeout", to: root.appendingPathComponent("\(name).timeout"))
                throw ProbeGateTimeout()
            }
            return try Data(contentsOf: url)
        }
    }

    /// The tab is done with an import's answer, dropped or not.
    static func dictionaryImportHandled(_ url: URL) {
        guard let root else { return }
        write("handled", to: root.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).handled"))
    }

    /// The Dictionary tab's export write while the probe answers its panels.
    nonisolated static func dictionaryWrite() -> SettingsStore.FileWrite? {
        guard let root else { return nil }
        return { data, url in
            let name = url.deletingPathExtension().lastPathComponent
            func mark(_ suffix: String) -> URL { root.appendingPathComponent("\(name).\(suffix)") }
            write("writing", to: mark("writing"))
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while ![mark("release"), mark("fail")].contains(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            if FileManager.default.fileExists(atPath: mark("release").path) {
                try data.write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: mark("fail").path) {
                throw CocoaError(.fileWriteNoPermission)
            } else {
                write("timeout", to: mark("timeout"))
                throw ProbeGateTimeout()
            }
        }
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

    /// Every marker the probe writes goes through `writer`, which a test
    /// may stand in for, so a write is counted, never made.
    nonisolated static func write(_ text: String, to url: URL) {
        writer.write(Data(text.utf8), url)
    }

    nonisolated static let writer = ProbeWriter()
}

/// The probe's last call to the disk, replaceable by a test that counts.
final class ProbeWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var standIn: (@Sendable (Data, URL) -> Void)?

    func write(_ data: Data, _ url: URL) {
        if let standIn = lock.withLock({ standIn }) {
            standIn(data, url)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Until `restore`, every write goes to `write` instead of the disk.
    func standIn(_ write: @escaping @Sendable (Data, URL) -> Void) {
        lock.withLock { standIn = write }
    }

    func restore() {
        lock.withLock { standIn = nil }
    }
}

/// Numbers the probe's writes, from any thread.
private final class ProbeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
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

private func probeTranscription(of fileURL: URL, asked: String, root: URL) async throws -> [TranscriptSegment] {
    let name = fileURL.lastPathComponent
    // Before "started": a test that sees the start reads this run's choice.
    FileProbe.write(asked, to: root.appendingPathComponent("run-\(name).choice"))
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
