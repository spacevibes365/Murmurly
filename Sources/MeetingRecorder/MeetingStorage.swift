import AVFoundation
import CryptoKit
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
extension MeetingStorage {
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

    /// Whether a file in a meeting's folder is one of the app's own: the
    /// metadata, the marks, the tracks it names or writes by default with
    /// their CAF/m4a pairs, the transcripts and their attempt records, and
    /// what a killed step leaves. Everything else is someone else's: notes
    /// the user put there, which the window shows and nothing removes.
    /// `tracks` are the names `metadata.json` lists.
    static func isOwnFile(_ name: String, tracks: [String]) -> Bool {
        if ["metadata.json", "murmurly.json"].contains(name) || defaultTrackNames.contains(name) { return true }
        let stems = Set(tracks.map { ($0 as NSString).deletingPathExtension })
        let stem = (name as NSString).deletingPathExtension
        if stems.contains(stem), name.lowercased().hasSuffix(".caf") || name.lowercased().hasSuffix(".m4a") { return true }
        if transcriptNumber(name) != nil || MeetingAttempt.number(inName: name) != nil { return true }
        if name.hasPrefix(MeetingTranscriber.temporaryPrefix), name.hasSuffix(MeetingTranscriber.temporarySuffix) { return true }
        return name.hasPrefix(".") && name.hasSuffix(partialSuffix)
    }

    /// Finder's and other volumes' own bookkeeping: neither ours nor the user's.
    static func isSystemFile(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._") || name == "Icon\r"
    }

    /// The bytes under `folder`, for a meeting's row and Storage alike: every
    /// regular file, hidden ones included (an attempt record, a copy a
    /// killed move left), links not followed. `complete` is false when
    /// anything could not be listed or measured, the folder itself included:
    /// the bytes are then only what was counted, a part that must not pass
    /// for the whole where a size is a fact about one meeting.
    static func folderSize(of folder: URL) -> (bytes: Int64, complete: Bool) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var complete = true
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in
                complete = false
                return true
            }
        ) else { return (0, false) }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else {
                complete = false
                continue
            }
            guard values.isRegularFile == true else { continue }
            guard let bytes = values.fileSize else {
                complete = false
                continue
            }
            total += Int64(bytes)
        }
        return (total, complete)
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

// MARK: - What may be removed, read strictly

/// What deletes is read strictly: a name a file may have in the meeting's
/// folder and nothing else, every object by `lstat` (a link is never
/// followed), and an error is "unknown", never "not there". The window reads
/// loosely; only what is read here is ever deleted.
extension MeetingStorage {
    /// A folder's address as the disk knows it: the folder itself, when it
    /// is there, and its path with links resolved in its parent. Two
    /// addresses are one folder when either matches: a destination not made
    /// yet is known by its path. Off the main actor for anything that may be
    /// on a network volume.
    struct Address: Equatable, Sendable {
        let identity: FolderIdentity?
        let path: String

        func isSameFolder(as other: Address) -> Bool {
            (identity != nil && identity == other.identity) || path == other.path
        }
    }

    /// `identity` nil means proven absent. Nil when anything is unknown:
    /// the parent cannot be resolved, or the path holds a link, a file, or
    /// cannot be read; an error is never taken for absence.
    static func address(of folder: URL) -> Address? {
        guard let parent = realpath(folder.deletingLastPathComponent().path, nil) else { return nil }
        defer { free(parent) }
        let path = String(cString: parent) + "/" + folder.lastPathComponent
        var info = stat()
        guard lstat(folder.path, &info) == 0 else {
            return errno == ENOENT ? Address(identity: nil, path: path) : nil
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return Address(identity: FolderIdentity(device: info.st_dev, inode: info.st_ino), path: path)
    }

    /// One file as `lstat` finds it: its name in the folder, the file itself
    /// and its size.
    struct FileFact: Equatable, Sendable {
        let name: String
        let device: Int32
        let inode: UInt64
        let bytes: Int64
    }

    enum Entry: Equatable, Sendable {
        case file(FileFact)
        case absent
        /// A link, a folder, anything but a file, or an error: never taken
        /// for a file nor for nothing.
        case unknown(String)
    }

    static func entry(_ name: String, in folder: URL) -> Entry {
        var info = stat()
        guard lstat(folder.appendingPathComponent(name).path, &info) == 0 else {
            let code = errno
            return code == ENOENT
                ? .absent : .unknown(String(localized: "“\(name)” can’t be read: \(String(cString: strerror(code)))"))
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            return .unknown(String(localized: "“\(name)” is not a plain file"))
        }
        return .file(FileFact(name: name, device: info.st_dev, inode: info.st_ino, bytes: Int64(info.st_size)))
    }

    /// A name `metadata.json` may give a track: a file directly in the
    /// meeting's folder. `../../notes.caf` is not the local `notes.caf`.
    static func isPlainTrackName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && (name as NSString).lastPathComponent == name && (lower.hasSuffix(".caf") || lower.hasSuffix(".m4a"))
    }

