import AVFoundation
import Foundation

/// Compresses a finished meeting folder in place: each CAF track becomes 24-bit
/// ALAC at its own rate and channel count, checked sample by sample against the
/// CAF before the CAF goes.
///
/// Holds no state: every step is recovered from the files, so quit may kill it
/// anywhere. The invariant is that `metadata.json` always names a whole,
/// existing file. A new m4a is renamed into place first, then named in the
/// metadata, and only then is the CAF removed; an m4a the metadata does not
/// name yet is unfinished work and is made again.
enum MeetingStorage {
    /// Above ×16 (+24 dB) the peak is a glitch, not speech: scaling the whole
    /// track down that far would lose the original's quiet detail.
    static let maximumPeak: Float = 16
    /// One 24-bit step: the encoder's rounding, and +1.0 stored as 8388607.
    static let tolerance: Float = 1 / 8_388_608
    /// Written only by a finished `stop`; a folder without them is a recording
    /// in progress or one cut off by a crash, and is never touched.
    static let finishedStates: Set<String> = ["done", "suspect", "failed"]

    struct Track: Sendable {
        let key: String
        let gainKey: String
        let label: String
    }

    static let tracks = [
        Track(key: "mic", gainKey: "micGain", label: String(localized: "microphone")),
        Track(key: "system", gainKey: "systemGain", label: String(localized: "others")),
    ]

    struct Result: Sendable, Equatable {
        /// Tracks that are m4a now.
        var compressed: [String] = []
        /// Why a track stays CAF, one line per track.
        var issues: [String] = []
    }

    /// Why a track is kept as CAF on purpose.
    enum Rejection: LocalizedError, Equatable {
        case glitch(peak: Float)
        case notFinite
        case mismatch(String)

        var errorDescription: String? {
            switch self {
            case .glitch(let peak):
                let value = peak.formatted(.number.precision(.fractionLength(1)))
                return String(localized: "peak ×\(value) — looks like an audio glitch")
            case .notFinite:
                return String(localized: "samples that are not numbers")
            case .mismatch(let detail):
                return String(localized: "the compressed copy does not match the original: \(detail)")
            }
        }
    }

    // MARK: - Which folders

