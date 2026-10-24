import CryptoKit
import Foundation

/// A model as published on Hugging Face, pinned to the revision the app was
/// checked with: everyone gets the same bytes, and the listing never changes.
struct ModelSource: Sendable, Equatable {
    let repo: String
    let revision: String
    /// The repository folder that becomes `destination`; "" is the root.
    let folder: String
    /// Under `folder`; a path ending in "/" takes everything below it.
    let paths: [String]
    /// Under the models folder. It appears by one rename, whole or not at all.
    let destination: String
    /// For the button, before anything is listed.
    let bytes: Int64

    /// A compiled model is complete with its `coremldata.bin`, any other file
    /// when it is there.
    var required: [String] {
        paths.map { $0.hasSuffix(".mlmodelc/") ? $0 + "coremldata.bin" : $0 }
    }

    static let parakeet = ModelSource(
        repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        revision: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
        folder: "",
        paths: [
            "Preprocessor.mlmodelc/", "Encoder.mlmodelc/", "Decoder.mlmodelc/",
            "JointDecisionv3.mlmodelc/", "parakeet_vocab.json",
        ],
        destination: "parakeet-tdt-0.6b-v3",
        bytes: 483_105_645
    )
    static let whisper = ModelSource(
        repo: "argmaxinc/whisperkit-coreml",
        revision: "0f63a7800b00dd0226abd051b906c246e1907482",
        folder: "openai_whisper-large-v3-v20240930_turbo/",
        paths: [
            "AudioEncoder.mlmodelc/", "MelSpectrogram.mlmodelc/", "TextDecoder.mlmodelc/",
            "TextDecoderContextPrefill.mlmodelc/", "config.json", "generation_config.json",
        ],
        destination: "openai_whisper-large-v3-v20240930_turbo",
        bytes: 1_638_464_446
    )
    /// The Core ML weights come without a tokenizer. Only its json and merges
    /// are taken, not the gigabytes of PyTorch weights next to them.
    static let whisperTokenizer = ModelSource(
        repo: "openai/whisper-large-v3",
        revision: "06f233fe06e710322aca913c1bc4249a0d71fce1",
        folder: "",
        paths: [
            "added_tokens.json", "config.json", "generation_config.json", "merges.txt",
            "normalizer.json", "preprocessor_config.json", "special_tokens_map.json",
            "tokenizer.json", "tokenizer_config.json", "vocab.json",
        ],
        destination: "openai/whisper-large-v3",
        bytes: 4_388_788
    )
    /// Finds speech in meetings; a megabyte, so it comes with either engine.
    static let vad = ModelSource(
        repo: "FluidInference/silero-vad-coreml",
        revision: "b419383c55c110e2c9271fa6ee0ea83d03c70d96",
        folder: "silero-vad-unified-256ms-v6.2.1.mlmodelc/",
        paths: [
            "coremldata.bin", "metadata.json", "model.mil",
            "weights/weight.bin", "analytics/coremldata.bin",
        ],
        destination: "silero-vad-unified-256ms-v6.2.1.mlmodelc",
        bytes: 1_063_425
    )
}

extension DictationEngine {
    /// What dictation loads, tokenizer before the Whisper model.
    var models: [ModelSource] { self == .whisper ? [.whisperTokenizer, .whisper] : [.parakeet] }
    var modelName: String { self == .whisper ? "Whisper large-v3 turbo" : "Parakeet v3" }
}

/// Puts models into the app's one models folder, one engine at a time. Files
/// gather in a `.partial-…` folder on the same volume and every model moves
/// into place by one rename, so a model folder is never half there. This is
/// the app's only network access: FluidAudio stays in `ModelHub.offlineMode`
/// and WhisperKit loads with `download: false`.
@MainActor
final class ModelDownloader: ObservableObject {
    struct Download: Equatable {
        let engine: DictationEngine
        var received: Int64 = 0
        /// Zero until the listing is in.
        var total: Int64 = 0

        var progressText: String {
            total == 0
                ? String(localized: "getting the file list…")
                : String(localized: "\(ModelDownloader.sizeText(received)) of \(ModelDownloader.sizeText(total))")
        }
    }

    struct Failure: Equatable {
        let engine: DictationEngine
        let message: String
    }

    enum InstallError: LocalizedError, Equatable {
        case server(status: Int, path: String)
        case damaged(String)
        case incomplete(String)
        case occupied(String)

        var errorDescription: String? {
            switch self {
            case let .server(status, path):
                return String(localized: "Hugging Face did not send \(path) (code \(status))")
            case let .damaged(path):
                return String(localized: "\(path) arrived damaged — try again")
            case let .incomplete(repo):
                return String(localized: "\(repo) does not have all the model files")
            case let .occupied(path):
                return String(localized: """
                    The folder \(path) already exists, but the model in it is missing files. \
                    Move this folder elsewhere with its contents and download again
                    """)
            }
        }
    }