    /// A meeting's audio: the tracks `metadata.json` names (the default ones
    /// without it), each with its CAF/m4a pair and what a killed compression
    /// leaves.
    enum Audio: Equatable, Sendable {
        /// `missing`: the tracks with neither a CAF nor an m4a left.
        case known(files: [FileFact], missing: [String])
        case unknown(String)

        var files: [FileFact]? {
            if case .known(let files, _) = self { files } else { nil }
        }

        var bytes: Int64? { files.map { $0.reduce(0) { $0 + $1.bytes } } }
    }

    /// The tracks `metadata.json` names, system first: plain names in the
    /// folder itself, or the default ones where it names none, or without
    /// it unless `requiringMetadata`.
    private static func trackNames(in folder: URL, requiringMetadata: Bool) -> Swift.Result<[String], ReadFailure> {
        var tracks: [String] = []
        switch entry("metadata.json", in: folder) {
        case .absent:
            guard !requiringMetadata else { return .failure(ReadFailure(String(localized: "metadata.json is gone"))) }
            tracks = ["system.caf", "microphone.caf"]
        case .unknown(let reason):
            return .failure(ReadFailure(reason))
        case .file:
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("metadata.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .failure(ReadFailure(String(localized: "metadata.json can’t be read")))
            }
            // The tracks as the app writes them, or none named: anything else
            // is not taken for the default tracks.
            let segments = object["segments"]
            guard segments == nil || segments is [[String: Any]] else {
                return .failure(ReadFailure(String(localized: "metadata.json can’t be read")))
            }
            let segment = (segments as? [[String: Any]])?.first
            for (key, fallback) in [("system", "system.caf"), ("mic", "microphone.caf")] {
                guard let value = segment?[key] else {
                    tracks.append(fallback)
                    continue
                }
                guard let name = value as? String, isPlainTrackName(name) else {
                    return .failure(ReadFailure(String(localized: "metadata.json names a track outside the meeting’s folder")))
                }
                tracks.append(name)
            }
        }
        return .success(tracks)
    }

    struct ReadFailure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// `requiringMetadata`: a recording without `metadata.json` (one that
    /// broke off) is unknown, as a deletion of its audio needs it.
    static func audio(in folder: URL, requiringMetadata: Bool = false) -> Audio {
        let tracks: [String]
        switch trackNames(in: folder, requiringMetadata: requiringMetadata) {
        case .success(let names): tracks = names
        case .failure(let failure): return .unknown(failure.reason)
        }
        var files: [FileFact] = []
        var missing: [String] = []
        for track in tracks {
            let stem = (track as NSString).deletingPathExtension
            var there = false
            for name in [stem + ".caf", stem + ".m4a", "." + stem + partialSuffix] {
                switch entry(name, in: folder) {
                case .file(let fact):
                    if !files.contains(fact) { files.append(fact) }
                    if !name.hasPrefix(".") { there = true }
                case .absent:
                    continue
                case .unknown(let reason):
                    return .unknown(reason)
                }
            }
            if !there { missing.append(track) }
        }
        return .known(files: files, missing: missing)
    }

    /// What the player plays: per track, its file as the folder holds it now,
    /// the m4a once compression put it there (it takes its name only after
    /// it was checked), else the CAF; a killed compression's leftover never.
    enum Playback: Equatable, Sendable {
        /// File names in the folder; empty when no track is left.
        case tracks([MeetingAttempt.Source: String])
        case unknown(String)
    }