    /// Finished folders directly under `root` that still have work, oldest
    /// first: a CAF track the metadata names, a CAF a kill left beside the
    /// m4a that replaced it, or, when they are `moving` to an available
    /// meetings folder, every finished one. Removes what a killed move left in
    /// `root` first.
    static func foldersNeedingWork(in root: URL, moving: Bool) -> [URL] {
        removeHidden(in: root, "local copy left by a killed move", where: isOwnRemovingName)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.filter { child in
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let metadata = finishedMetadata(in: child) else { return false }
            return moving || tracks.contains { track in
                guard let name = listedName(track, in: metadata) else { return false }
                let listed = child.appendingPathComponent(name)
                if isCAF(name) { return isFile(listed) }
                // The same test `compress` removes the leftover by.
                return name.lowercased().hasSuffix(".m4a") && isFile(listed)
                    && isFile(child.appendingPathComponent((name as NSString).deletingPathExtension + ".caf"))
            }
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Read loosely, as `MeetingTranscriber.Folder.inspect` does: July
    /// recordings have no `endedAt`, and `MeetingMetadata` must keep requiring
    /// it for the quit-time proof.
    static func finishedMetadata(in directory: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("metadata.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["state"] as? String,
              finishedStates.contains(state) else { return nil }
        return object
    }

    // MARK: - Compression

    static func compress(
        _ directory: URL,
        progress: @Sendable (String) async -> Void = { _ in }
    ) async -> Result {
        var result = Result()
        guard finishedMetadata(in: directory) != nil else { return result }
        removeLeftovers(in: directory)
        for track in tracks {
            // Read again for every track: the first track's commit changed it.
            guard let metadata = finishedMetadata(in: directory),
                  let name = listedName(track, in: metadata) else { continue }
            let listed = directory.appendingPathComponent(name)
            let base = (name as NSString).deletingPathExtension
            let caf = directory.appendingPathComponent(base + ".caf")
            let m4a = directory.appendingPathComponent(base + ".m4a")
            if !isCAF(name) {
                // Already named in the metadata: a CAF left here is what a
                // kill between the commit and the removal left behind.
                if name.lowercased().hasSuffix(".m4a"), isFile(listed), isFile(caf) {
                    removeLogged(caf, "CAF after commit")
                }
                continue
            }
            guard isFile(listed) else { continue }
            if isFile(m4a) { removeLogged(m4a, "uncommitted m4a") }
            await progress(track.label)
            let started = ContinuousClock.now
            do {
                let gain = try compressTrack(listed, into: m4a)
                try commit(track, name: m4a.lastPathComponent, gain: gain, in: directory)
                result.compressed.append(name)
                AppLog.info("meeting-storage", "\(directory.lastPathComponent)/\(name) → \(m4a.lastPathComponent): "
                    + "\(fileSize(listed)) → \(fileSize(m4a)) bytes, gain \(gain), \(started.duration(to: .now))")
                // Committed: a CAF that cannot be removed now goes on the next run.
                removeLogged(listed, "CAF")
            } catch {
                let reason = (error as? Rejection)?.localizedDescription
                    ?? String(localized: "couldn’t compress: \(error.localizedDescription)")
                result.issues.append(String(localized: "\(track.label): \(reason) — kept as CAF"))
                AppLog.error("meeting-storage", "\(directory.lastPathComponent)/\(name) kept: \(reason)")
            }
        }
        return result
    }

    /// Writes the m4a under a hidden name, checks it and only then gives it
    /// its own name. Returns the gain it was written with.
    private static func compressTrack(_ caf: URL, into m4a: URL) throws -> Float {
        let partial = m4a.deletingLastPathComponent()
            .appendingPathComponent("." + m4a.deletingPathExtension().lastPathComponent + partialSuffix)
        defer { try? FileManager.default.removeItem(at: partial) }
        let (peak, channels) = try measurePeak(caf)
        guard peak <= maximumPeak else { throw Rejection.glitch(peak: peak) }
        // Rounded to nearest, peak × RN(1/peak) never exceeds 1 while 1/peak
        // is a normal float, and every smaller sample stays below that.
        let gain: Float = peak > 1 ? 1 / peak : 1
        try DictationHistoryStore.encodeAppleLossless(from: caf, to: partial, gain: gain, channels: channels)
        try verify(partial, against: caf, gain: gain)
        try FileManager.default.moveItem(at: partial, to: m4a)
        return gain
    }

    private static func measurePeak(_ url: URL) throws -> (peak: Float, channels: UInt32) {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockFrames),
              let data = buffer.floatChannelData else {
            throw DictationHistoryStore.ArchiveSampleError.unsupportedFormat
        }
        let channels = Int(file.processingFormat.channelCount)
        var peak: Float = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: blockFrames)
            guard buffer.frameLength > 0 else { break }
            for channel in 0..<channels {
                let samples = UnsafeBufferPointer(start: data[channel], count: Int(buffer.frameLength))
                for sample in samples {
                    guard sample.isFinite else { throw Rejection.notFinite }
                    peak = max(peak, abs(sample))
                }
            }
        }
        return (peak, file.fileFormat.channelCount)
    }