    nonisolated static let defaultRoot = URL(
        fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Murmurly/Models",
        isDirectory: true
    )
    nonisolated static let partialPrefix = ".partial-"
    /// No cache or cookies: nothing about the download outlives it.
    nonisolated static let session = URLSession(configuration: .ephemeral)

    @Published private(set) var download: Download?
    @Published private(set) var failure: Failure?
    /// Counts finished downloads; the dictation warms the new model up on it.
    @Published private(set) var installs = 0

    nonisolated let root: URL
    private let session: URLSession
    private let host: URL
    private var task: Task<Void, Never>?
    private var attempt: UInt = 0

    init(
        root: URL = ModelDownloader.defaultRoot,
        session: URLSession = ModelDownloader.session,
        host: URL = URL(string: "https://huggingface.co")!
    ) {
        self.root = root
        self.session = session
        self.host = host
    }

    /// Dictation can start: the engine's own files are in place.
    func isReady(_ engine: DictationEngine) -> Bool {
        engine.models.allSatisfy { isInstalled($0) }
    }

    /// What is left to download for the engine, speech detection included.
    func missing(_ engine: DictationEngine) -> [ModelSource] {
        (engine.models + [.vad]).filter { !isInstalled($0) }
    }

    nonisolated func isInstalled(_ source: ModelSource) -> Bool {
        Self.isInstalled(source, in: root)
    }