    static func playback(in folder: URL) -> Playback {
        let names: [String]
        switch trackNames(in: folder, requiringMetadata: false) {
        case .success(let tracks): names = tracks
        case .failure(let failure): return .unknown(failure.reason)
        }
        var tracks: [MeetingAttempt.Source: String] = [:]
        for (source, track) in zip([MeetingAttempt.Source.system, .microphone], names) {
            let stem = (track as NSString).deletingPathExtension
            for name in [stem + ".m4a", stem + ".caf"] {
                switch entry(name, in: folder) {
                case .file: tracks[source] = name
                case .absent: continue
                case .unknown(let reason): return .unknown(reason)
                }
                break
            }
        }
        return .tracks(tracks)
    }

    /// Everything at the top of a meeting's folder, for deleting it whole:
    /// files only. Finder's and volumes' own files may change, come or go
    /// (Finder rewrites `.DS_Store` while the folder is open), being files.
    struct Manifest: Equatable, Sendable {
        let folder: FolderIdentity
        let files: [FileFact]

        func matches(_ now: Manifest) -> Bool {
            folder == now.folder && Self.own(files) == Self.own(now.files)
        }

        private static func own(_ files: [FileFact]) -> [FileFact] {
            files.filter { !MeetingStorage.isSystemFile($0.name) }.sorted { $0.name < $1.name }
        }
    }

    enum ManifestRead: Equatable, Sendable {
        case read(Manifest)
        /// A folder or a link inside, or anything unreadable: not deleted by
        /// the app, the reason says where to do it.
        case refused(String)
    }

    static func manifest(of folder: URL) -> ManifestRead {
        guard let identity = FolderIdentity.of(folder) else {
            return .refused(String(localized: "The meeting folder can’t be read."))
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            return .refused(String(localized: "The meeting folder can’t be read."))
        }
        var files: [FileFact] = []
        for name in names.sorted() {
            switch entry(name, in: folder) {
            case .file(let fact): files.append(fact)
            case .absent: continue
            case .unknown(let reason):
                return .refused(String(localized: "\(reason). Delete this meeting in Finder."))
            }
        }
        return .read(Manifest(folder: identity, files: files))
    }

    // MARK: - The audio rule

    /// Whether a meeting's audio may go by the rule, read strictly: the date
    /// its first full transcription ended and the files; why it is kept; or
    /// what could not be read to tell, which keeps it too, and leaves a
    /// count of what the rule takes incomplete.
    enum Retention: Equatable, Sendable {
        case eligible(since: Date, files: [FileFact])
        case kept(String)
        case unknown(String)

        /// Due once `days` have passed since `since`.
        func due(days: Int, now: Date) -> [FileFact]? {
            guard days > 0, case .eligible(let since, let files) = self,
                  now >= since.addingTimeInterval(TimeInterval(days) * 86_400) else { return nil }
            return files
        }
    }

    /// A `complete` record that says what complete means: its transcript by
    /// name and fingerprint, an end not before its start, no piece missed,
    /// not cut short, no track missing.
    static func isConsistentComplete(_ attempt: MeetingAttempt) -> Bool {
        guard attempt.result == .complete, let transcript = attempt.transcript, transcriptNumber(transcript) != nil,
              attempt.fingerprint != nil, let ended = attempt.endedAt, ended >= attempt.startedAt else { return false }
        return attempt.failedChunks == 0 && !attempt.cutShort && attempt.missingTracks.isEmpty
    }