    /// Both files read in step, every channel: each decoded sample within one
    /// 24-bit step of the source times `gain`, and both end on the same frame.
    static func verify(_ m4a: URL, against caf: URL, gain: Float) throws {
        let source = try AVAudioFile(forReading: caf)
        let copy = try AVAudioFile(forReading: m4a)
        let channels = Int(source.processingFormat.channelCount)
        guard copy.processingFormat.channelCount == source.processingFormat.channelCount,
              copy.fileFormat.sampleRate == source.fileFormat.sampleRate else {
            throw Rejection.mismatch(String(
                localized: "another format: \(copy.fileFormat.description) instead of \(source.fileFormat.description)"
            ))
        }
        guard copy.length == source.length else {
            throw Rejection.mismatch(String(localized: "\(copy.length) frames instead of \(source.length)"))
        }
        guard let original = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: blockFrames),
              let decoded = AVAudioPCMBuffer(pcmFormat: copy.processingFormat, frameCapacity: blockFrames),
              let sourceScratch = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: blockFrames),
              let copyScratch = AVAudioPCMBuffer(pcmFormat: copy.processingFormat, frameCapacity: blockFrames),
              let expected = original.floatChannelData,
              let actual = decoded.floatChannelData else {
            throw DictationHistoryStore.ArchiveSampleError.unsupportedFormat
        }
        while source.framePosition < source.length {
            let frame = source.framePosition
            let wanted = AVAudioFrameCount(min(Int64(blockFrames), source.length - frame))
            try fill(original, from: source, frames: wanted, scratch: sourceScratch)
            try fill(decoded, from: copy, frames: wanted, scratch: copyScratch)
            guard original.frameLength == wanted, decoded.frameLength == wanted else {
                throw Rejection.mismatch(String(
                    localized: "at frame \(frame), read \(original.frameLength) and \(decoded.frameLength) of \(wanted)"
                ))
            }
            if gain != 1 { try DictationHistoryStore.scale(original, by: gain) }
            for channel in 0..<channels {
                for index in 0..<Int(wanted) where !(abs(actual[channel][index] - expected[channel][index]) <= tolerance) {
                    throw Rejection.mismatch(String(localized: "frame \(frame + Int64(index)), channel \(channel + 1)"))
                }
            }
        }
    }

    /// `AVAudioFile` may hand back fewer frames than asked for in the middle
    /// of a file (a CAF read stops at 1024-frame boundaries), so blocks are
    /// read until full or the file ends. `scratch` has the file's own format.
    private static func fill(
        _ buffer: AVAudioPCMBuffer,
        from file: AVAudioFile,
        frames: AVAudioFrameCount,
        scratch: AVAudioPCMBuffer
    ) throws {
        guard let target = buffer.floatChannelData, let source = scratch.floatChannelData else {
            throw DictationHistoryStore.ArchiveSampleError.unsupportedFormat
        }
        buffer.frameLength = 0
        while buffer.frameLength < frames, file.framePosition < file.length {
            try file.read(into: scratch, frameCount: frames - buffer.frameLength)
            guard scratch.frameLength > 0 else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                (target[channel] + Int(buffer.frameLength))
                    .update(from: source[channel], count: Int(scratch.frameLength))
            }
            buffer.frameLength += scratch.frameLength
        }
    }

    /// Names the m4a and its gain in `metadata.json`, keeping every other key.
    /// Edited loosely rather than through `MeetingMetadata`, which cannot read
    /// July recordings.
    private static func commit(_ track: Track, name: String, gain: Float, in directory: URL) throws {
        let url = directory.appendingPathComponent("metadata.json")
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              var segments = object["segments"] as? [[String: Any]],
              !segments.isEmpty else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        segments[0][track.key] = name
        if gain != 1 { segments[0][track.gainKey] = Double(gain) }
        object["segments"] = segments
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Moving and copying

    /// Why a folder or a transcript did not reach its place.
    enum DeliveryFailure: LocalizedError, Equatable {
        case unavailable(String)
        case conflict(String)
        case incomplete(String)
        case alreadyThere(String)
        case unfinished(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let path): return String(localized: "folder not available: \(path)")
            case .conflict(let name):
                return String(localized: "the meetings folder already has a different “\(name)”")
            case .incomplete(let detail): return String(localized: "the copy does not match the original: \(detail)")
            case .alreadyThere(let name): return String(localized: "“\(name)” already exists — not overwritten")
            case .unfinished(let name):
                return String(localized: "“\(name)” — recording not finished, it stays on this Mac")
            }
        }
    }

    static let removingSuffix = ".removing"
    static let movePartialMarker = ".partial-"

    /// `yyyy-MM-dd HH-mm-ss Meeting`, with `-N` when two start in one second:
    /// the only names `RecordingsStore.createSession` gives.
    static func isMeetingFolderName(_ name: String) -> Bool {
        name.wholeMatch(of: #/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}-[0-9]{2}-[0-9]{2} Meeting(-[0-9]+)?/#) != nil
    }

    /// `.<meeting>.removing`: a local folder a killed move was taking away.
    /// Only this exact form is ours; any other hidden name stays.
    static func isOwnRemovingName(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(removingSuffix)
            && isMeetingFolderName(String(name.dropFirst().dropLast(removingSuffix.count)))
    }

    /// `.<meeting>.partial-<UUID>`: a copy a killed move left at the target,
    /// which may be a folder shared with other programs and people. The marker
    /// is looked for after the leading dot only: a name that starts with it,
    /// `.partial-backup`, has no meeting before it and is someone else's.
    static func isOwnPartialCopyName(_ name: String) -> Bool {
        guard name.hasPrefix(".") else { return false }
        let rest = name.dropFirst()
        guard let marker = rest.range(of: movePartialMarker, options: .backwards) else { return false }
        return isMeetingFolderName(String(rest[..<marker.lowerBound]))
            && UUID(uuidString: String(rest[marker.upperBound...])) != nil
    }

    /// A chosen folder counts only if it exists as a folder, and one under
    /// `/Volumes` on the same volume as `/Volumes` itself does not: that is a
    /// mount point left (or made) while its disk was away, and anything put
    /// there would stay on this Mac. The startup volume `/` is no reference:
    /// on APFS it is the sealed system volume, while `/Volumes` lives on the
    /// data volume. Nothing is ever created here, the folder nor its parents.
    static func isAvailable(_ folder: URL, mounts: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true)) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        let resolved = folder.resolvingSymlinksInPath()
        let mountsPath = mounts.resolvingSymlinksInPath().path
        guard resolved.path.hasPrefix(mountsPath + "/") else { return true }
        func volume(_ url: URL) -> (any NSObjectProtocol)? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
        }
        guard let own = volume(resolved), let parent = volume(mounts) else { return false }
        return !own.isEqual(parent)
    }

    /// Moves a finished local folder into `target`: copied under a hidden
    /// name, checked, renamed into place, and only then is the local folder
    /// removed, itself renamed away first so a kill never leaves half of it
    /// looking like a meeting. Returns where the folder is now.
    static func move(
        _ folder: URL,
        into target: URL,
        localRoot: URL,
        mounts: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
    ) throws -> URL {
        let fileManager = FileManager.default
        let name = folder.lastPathComponent
        // Checked here, whoever asks: a folder without a finished stop's
        // metadata may still be written to, and a copy of it is not the
        // recording.
        guard finishedMetadata(in: folder) != nil else { throw DeliveryFailure.unfinished(name) }
        guard isAvailable(target, mounts: mounts) else { throw DeliveryFailure.unavailable(target.path) }
        removeHidden(in: target, "copy left by a killed move", where: isOwnPartialCopyName)
        let destination = target.appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) {
            // Killed between the rename and the removal: the same folder is
            // already there, byte for byte. Anything else is not ours to
            // replace, nor is a local folder that changed since that copy.
            if let problem = difference(of: folder, in: destination, comparingBytes: true) {
                AppLog.error("meeting-storage", "\(name) is taken in the meetings folder: \(problem)")
                throw DeliveryFailure.conflict(name)
            }
        } else {
            let partial = target.appendingPathComponent(
                "." + name + movePartialMarker + UUID().uuidString, isDirectory: true
            )
            do {
                try fileManager.copyItem(at: folder, to: partial)
                if let problem = difference(of: folder, in: partial) { throw DeliveryFailure.incomplete(problem) }
                try fileManager.moveItem(at: partial, to: destination)
            } catch {
                try? fileManager.removeItem(at: partial)
                throw error
            }
        }
        let away = localRoot.appendingPathComponent("." + name + removingSuffix, isDirectory: true)
        // A name in another form is not ours: the rename below then fails
        // and the local folder stays.
        if isOwnRemovingName(away.lastPathComponent), fileManager.fileExists(atPath: away.path) {
            try fileManager.removeItem(at: away)
        }
        try fileManager.moveItem(at: folder, to: away)
        removeLogged(away, "local copy after the move")
        return destination
    }

    /// The first local file the copy lacks or holds at another size, or, when
    /// `comparingBytes`, with other contents; nil only when every local file
    /// was read and matched, so a folder that cannot be read in full is never
    /// taken for its copy. One way only: exFAT and SMB add `._*` and
    /// `.DS_Store` of their own. Sizes straight after a fresh copy: read back
    /// then, the bytes would come from this Mac's own cache. Bytes when the
    /// name was already taken: that copy is an earlier one, and the local
    /// folder may have been edited since.
    static func difference(of local: URL, in copy: URL, comparingBytes: Bool = false) -> String? {
        do {
            for path in try regularFiles(in: local) {
                let source = local.appendingPathComponent(path)
                let copied = copy.appendingPathComponent(path)
                let expected = try size(of: source)
                guard let size = try? self.size(of: copied) else { return String(localized: "“\(path)” is missing") }
                if size != expected { return String(localized: "“\(path)”: \(size) bytes instead of \(expected)") }
                if comparingBytes, try !sameBytes(source, copied) {
                    return String(localized: "“\(path)”: different contents")
                }
            }
            return nil
        } catch {
            return String(localized: "not read: \(error.localizedDescription)")
        }
    }

    /// Regular files under `folder`, relative, throwing on anything it cannot
    /// list or read. Symbolic links and other special files are passed by:
    /// removing one loses no recording.
    private static func regularFiles(in folder: URL, prefix: String = "") throws -> [String] {
        let fileManager = FileManager.default
        var files: [String] = []
        for name in try fileManager.contentsOfDirectory(atPath: folder.path).sorted() {
            let item = folder.appendingPathComponent(name)
            switch try fileManager.attributesOfItem(atPath: item.path)[.type] as? FileAttributeType {
            case .typeDirectory?: files += try regularFiles(in: item, prefix: prefix + name + "/")
            case .typeRegular?: files.append(prefix + name)
            default: continue
            }
        }
        return files
    }

    private static func size(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return size.int64Value
    }

    /// Block by block: a meeting track is hundreds of megabytes.
    private static func sameBytes(_ first: URL, _ second: URL) throws -> Bool {
        let one = try FileHandle(forReadingFrom: first)
        defer { try? one.close() }
        let other = try FileHandle(forReadingFrom: second)
        defer { try? other.close() }
        // A read may stop short of the block, on a network volume above all.
        func block(_ handle: FileHandle) throws -> Data {
            var data = Data()
            while data.count < compareBlockBytes,
                  let more = try handle.read(upToCount: compareBlockBytes - data.count), !more.isEmpty {
                data += more
            }
            return data
        }
        while true {
            let (left, right) = try autoreleasepool { (try block(one), try block(other)) }
            guard left == right else { return false }
            if left.isEmpty { return true }
        }
    }

    /// The copy's name keeps the folder's seconds, so two calls in one minute
    /// never share a note, and the transcript's number: `transcript 2.md` →
    /// `… Meeting 2.md`. A file name, so never translated: the word is the
    /// folder's own English "Meeting" in every interface language, and the
    /// same meeting always gives the same note name.
    static func transcriptCopyName(folder: String, transcript: String) -> String {
        let base = folder.contains("Meeting") ? folder : folder + " Meeting"
        let stem = (transcript as NSString).deletingPathExtension
        let number = stem.hasPrefix("transcript ") ? String(stem.dropFirst("transcript".count)) : ""
        return base + number + ".md"
    }

    /// Puts one copy of a new transcript into `target`, never over a file
    /// already there: the user may have edited or renamed notes there.
    static func copyTranscript(
        _ transcript: URL,
        of folder: URL,
        into target: URL,
        mounts: URL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
    ) throws -> URL {
        let fileManager = FileManager.default
        guard isAvailable(target, mounts: mounts) else { throw DeliveryFailure.unavailable(target.path) }
        let name = transcriptCopyName(folder: folder.lastPathComponent, transcript: transcript.lastPathComponent)
        let destination = target.appendingPathComponent(name)
        guard !fileManager.fileExists(atPath: destination.path) else { throw DeliveryFailure.alreadyThere(name) }
        let temporary = target.appendingPathComponent("." + name + ".tmp-" + UUID().uuidString)
        try fileManager.copyItem(at: transcript, to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            // Someone took the name between the check and the move.
            if fileManager.fileExists(atPath: destination.path) { throw DeliveryFailure.alreadyThere(name) }
            throw error
        }
        return destination
    }

    // MARK: - Files

    static let partialSuffix = ".partial.m4a"
    private static let blockFrames: AVAudioFrameCount = 65_536
    private static let compareBlockBytes = 1 << 20

    /// Only the hidden names `compressTrack` writes; nothing else in the folder.
    private static func removeLeftovers(in directory: URL) {
        removeHidden(in: directory, "leftover") { $0.hasSuffix(partialSuffix) }
    }

    /// Hidden entries this code names itself, matched by `isOurs`.
    private static func removeHidden(in directory: URL, _ what: String, where isOurs: (String) -> Bool) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(".") && isOurs(name) {
            removeLogged(directory.appendingPathComponent(name), what)
        }
    }

    /// Reduced to the last component so a track always stays in its folder.
    private static func listedName(_ track: Track, in metadata: [String: Any]) -> String? {
        let segment = (metadata["segments"] as? [[String: Any]])?.first
        return (segment?[track.key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    private static func isCAF(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".caf")
    }

    private static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func removeLogged(_ url: URL, _ what: String) {
        do {
            try FileManager.default.removeItem(at: url)
            AppLog.info("meeting-storage", "removed \(what): \(url.lastPathComponent)")
        } catch {
            AppLog.error("meeting-storage", "could not remove \(what) \(url.path): \(error.localizedDescription)")
        }
    }
}