    nonisolated static func isInstalled(_ source: ModelSource, in root: URL) -> Bool {
        let folder = root.appendingPathComponent(source.destination, isDirectory: true)
        return source.required.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    func start(_ engine: DictationEngine) {
        guard download == nil else { return }
        let sources = missing(engine)
        guard !sources.isEmpty else { return }
        failure = nil
        attempt &+= 1
        let attempt = attempt
        download = Download(engine: engine)
        AppLog.info("models", "download \(engine.rawValue): \(sources.map(\.destination))")
        let (root, session, host) = (self.root, self.session, self.host)
        task = Task {
            var outcome: (any Error)?
            do {
                try await Self.install(sources, into: root, session: session, host: host) { received, total in
                    Task { @MainActor in self.show(received, of: total, attempt: attempt) }
                }
            } catch {
                outcome = error
            }
            finish(attempt: attempt, error: outcome)
        }
    }

    /// Whatever was fetched goes with the `.partial` folder; models already
    /// in place stay.
    func cancel() {
        task?.cancel()
    }

    nonisolated static func sizeText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    private func show(_ received: Int64, of total: Int64, attempt: UInt) {
        // Updates hop to the main actor one by one; a late one never moves
        // the bar back.
        guard attempt == self.attempt, var current = download, received >= current.received else { return }
        current.received = received
        current.total = total
        download = current
    }

    private func finish(attempt: UInt, error: (any Error)?) {
        guard attempt == self.attempt, let engine = download?.engine else { return }
        task = nil
        download = nil
        guard let error else {
            installs += 1
            AppLog.info("models", "installed \(engine.rawValue)")
            return
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            AppLog.info("models", "download cancelled")
        } else {
            failure = Failure(engine: engine, message: error.localizedDescription)
            AppLog.error("models", "download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Network and files

    private struct Entry: Decodable {
        struct LFS: Decodable { let oid: String }
        let type: String
        let path: String
        let size: Int64
        /// Large files carry their sha256; small ones only a git hash.
        let lfs: LFS?
    }

    nonisolated static func install(
        _ sources: [ModelSource],
        into root: URL,
        session: URLSession,
        host: URL,
        progress: @escaping @Sendable (_ received: Int64, _ total: Int64) -> Void
    ) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        // What a download cut short by quit or a crash left: only a folder
        // named exactly the way this code names one. Anything else that merely
        // starts the same is someone else's.
        for name in (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        where name.hasPrefix(partialPrefix) && UUID(uuidString: String(name.dropFirst(partialPrefix.count))) != nil {
            var isDirectory: ObjCBool = false
            let leftover = root.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: leftover.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            try? fileManager.removeItem(at: leftover)
        }
        let staging = root.appendingPathComponent(partialPrefix + UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        var plan: [(source: ModelSource, files: [Entry])] = []
        for source in sources {
            plan.append((source, try await listing(of: source, session: session, host: host)))
        }
        let total = plan.flatMap(\.files).reduce(0) { $0 + $1.size }
        var received: Int64 = 0
        progress(0, total)
        for (source, files) in plan {
            let folder = staging.appendingPathComponent(source.destination, isDirectory: true)
            for file in files {
                let before = received
                try await fetch(
                    file, of: source,
                    to: folder.appendingPathComponent(String(file.path.dropFirst(source.folder.count))),
                    session: session, host: host
                ) { progress(before + $0, total) }
                received += file.size
                progress(received, total)
            }
        }
        // In the order given: the tokenizer is in place before the model
        // that needs it. A cancel that came after the last byte still stops
        // whatever is not in place yet; what is already there stays.
        for (source, _) in plan {
            try Task.checkCancellation()
            guard isInstalled(source, in: staging) else { throw InstallError.incomplete(source.repo) }
            let staged = staging.appendingPathComponent(source.destination, isDirectory: true)
            let target = root.appendingPathComponent(source.destination, isDirectory: true)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // rename(2) takes the place of an empty folder, never of one
            // with something in it.
            guard rename(staged.path, target.path) == 0 else {
                let code = errno
                if code == ENOTEMPTY || code == EEXIST { throw InstallError.occupied(target.path) }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
    }

    private nonisolated static func listing(
        of source: ModelSource,
        session: URLSession,
        host: URL
    ) async throws -> [Entry] {
        var url = host.appending(path: "api/models/\(source.repo)/tree/\(source.revision)")
        if !source.folder.isEmpty { url.append(path: String(source.folder.dropLast())) }
        url.append(queryItems: [URLQueryItem(name: "recursive", value: "true")])
        let (data, response) = try await session.data(from: url)
        try check(response, path: source.repo)
        return try JSONDecoder().decode([Entry].self, from: data).filter { entry in
            guard entry.type == "file", entry.path.hasPrefix(source.folder) else { return false }
            let path = entry.path.dropFirst(source.folder.count)
            return source.paths.contains { $0.hasSuffix("/") ? path.hasPrefix($0) : path == $0 }
        }
    }

    private nonisolated static func fetch(
        _ entry: Entry,
        of source: ModelSource,
        to target: URL,
        session: URLSession,
        host: URL,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let url = host.appending(path: "\(source.repo)/resolve/\(source.revision)/\(entry.path)")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        let writer = FileWriter(handle: handle, report: progress)
        let written = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { writer.start(URLRequest(url: url), in: session, $0) }
        } onCancel: {
            writer.cancel()
        }
        try check(written.response, path: entry.path)
        guard written.size == entry.size, entry.lfs.map({ $0.oid == written.sha256 }) ?? true else {
            throw InstallError.damaged(entry.path)
        }
    }

    private nonisolated static func check(_ response: URLResponse, path: String) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw InstallError.server(status: status, path: path) }
    }
}

/// Writes one file straight into the `.partial` folder and hashes it on the
/// way. A download task would keep the body in the system's temporary folder
/// and leave it there when cancelled or cut off (checked on macOS 26).
private final class FileWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Written = (response: URLResponse, size: Int64, sha256: String)

    private let lock = NSLock()
    private let handle: FileHandle
    private let report: @Sendable (Int64) -> Void
    private var hasher = SHA256()
    private var received: Int64 = 0
    private var reported: Int64 = 0
    private var writeError: (any Error)?
    private var task: URLSessionTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<Written, any Error>?

    init(handle: FileHandle, report: @escaping @Sendable (Int64) -> Void) {
        self.handle = handle
        self.report = report
    }

    func start(_ request: URLRequest, in session: URLSession, _ continuation: CheckedContinuation<Written, any Error>) {
        let task = session.dataTask(with: request)
        task.delegate = self
        let cancelled = lock.withLock {
            self.continuation = continuation
            self.task = task
            return self.cancelled
        }
        task.resume()
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            return task
        }?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (failed, progress): (Bool, Int64?) = lock.withLock {
            guard writeError == nil else { return (true, nil) }
            do {
                try handle.write(contentsOf: data)
            } catch {
                writeError = error
                return (true, nil)
            }
            hasher.update(data: data)
            received += Int64(data.count)
            // A report per megabyte: a big file arrives in thousands of pieces.
            guard received - reported >= 1 << 20 else { return (false, nil) }
            reported = received
            return (false, received)
        }
        if failed { dataTask.cancel() }
        if let progress { report(progress) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, result): (CheckedContinuation<Written, any Error>?, Result<Written, any Error>) = lock.withLock {
            defer { self.continuation = nil }
            if let failure = writeError ?? error {
                return (self.continuation, .failure(failure))
            }
            guard let response = task.response else {
                return (self.continuation, .failure(URLError(.badServerResponse)))
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (self.continuation, .success((response, received, digest)))
        }
        continuation?.resume(with: result)
    }
}