    /// The rule's facts. Anything not proven keeps the audio, with the
    /// reason: a fact that disproves (not done, starred, not complete,
    /// changed) or one that could not be read.
    static func audioRetention(of folder: URL) -> Retention {
        guard isMeetingFolderName(folder.lastPathComponent) else {
            return .kept(String(localized: "This is not a meeting’s folder."))
        }
        guard FolderIdentity.of(folder) != nil else { return .unknown(String(localized: "The meeting folder can’t be read.")) }
        switch entry("metadata.json", in: folder) {
        case .absent: return .kept(String(localized: "The recording broke off before it was saved."))
        case .unknown(let reason): return .unknown(reason)
        case .file:
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("metadata.json")),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .unknown(String(localized: "metadata.json can’t be read"))
            }
            guard object["state"] as? String == "done" else {
                return .kept(String(localized: "The recording was saved with a warning."))
            }
        }
        switch entry(MeetingMarks.fileName, in: folder) {
        case .absent: break
        case .unknown(let reason): return .unknown(reason)
        case .file:
            switch MeetingMarks.read(in: folder) {
            case .read(let marks) where marks.starred: return .kept(String(localized: "The meeting is starred."))
            case .read, .none: break
            case .unreadable(let reason): return .unknown(MeetingMarks.Refusal.unreadable(reason).localizedDescription)
            case .newer(let version): return .unknown(MeetingMarks.Refusal.newer(version: version).localizedDescription)
            }
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            return .unknown(String(localized: "The meeting folder can’t be read."))
        }
        let recordNames = names.filter { MeetingAttempt.number(inName: $0) != nil }
        let numbers = recordNames.compactMap(MeetingAttempt.number(inName:))
        guard !numbers.isEmpty else { return .kept(String(localized: "No record of a full transcription.")) }
        guard Set(numbers).count == numbers.count else {
            return .kept(String(localized: "Two records claim one transcription number."))
        }
        for name in recordNames {
            guard case .file = entry(name, in: folder) else {
                return .unknown(String(localized: "A transcription record can’t be read."))
            }
        }
        guard let entries = try? MeetingAttempt.entries(in: folder), entries.allSatisfy({ $0.attempt != nil }) else {
            return .unknown(String(localized: "A transcription record can’t be read."))
        }
        let attempts = entries.compactMap(\.attempt)
        guard let last = attempts.last, last.result == .complete else {
            return .kept(String(localized: "The last transcription is not complete."))
        }
        guard isConsistentComplete(last),
              let first = attempts.first(where: { $0.result == .complete }), isConsistentComplete(first),
              let since = first.endedAt, let transcript = last.transcript, let fingerprint = last.fingerprint else {
            return .kept(String(localized: "A record of a full transcription contradicts itself."))
        }
        let changed = String(localized: "The transcript was changed or is missing.")
        switch entry(transcript, in: folder) {
        case .absent: return .kept(changed)
        case .unknown(let reason): return .unknown(reason)
        case .file(let file) where file.bytes != Int64(fingerprint.bytes): return .kept(changed)
        case .file: break
        }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: folder.appendingPathComponent(transcript))
        } catch {
            return .unknown(error.localizedDescription)
        }
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == fingerprint.sha256 else {
            return .kept(changed)
        }
        switch audio(in: folder) {
        case .unknown(let reason): return .unknown(reason)
        case .known(let files, _) where files.isEmpty: return .kept(String(localized: "The meeting has no audio."))
        case .known(let files, _): return .eligible(since: since, files: files)
        }
    }

    // MARK: - Removal

    /// The only way the app deletes a meeting's files: to the Trash by hand,
    /// for good by the audio rule. Every call is made through `perform`,
    /// which checks, right before it, the folder and the file (or the whole
    /// folder's manifest) against what was confirmed, and then, after its
    /// last read of the disk, whether the call is still wanted. In a test
    /// process the disk's own calls are never made unless a test gives its
    /// own; there is no way round.
    struct Removal: Sendable {
        enum Failure: LocalizedError, Equatable {
            /// The volume has no Trash.
            case noTrash
            /// The folder or the file is not what was confirmed.
            case changed(String)
            /// The reason it was asked for is gone (the rule or the folder changed).
            case stale(String)
            case failed(String)

            var errorDescription: String? {
                switch self {
                case .noTrash: String(localized: "This disk has no Trash — delete the folder in Finder.")
                case .changed(let detail): String(localized: "Changed since it was confirmed: \(detail)")
                case .stale(let reason), .failed(let reason): reason
                }
            }
        }

        enum Target: Sendable {
            case file(FileFact)
            case folder(Manifest)
        }

        var trash: @Sendable (URL) throws -> Void
        var remove: @Sendable (URL) throws -> Void
        /// Right before `perform` reads the disk: tests hold a call there.
        var beforeCheck: @Sendable (URL) -> Void = { _ in }

        /// `target` in `folder` (the folder itself for `.folder`), to the
        /// Trash or for good. `stillWanted` runs after the last read of the
        /// disk, right before the call: a reason returned refuses it.
        func perform(
            _ target: Target,
            in folder: URL,
            folderIdentity: FolderIdentity,
            forGood: Bool,
            stillWanted: @Sendable () -> String? = { nil }
        ) -> Swift.Result<URL, Failure> {
            let url: URL
            beforeCheck(folder)
            guard FolderIdentity.of(folder) == folderIdentity else {
                return .failure(.changed(String(localized: "the meeting’s folder")))
            }
            switch target {
            case .file(let fact):
                url = folder.appendingPathComponent(fact.name)
                guard MeetingStorage.entry(fact.name, in: folder) == .file(fact) else { return .failure(.changed(fact.name)) }
            case .folder(let manifest):
                url = folder
                guard case .read(let now) = MeetingStorage.manifest(of: folder), manifest.matches(now) else {
                    return .failure(.changed(String(localized: "what the meeting’s folder holds")))
                }
            }
            if let reason = stillWanted() { return .failure(.stale(reason)) }
            do {
                try (forGood ? remove : trash)(url)
                return .success(url)
            } catch CocoaError.featureUnsupported {
                return .failure(.noTrash)
            } catch let failure as Failure {
                return .failure(failure)
            } catch {
                return .failure(.failed(error.localizedDescription))
            }
        }

        /// The disk's own calls, outside tests; in a DEBUG UI test, the probe
        /// it asked for (`-RemovalProbeTrash`); in any other test process, a
        /// refusal.
        static let live = backend(
            arguments: ProcessInfo.processInfo.arguments,
            testProcess: TestIsolation.isTestProcess,
            appMeetingsRoot: RecordingsStore.ownersMeetingsRoot()
        )

        /// The probe works only inside the root the UI test seeded, named by
        /// its own argument; without one it refuses, whatever else the
        /// process was told (the stage gate's opt-out included), and it never
        /// reaches `appMeetingsRoot`, the owner's meetings (never the root a
        /// test moved the app to), even when the seeded root is that very
        /// folder, inside it or around it.
        static func backend(arguments: [String], testProcess: Bool, appMeetingsRoot: URL) -> Removal {
            #if DEBUG
            if let index = arguments.firstIndex(of: "-RemovalProbeTrash"), index + 1 < arguments.count {
                guard let seeded = arguments.firstIndex(of: "-MeetingsProbeRoot"), seeded + 1 < arguments.count else {
                    return refusing
                }
                let root = URL(fileURLWithPath: arguments[seeded + 1], isDirectory: true)
                let app = appMeetingsRoot.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                let own = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                guard !own.hasPrefix(app), !app.hasPrefix(own) else { return refusing }
                return confined(to: [root], trash: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
            }
            #endif
            guard !testProcess else { return refusing }
            return Removal(
                trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                remove: { try FileManager.default.removeItem(at: $0) }
            )
        }

        static let refusing = Removal(
            trash: { _ in throw Failure.failed(String(localized: "Nothing is deleted in a test process without a test Trash.")) },
            remove: { _ in throw Failure.failed(String(localized: "Nothing is deleted in a test process without a test Trash.")) }
        )

        /// A test's own: its Trash is a folder of its own, and nothing outside
        /// `roots` (links resolved) is ever touched.
        static func confined(to roots: [URL], trash: URL) -> Removal {
            let allowed = roots.map { $0.resolvingSymlinksInPath().standardizedFileURL.path + "/" }
            let inside: @Sendable (URL) throws -> Void = { url in
                let path = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path + "/"
                guard allowed.contains(where: { path.hasPrefix($0) }) else {
                    throw Failure.failed(String(localized: "Nothing is deleted in a test process without a test Trash."))
                }
            }
            return Removal(
                trash: { url in
                    try inside(url)
                    let place = trash.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: url, to: place.appendingPathComponent(url.lastPathComponent))
                },
                remove: { url in
                    try inside(url)
                    try FileManager.default.removeItem(at: url)
                }
            )
        }
    }
}

// MARK: - Attempt records, written here; read in `Sources/Archive/MeetingFiles.swift`

extension MeetingAttempt {
    static func fileName(number: Int) -> String {
        namePrefix + String(format: "%04d", number) + " " + UUID().uuidString + nameSuffix
    }

    /// Creates the record of a new attempt, numbered after every record the
    /// folder holds, readable or not. Throws when it cannot be written: the
    /// attempt does not start then, or a later failure could leave no trace.
    static func begin(in folder: URL, at date: Date = Date()) throws -> (url: URL, attempt: MeetingAttempt) {
        let last = try FileManager.default.contentsOfDirectory(atPath: folder.path).compactMap(number(inName:)).max() ?? 0
        let attempt = MeetingAttempt(number: last + 1, startedAt: date)
        let url = folder.appendingPathComponent(fileName(number: attempt.number))
        try attempt.write(to: url)
        return (url, attempt)
    }

    /// Atomically: a killed write leaves the previous state of the record.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - The user's marks, written here; read in `Sources/Archive/MeetingFiles.swift`

extension MeetingMarks {
    /// What the user changed. A field set replaces the file's; a field left
    /// nil stays as the file has it. `title` set to `.some(nil)` takes the
    /// user's name out: the date shows again. A speaker's name set to nil
    /// takes it out: the transcript's label shows again.
    struct Change: Sendable, Equatable {
        var title: String?? = nil
        var starred: Bool? = nil
        /// Only the tracks named here change. Set with `updateValue`: a
        /// subscript assignment of a literal nil would drop the change itself.
        var speakers: [MeetingAttempt.Source: String?] = [:]

        var isEmpty: Bool { title == nil && starred == nil && speakers.isEmpty }

        func applied(to marks: MeetingMarks) -> MeetingMarks {
            var marks = marks
            if let title { marks.title = title }
            if let starred { marks.starred = starred }
            for (source, name) in speakers { marks.speakers[source] = name }
            return marks
        }

        /// A later change over this one: the fields it sets win.
        mutating func add(_ later: Change) {
            if let title = later.title { self.title = title }
            if let starred = later.starred { self.starred = starred }
            for (source, name) in later.speakers { speakers.updateValue(name, forKey: source) }
        }
    }

    /// Reads the file once, checks it, lays the change over that very object
    /// and writes it atomically, so every other key survives and nothing read
    /// later stands in for what was checked. Returns the marks now on disk.
    /// Nothing is written when the folder at the address is not `identity`
    /// (another folder, or a link), when the file cannot be read, is not this
    /// version's or is a later one's; only a file that is not there is new.
    /// `read` stands in for the disk in tests.
    @discardableResult
    static func write(
        _ change: Change,
        in folder: URL,
        expecting identity: FolderIdentity?,
        read: (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) throws -> MeetingMarks {
        guard let identity, FolderIdentity.of(folder) == identity else { throw Refusal.replaced }
        let url = folder.appendingPathComponent(fileName)
        var object: [String: Any] = [:]
        let data: Data?
        do {
            data = try read(url)
        } catch CocoaError.fileReadNoSuchFile {
            data = nil
        }
        if let data {
            guard let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Refusal.unreadable(String(localized: "not a JSON object"))
            }
            if case .failure(let refusal) = parse(dictionary) { throw refusal }
            object = dictionary
        }
        object["version"] = formatVersion
        if let title = change.title { object["title"] = title }
        if let starred = change.starred { object["starred"] = starred }
        if !change.speakers.isEmpty {
            // The object read, changed in place: a key of a later version in it stays.
            var names = object["speakers"] as? [String: Any] ?? [:]
            for (source, name) in change.speakers {
                if let name { names[source.rawValue] = name } else { names.removeValue(forKey: source.rawValue) }
            }
            if names.isEmpty { object.removeValue(forKey: "speakers") } else { object["speakers"] = names }
        }
        guard case .success(let marks) = parse(object) else { throw Refusal.unreadable(String(localized: "a mark of another kind")) }
        let written = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try written.write(to: url, options: .atomic)
        return marks
    }
}
