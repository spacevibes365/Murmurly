import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import Synchronization

enum SystemAudioCaptureError: LocalizedError, Equatable, Sendable {
    case alreadyRunning
    case notRunning
    case microphoneUnavailable
    case noInputDevice
    /// The microphone showed no input stream or channel: it is being
    /// connected or reconfigured, for example as another app takes it.
    case microphoneNotReady
    case captureFailed(message: String, savedAt: URL)
    case coreAudio(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return String(localized: "Meeting recording is already running")
        case .notRunning:
            return String(localized: "Meeting recording is not running")
        case .microphoneUnavailable:
            return String(localized: "Microphone unavailable — check the permission and the input device")
        case .noInputDevice:
            return String(localized: "Microphone unavailable (no input device)")
        case .microphoneNotReady:
            return String(localized: "The microphone isn’t ready (no input channels yet)")
        case let .captureFailed(message, savedAt):
            return String(localized: "The recording was only partly saved: \(savedAt.path). \(message)")
        case let .coreAudio(operation, status):
            return "\(operation): Core Audio \(Self.describe(status))"
        }
    }

    var savedDirectory: URL? {
        if case let .captureFailed(_, savedAt) = self { return savedAt }
        return nil
    }

    private static func describe(_ status: OSStatus) -> String {
        let raw = UInt32(bitPattern: status)
        let bytes: [UInt8] = [
            UInt8((raw >> 24) & 0xff), UInt8((raw >> 16) & 0xff),
            UInt8((raw >> 8) & 0xff), UInt8(raw & 0xff),
        ]
        if bytes.allSatisfy({ (32...126).contains($0) }) {
            return "'\(String(bytes: bytes, encoding: .ascii) ?? "????")' (\(status))"
        }
        return "\(status)"
    }
}

/// A snapshot of the live audio ring (`LiveAudioRing.read()`): the same
/// frames that went into the meeting's tracks, read by the meeting's
/// `LiveTranscript`. `firstFrame` counts the same way as `writtenFrames`.
struct LiveAudio: Sendable {
    let sampleRate: Double
    let microphoneChannels: Int
    let firstFrame: Int64
    let system: [Float]
    let microphone: [Float]
    let dropped: Int64
}

/// A preallocated ring of the same audio the IOProc writes to the meeting's
/// two tracks, for a live-transcript pipeline to read while the call is still
/// going. One writer (the IOProc, `write`) and one reader (the capture actor,
/// serialized by the actor, `read`); `@unchecked Sendable` because every
/// field below is owned by exactly one side and the two talk only through the
/// atomics, in release/acquire pairs that this type documents at each use.
///
/// The buffers are raw memory, not Swift arrays: the IOProc may not allocate,
/// lock or lose time to copy-on-write. Both are zero-filled in `init`, before
/// capture starts, so the first cycles never fault in fresh pages on the
/// realtime thread.
private final class LiveAudioRing: @unchecked Sendable {
    let sampleRate: Double
    let capacity: Int
    /// Channels the IOProc's microphone buffer actually carries this cycle.
    let streamMicrophoneChannels: Int
    /// Channels kept in the ring: equal to `streamMicrophoneChannels` for one
    /// or two of them, 1 (channel 0) for three or more — the same split the
    /// microphone file makes (`createFirstChannelFile`).
    let microphoneChannels: Int

    private let systemBuffer: UnsafeMutablePointer<Float>
    private let microphoneBuffer: UnsafeMutablePointer<Float>

    /// Frames written to the ring so far, by the writer's own count (not the
    /// track's `firstFrame`, which can jump after a drop). Writer: `.releasing`
    /// after the samples are copied. Reader: `.acquiring`, before it reads
    /// anything else published alongside it (`baseFrame`, `basePosition`,
    /// `droppedTotal`).
    private let written = Atomic<Int64>(0)
    /// Frames the reader has taken out of the ring. Reader: `.releasing`
    /// after it has copied the samples out, so the writer only overwrites
    /// space the reader is done with. Writer: `.acquiring`, before deciding
    /// whether there is room for a new cycle.
    private let readIndex = Atomic<Int64>(0)
    /// Frames dropped by a full ring, published the same way as `written`:
    /// writer `wrappingAdd(ordering: .releasing)`, reader
    /// `load(ordering: .acquiring)`. A plain `.relaxed` pair would let the
    /// reader's acquire of `written` land before a drop recorded just after
    /// it, pushing that loss into the snapshot after the one it belongs to.
    private let droppedTotal = Atomic<Int64>(0)
    /// The track frame number of ring position `basePosition`, i.e. of
    /// `written`/`read` when the ring was last empty and a new base was set.
    /// `.relaxed`: both are written by the writer strictly before the
    /// release-store of `written` that makes the cycle visible, and read by
    /// the reader strictly after the acquire-load of `written` that makes the
    /// cycle visible, so the acquire/release pair on `written` already
    /// orders them.
    private let baseFrame = Atomic<Int64>(0)
    private let basePosition = Atomic<Int64>(0)

    // Writer-only (the IOProc never runs concurrently with itself).
    private var writePosition: Int64 = 0
    private var nextFrame: Int64 = 0
    private var needsBase = true

    // Reader-only (the capture actor serializes every call).
    private var reportedDropped: Int64 = 0

    init(sampleRate: Double, capacity: Int, streamMicrophoneChannels: Int, microphoneChannels: Int) {
        self.sampleRate = sampleRate
        self.capacity = capacity
        self.streamMicrophoneChannels = streamMicrophoneChannels
        self.microphoneChannels = microphoneChannels
        let system = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        system.initialize(repeating: 0, count: capacity)
        systemBuffer = system
        let microphoneCount = capacity * microphoneChannels
        let microphone = UnsafeMutablePointer<Float>.allocate(capacity: microphoneCount)
        microphone.initialize(repeating: 0, count: microphoneCount)
        microphoneBuffer = microphone
    }

    deinit {
        systemBuffer.deinitialize(count: capacity)
        systemBuffer.deallocate()
        microphoneBuffer.deinitialize(count: capacity * microphoneChannels)
        microphoneBuffer.deallocate()
    }

    /// Copies one IOProc cycle in. Only raw-memory copies: no allocation,
    /// lock, log or `await`. `system` and `microphone` must each hold at
    /// least `frames` frames (the microphone at `streamMicrophoneChannels`
    /// per frame); the caller (the IOProc) already knows this from the
    /// cycle's own buffers.
    ///
    /// A new base — the point where `firstFrame` starts applying to ring
    /// position `writePosition` — is set only while the ring is empty
    /// (`readIndex == written`): changing it while the reader might still be
    /// mid-copy of the old base would let one snapshot claim a `firstFrame`
    /// that doesn't match part of its own samples. So a cycle that doesn't
    /// continue the previous one (after a drop, or at the very first cycle)
    /// is itself dropped unless the ring is already empty; once it is, that
    /// cycle becomes the new base. A cycle larger than the whole ring can
    /// never fit either way, even into an empty ring.
    func write(system: UnsafePointer<Float>, microphone: UnsafePointer<Float>, frames: Int, firstFrame: Int64) {
        guard frames > 0 else { return }
        let w = writePosition
        let r = readIndex.load(ordering: .acquiring)
        let unread = Int(w - r)
        if needsBase || firstFrame != nextFrame {
            guard unread == 0, frames <= capacity else {
                _ = droppedTotal.wrappingAdd(Int64(frames), ordering: .releasing)
                needsBase = true
                return
            }
            baseFrame.store(firstFrame, ordering: .relaxed)
            basePosition.store(w, ordering: .relaxed)
            needsBase = false
        } else if unread + frames > capacity {
            _ = droppedTotal.wrappingAdd(Int64(frames), ordering: .releasing)
            needsBase = true
            return
        }
        copyIn(systemBuffer, position: w, count: frames, channels: 1, from: system)
        if streamMicrophoneChannels == microphoneChannels {
            copyIn(microphoneBuffer, position: w, count: frames, channels: microphoneChannels, from: microphone)
        } else {
            // Three or more microphone channels: keep channel 0 only, the
            // same channel `createFirstChannelFile`'s converter keeps.
            for i in 0..<frames {
                let index = Int((w + Int64(i)) % Int64(capacity))
                microphoneBuffer[index] = microphone[i * streamMicrophoneChannels]
            }
        }
        writePosition = w + Int64(frames)
        nextFrame = firstFrame + Int64(frames)
        written.store(writePosition, ordering: .releasing)
    }

    /// Everything unread, as one snapshot, or nil when the writer has put
    /// nothing new in since the last `read()`. The only reader, serialized by
    /// the capture actor.
    func read() -> LiveAudio? {
        let w = written.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .relaxed) // only this reader ever moves it
        guard w > r else { return nil }
        let base = baseFrame.load(ordering: .relaxed)
        let basePos = basePosition.load(ordering: .relaxed)
        let first = base + (r - basePos)
        let count = Int(w - r)
        var systemSamples = [Float](repeating: 0, count: count)
        var microphoneSamples = [Float](repeating: 0, count: count * microphoneChannels)
        systemSamples.withUnsafeMutableBufferPointer { destination in
            copyOut(destination.baseAddress!, from: systemBuffer, position: r, count: count, channels: 1)
        }
        microphoneSamples.withUnsafeMutableBufferPointer { destination in
            copyOut(destination.baseAddress!, from: microphoneBuffer, position: r, count: count, channels: microphoneChannels)
        }
        let totalDropped = droppedTotal.load(ordering: .acquiring)
        let dropped = totalDropped - reportedDropped
        reportedDropped = totalDropped
        readIndex.store(w, ordering: .releasing)
        return LiveAudio(
            sampleRate: sampleRate,
            microphoneChannels: microphoneChannels,
            firstFrame: first,
            system: systemSamples,
            microphone: microphoneSamples,
            dropped: dropped
        )
    }

    /// Copies `count` frames of `channels` samples each from `source` into
    /// `dest`, a ring of this capacity, starting at ring position `position`
    /// (wrapped), splitting the copy in two only where the ring wraps.
    private func copyIn(
        _ dest: UnsafeMutablePointer<Float>,
        position: Int64,
        count: Int,
        channels: Int,
        from source: UnsafePointer<Float>
    ) {
        let start = Int(position % Int64(capacity)) * channels
        let total = count * channels
        let firstPart = min(total, capacity * channels - start)
        dest.advanced(by: start).update(from: source, count: firstPart)
        if firstPart < total {
            dest.update(from: source.advanced(by: firstPart), count: total - firstPart)
        }
    }

    /// The mirror of `copyIn`: copies `count` frames of `channels` samples
    /// each out of ring `source` starting at ring position `position`
    /// (wrapped) into `dest`.
    private func copyOut(
        _ dest: UnsafeMutablePointer<Float>,
        from source: UnsafePointer<Float>,
        position: Int64,
        count: Int,
        channels: Int
    ) {
        let start = Int(position % Int64(capacity)) * channels
        let total = count * channels
        let firstPart = min(total, capacity * channels - start)
        dest.update(from: source.advanced(by: start), count: firstPart)
        if firstPart < total {
            dest.advanced(by: firstPart).update(from: source, count: total - firstPart)
        }
    }
}

private final class SystemAudioRuntime: @unchecked Sendable {
    private let errorLock = NSLock()
    private var firstErrorStatus: OSStatus?

    // Access to these fields is fenced by AudioDeviceStop/DestroyIOProcID.
    // The IOProc is their only writer while capture is running.
    var systemFile: ExtAudioFileRef?
    var microphoneFile: ExtAudioFileRef?
    var frames: Int64 = 0
    /// A copy of `frames`, for a reader off the realtime thread (the call
    /// feed watcher's clock): the IOProc stores it with no lock right after
    /// a cycle's frames are accepted, so a cycle left out of the tracks (the
    /// equal-frames check, or a write error) never moves it ahead of them.
    let writtenFrames = Atomic<Int64>(0)
    /// Cycles left out of both tracks, by why (see the IOProc).
    var cyclesWithoutAStream: Int64 = 0
    var cyclesOutOfStep: Int64 = 0
    /// While cycles are being skipped, the frames written before the first of
    /// them; nil once a whole cycle came again.
    var skippingSinceFrame: Int64?
    /// Exact digital silence from the microphone, every byte of its buffer 0,
    /// which a live one never sends: its noise floor is never all zeros.
    /// Frames of it so far; where the current run of it began; and the span
    /// from the first to the last run of at least `silenceLimit` frames, with
    /// the silent frames counted at either end of it.
    var silentFrames: Int64 = 0
    var silentSinceFrame: Int64?
    var longSilence: (start: Int64, silentBefore: Int64, end: Int64, silentByEnd: Int64)?
    let silenceLimit: Int64
    let systemBufferIndex: Int
    let microphoneBufferIndex: Int
    let systemBytesPerFrame: UInt32
    let microphoneBytesPerFrame: UInt32
    /// The live-audio ring, or nil when the format didn't allow one (see
    /// `SystemAudioTapRecorder.liveRing`). Set once, before the first cycle;
    /// the IOProc only reads it, through `write`, which fences its own
    /// writer-side state.
    let live: LiveAudioRing?
    #if DEBUG
    /// Test-only: an adopted session writes synchronously (see
    /// `adoptedForTesting`). Written once, before the first cycle; the IOProc
    /// only reads it.
    var writesSynchronouslyForTesting = false
    /// Test-only: makes the next synchronous write cycle fail without
    /// touching either file (`deliverCycleForTesting(failingWrite:)`). The
    /// IOProc clears it right after using it, so it applies to one cycle.
    var failsWritesForTesting = false
    #endif

    init(
        systemFile: ExtAudioFileRef,
        microphoneFile: ExtAudioFileRef,
        systemBufferIndex: Int,
        microphoneBufferIndex: Int,
        systemBytesPerFrame: UInt32,
        microphoneBytesPerFrame: UInt32,
        sampleRate: Double,
        live: LiveAudioRing?
    ) {
        self.systemFile = systemFile
        self.microphoneFile = microphoneFile
        self.systemBufferIndex = systemBufferIndex
        self.microphoneBufferIndex = microphoneBufferIndex
        self.systemBytesPerFrame = systemBytesPerFrame
        self.microphoneBytesPerFrame = microphoneBytesPerFrame
        self.live = live
        // A headset's microphone starts with up to ~1.5 s of zeros; a live
        // one never sends 10 s of them.
        self.silenceLimit = Int64(sampleRate * 10)
    }

    /// Ends the current run of silence at `frame`. A long one widens the
    /// span; short ones only count inside it, so a moment of sound between
    /// long runs doesn't split the span or hide the silence around it.
    func endSilence(at frame: Int64) {
        guard let start = silentSinceFrame else { return }
        silentSinceFrame = nil
        guard frame - start >= silenceLimit else { return }
        longSilence = (
            start: longSilence?.start ?? start,
            silentBefore: longSilence?.silentBefore ?? silentFrames - (frame - start),
            end: frame,
            silentByEnd: silentFrames
        )
    }

    func record(_ status: OSStatus) {
        guard status != noErr else { return }
        errorLock.lock()
        if firstErrorStatus == nil { firstErrorStatus = status }
        errorLock.unlock()
    }

    func errorStatus() -> OSStatus? {
        errorLock.lock()
        defer { errorLock.unlock() }
        return firstErrorStatus
    }
}

private func murmurlySystemAudioIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let context else { return kAudioHardwareUnspecifiedError }
    let runtime = Unmanaged<SystemAudioRuntime>.fromOpaque(context).takeUnretainedValue()
    guard let systemFile = runtime.systemFile,
          let microphoneFile = runtime.microphoneFile else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(
        UnsafeMutablePointer(mutating: inputData)
    )
    let system = stream(in: buffers, at: runtime.systemBufferIndex, bytesPerFrame: runtime.systemBytesPerFrame)
    let microphone = stream(
        in: buffers, at: runtime.microphoneBufferIndex, bytesPerFrame: runtime.microphoneBytesPerFrame
    )
    let systemFrames = system?.frames ?? 0
    let microphoneFrames = microphone?.frames ?? 0
    guard systemFrames > 0 || microphoneFrames > 0 else { return noErr }
    // Both files have the clock's rate (`trackFormats`), which holds only
    // while the tap arrives resampled to it: as many frames as the microphone.
    // A cycle with a stream gone, empty or out of step is not a write error.
    // An AirPods headset dropping out mid-call removes its input device: the
    // aggregate goes on for a moment on the tap's clock, without the
    // microphone stream, until the headset is back. Such a cycle is left out
    // of both tracks, so they stay aligned, and counted for `stop()`.
    guard let system, let microphone, systemFrames == microphoneFrames else {
        if runtime.skippingSinceFrame == nil { runtime.skippingSinceFrame = runtime.frames }
        if system == nil || microphone == nil {
            runtime.cyclesWithoutAStream += 1
        } else {
            runtime.cyclesOutOfStep += 1
        }
        return noErr
    }
    runtime.skippingSinceFrame = nil
    let microphoneIsSilent = isSilent(microphone.buffer)

    var systemData = AudioBufferList(mNumberBuffers: 1, mBuffers: system.buffer)
    var microphoneData = AudioBufferList(mNumberBuffers: 1, mBuffers: microphone.buffer)
    let systemStatus: OSStatus
    let microphoneStatus: OSStatus
    #if DEBUG
    // A test hands cycles over far faster than a device's clock, so the
    // asynchronous writer's buffer can overflow (-66570) for a pace no real
    // session is driven at. The adopted test session writes synchronously
    // instead: there is no ring to overflow, and both writers' progress is
    // guaranteed by the call itself.
    if runtime.writesSynchronouslyForTesting {
        if runtime.failsWritesForTesting {
            systemStatus = kAudioFileUnspecifiedError
            microphoneStatus = noErr
            runtime.failsWritesForTesting = false
        } else {
            systemStatus = ExtAudioFileWrite(systemFile, systemFrames, &systemData)
            microphoneStatus = ExtAudioFileWrite(microphoneFile, systemFrames, &microphoneData)
        }
    } else {
        systemStatus = ExtAudioFileWriteAsync(systemFile, systemFrames, &systemData)
        microphoneStatus = ExtAudioFileWriteAsync(microphoneFile, systemFrames, &microphoneData)
    }
    #else
    systemStatus = ExtAudioFileWriteAsync(systemFile, systemFrames, &systemData)
    microphoneStatus = ExtAudioFileWriteAsync(microphoneFile, systemFrames, &microphoneData)
    #endif
    let status = systemStatus == noErr ? microphoneStatus : systemStatus
    if status != noErr {
        // The error path may lock; the successful realtime path does not.
        runtime.record(status)
    } else {
        // A headset that gave its voice channel to another device stays the
        // input, and Core Audio goes on delivering its buffers, all zeros.
        if microphoneIsSilent {
            if runtime.silentSinceFrame == nil { runtime.silentSinceFrame = runtime.frames }
            runtime.silentFrames += Int64(systemFrames)
        } else {
            runtime.endSilence(at: runtime.frames)
        }
        let firstFrame = runtime.frames
        runtime.frames += Int64(systemFrames)
        runtime.writtenFrames.store(runtime.frames, ordering: .relaxed)
        if let live = runtime.live,
           let systemData = system.buffer.mData,
           let microphoneData = microphone.buffer.mData {
            live.write(
                system: systemData.assumingMemoryBound(to: Float.self),
                microphone: microphoneData.assumingMemoryBound(to: Float.self),
                frames: Int(systemFrames),
                firstFrame: firstFrame
            )
        }
    }
    return status
}

/// Whether every byte of a buffer with data is 0. Live sound leaves this on
/// the first samples.
private func isSilent(_ buffer: AudioBuffer) -> Bool {
    guard let data = buffer.mData else { return false }
    return UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize)).allSatisfy { $0 == 0 }
}

/// One stream's buffer in an IOProc cycle and its frames (none without data),
/// or nil when the cycle has no such stream.
private func stream(
    in buffers: UnsafeMutableAudioBufferListPointer,
    at index: Int,
    bytesPerFrame: UInt32
) -> (buffer: AudioBuffer, frames: UInt32)? {
    guard index < buffers.count else { return nil }
    let buffer = buffers[index]
    let frames = buffer.mData != nil && bytesPerFrame > 0 ? buffer.mDataByteSize / bytesPerFrame : 0
    return (buffer, frames)
}

/// One private aggregate: the microphone is its clock source and the global
/// tap uses drift compensation. One IOProc writes both streams to separate CAFs.
final class SystemAudioTapRecorder: @unchecked Sendable {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var runtime: SystemAudioRuntime?
    private(set) var sampleRate: Double = 0

    func start(systemURL: URL, microphoneURL: URL) async throws {
        guard runtime == nil else { throw SystemAudioCaptureError.alreadyRunning }

        do {
            let hardware = AudioHardwareSystem.shared
            let (microphone, nativeMicrophoneFormat, firstChannelOnly) = try await Self.readyMicrophone(hardware)
            let microphoneUID = try microphone.uid

            let tapDescription = CATapDescription(monoGlobalTapButExcludeProcesses: [])
            tapDescription.name = "Murmurly meeting system audio"
            tapDescription.isPrivate = true
            tapDescription.muteBehavior = .unmuted

            guard let tap = try hardware.makeProcessTap(description: tapDescription) else {
                throw SystemAudioCaptureError.coreAudio(
                    operation: String(localized: "Couldn’t create the system audio capture"),
                    status: kAudioHardwareUnspecifiedError
                )
            }
            tapID = tap.id
            let tapUID = try tap.uid
            let tapFormat = try tap.format
            guard tapFormat.mChannelsPerFrame == 1 else {
                throw SystemAudioCaptureError.coreAudio(
                    operation: String(localized: "Core Audio returned an unsupported tap format"),
                    status: kAudioHardwareUnsupportedOperationError
                )
            }

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Murmurly Meeting Tap",
                kAudioAggregateDeviceUIDKey: "\(Bundle.main.bundleIdentifier ?? "Murmurly").meeting.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: microphoneUID],
                ],
                kAudioAggregateDeviceMainSubDeviceKey: microphoneUID,
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: tapUID,
                        kAudioSubTapDriftCompensationKey: true,
                    ],
                ],
            ]
            guard let aggregate = try hardware.makeAggregateDevice(
                description: aggregateDescription
            ) else {
                throw SystemAudioCaptureError.coreAudio(
                    operation: String(localized: "Couldn’t create the combined audio device"),
                    status: kAudioHardwareUnspecifiedError
                )
            }
            aggregateID = aggregate.id
            let aggregateStreams = try await Self.waitForInputStreams(
                on: aggregate,
                count: 2
            )
            let startingChannels = try aggregateStreams.map {
                try $0.startingChannel
            }
            let systemStartingChannel = Int(nativeMicrophoneFormat.mChannelsPerFrame) + 1
            guard let microphoneIndex = startingChannels.firstIndex(of: 1),
                  let systemIndex = startingChannels.firstIndex(of: systemStartingChannel) else {
                throw SystemAudioCaptureError.coreAudio(
                    operation: String(localized: "Couldn’t find the microphone and tap streams"),
                    status: kAudioHardwareUnsupportedOperationError
                )
            }
            let microphoneStream = try aggregateStreams[microphoneIndex].virtualFormat
            let systemStream = try aggregateStreams[systemIndex].virtualFormat
            let clockRate = try aggregate.nominalSampleRate
            let microphoneFormat: AudioStreamBasicDescription
            let systemFormat: AudioStreamBasicDescription
            switch SystemAudioCapture.trackFormats(
                clockRate: clockRate,
                microphone: microphoneStream,
                system: systemStream,
                microphoneChannels: nativeMicrophoneFormat.mChannelsPerFrame
            ) {
            case let .record(microphone, system):
                microphoneFormat = microphone
                systemFormat = system
            case let .refuse(reason):
                throw SystemAudioCaptureError.coreAudio(
                    operation: reason,
                    status: kAudioHardwareUnsupportedOperationError
                )
            }
            sampleRate = clockRate

            let systemFile = try Self.createFile(
                at: systemURL,
                format: systemFormat,
                operation: String(localized: "Couldn’t create the system audio file")
            )
            let microphoneFile: ExtAudioFileRef
            do {
                let operation = String(localized: "Couldn’t create the microphone file")
                microphoneFile = firstChannelOnly
                    ? try Self.createFirstChannelFile(at: microphoneURL, streamFormat: microphoneFormat, operation: operation)
                    : try Self.createFile(at: microphoneURL, format: microphoneFormat, operation: operation)
            } catch {
                ExtAudioFileDispose(systemFile)
                throw error
            }

            let liveAudioOffReason = Self.liveAudioUnsupportedReason(microphone: microphoneFormat, system: systemFormat)
            let live = liveAudioOffReason == nil
                ? Self.liveRing(microphone: microphoneFormat, system: systemFormat, firstChannelOnly: firstChannelOnly)
                : nil
            let runtime = SystemAudioRuntime(
                systemFile: systemFile,
                microphoneFile: microphoneFile,
                systemBufferIndex: systemIndex,
                microphoneBufferIndex: microphoneIndex,
                systemBytesPerFrame: systemFormat.mBytesPerFrame,
                microphoneBytesPerFrame: microphoneFormat.mBytesPerFrame,
                sampleRate: clockRate,
                live: live
            )
            self.runtime = runtime
            var proc: AudioDeviceIOProcID?
            try Self.check(
                AudioDeviceCreateIOProcID(
                    aggregateID,
                    murmurlySystemAudioIOProc,
                    Unmanaged.passUnretained(runtime).toOpaque(),
                    &proc
                ),
                String(localized: "Couldn’t prepare the system audio recording")
            )
            ioProcID = proc
            try Self.check(
                AudioDeviceStart(aggregateID, ioProcID),
                String(localized: "The combined audio device didn’t start — check the permissions")
            )
            AppLog.info(
                "meeting",
                "shared clock @ \(Int(sampleRate)) Hz; mic \(microphoneFormat.mChannelsPerFrame)ch"
                    + (firstChannelOnly ? ", first channel written" : "")
                    + (systemStream.mSampleRate != sampleRate ? "; tap declares \(Int(systemStream.mSampleRate)) Hz" : "")
                    + (liveAudioOffReason.map { "; live audio off: \($0)" } ?? "")
            )
        } catch {
            teardown()
            try? FileManager.default.removeItem(at: systemURL)
            try? FileManager.default.removeItem(at: microphoneURL)
            throw error
        }
    }

    /// What stopping proved. `enqueuedFrames` counts what the IOProc handed to
    /// the asynchronous write queue, not what reached the files;
    /// `skippedCycles`, the cycles it left out of both tracks;
    /// `skippingSinceFrame`, where the skipping that lasted to the stop began;
    /// `silence`, the span of the microphone's long runs of exact zeros and
    /// the silent frames in it.
    /// `microphoneChannels`: what the device delivered and what the file
    /// holds, read from the file itself; nil when it could not be read.
    struct StopReport {
        let enqueuedFrames: Int64
        let skippedCycles: Int64
        let skippingSinceFrame: Int64?
        let silence: (start: Int64, end: Int64, frames: Int64)?
        let issues: [String]
        let microphoneChannels: (input: Int, written: Int)?
    }

    /// Closes both tracks even if one fails and reports every problem, so the
    /// first error never hides the second and the queue count is not lost.
    /// Throws only when no session was running.
    func stop() throws -> StopReport {
        guard let runtime else { throw SystemAudioCaptureError.notRunning }
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            _ = AudioDeviceStop(aggregateID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        let frames = runtime.frames
        runtime.endSilence(at: frames)
        var issues: [String] = []
        if let writeError = runtime.errorStatus() {
            issues.append(SystemAudioCaptureError.coreAudio(
                operation: String(localized: "Writing the meeting tracks"),
                status: writeError
            ).localizedDescription)
        }
        if let file = runtime.systemFile {
            let status = ExtAudioFileDispose(file)
            if status != noErr {
                issues.append(SystemAudioCaptureError.coreAudio(
                    operation: String(localized: "Closing system.caf"),
                    status: status
                ).localizedDescription)
            }
            runtime.systemFile = nil
        }
        var microphoneChannels: (input: Int, written: Int)?
        if let file = runtime.microphoneFile {
            microphoneChannels = Self.channels(of: file)
            let status = ExtAudioFileDispose(file)
            if status != noErr {
                issues.append(SystemAudioCaptureError.coreAudio(
                    operation: String(localized: "Closing microphone.caf"),
                    status: status
                ).localizedDescription)
            }
            runtime.microphoneFile = nil
        }
        self.runtime = nil
        destroyAudioObjects()
        let skipped = runtime.cyclesWithoutAStream + runtime.cyclesOutOfStep
        AppLog.info(
            "meeting",
            "shared capture stopped; \(frames) frames queued per track"
                + (skipped > 0
                    ? "; cycles skipped: \(runtime.cyclesWithoutAStream) without a stream, "
                        + "\(runtime.cyclesOutOfStep) out of step"
                    : "")
                + (runtime.silentFrames > 0 ? "; microphone frames of exact silence: \(runtime.silentFrames)" : "")
        )
        return StopReport(
            enqueuedFrames: frames,
            skippedCycles: skipped,
            skippingSinceFrame: runtime.skippingSinceFrame,
            silence: runtime.longSilence.map { ($0.start, $0.end, $0.silentByEnd - $0.silentBefore) },
            issues: issues,
            microphoneChannels: microphoneChannels
        )
    }

    /// Channels the file's client gives it (what the device delivered) and
    /// channels it stores. They differ only for a first-channel file; a file
    /// with no client format of its own (0 channels read) takes the device's
    /// frames as they are.
    private static func channels(of file: ExtAudioFileRef) -> (input: Int, written: Int)? {
        var client = AudioStreamBasicDescription()
        var stored = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_ClientDataFormat, &size, &client) == noErr else {
            return nil
        }
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &stored) == noErr else {
            return nil
        }
        let written = Int(stored.mChannelsPerFrame)
        return (client.mChannelsPerFrame > 0 ? Int(client.mChannelsPerFrame) : written, written)
    }

    /// Seconds of audio already written to the tracks: the atomic copy of
    /// the IOProc's frame count, divided by the tracks' own rate — never the
    /// wall clock, which a dropped headset would run ahead of the files.
    func writtenSeconds() -> TimeInterval? {
        guard let runtime, sampleRate > 0 else { return nil }
        return Double(runtime.writtenFrames.load(ordering: .relaxed)) / sampleRate
    }

    /// A snapshot of the live audio ring, or nil when nothing new is there,
    /// there is no session, or this format never got a ring.
    func liveAudio() -> LiveAudio? {
        runtime?.live?.read()
    }

    deinit { teardown() }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            _ = AudioDeviceStop(aggregateID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if let file = runtime?.systemFile {
            ExtAudioFileDispose(file)
            runtime?.systemFile = nil
        }
        if let file = runtime?.microphoneFile {
            ExtAudioFileDispose(file)
            runtime?.microphoneFile = nil
        }
        runtime = nil
        destroyAudioObjects()
    }

    private func destroyAudioObjects() {
        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw SystemAudioCaptureError.coreAudio(operation: operation, status: status)
        }
    }

    private static func inputStreams(
        on device: AudioHardwareDevice
    ) throws -> [AudioHardwareStream] {
        try device.streams.filter { try $0.direction == .input }
    }

    /// The default microphone, its stream format and whether only its first
    /// channel is written. A device being connected or reconfigured — another
    /// app taking it — shows no stream or no channel for a moment, so it is
    /// read again for up to two seconds before the start gives up.
    private static func readyMicrophone(
        _ hardware: AudioHardwareSystem
    ) async throws -> (device: AudioHardwareDevice, format: AudioStreamBasicDescription, firstChannelOnly: Bool) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while true {
            guard let microphone = try hardware.defaultInputDevice else {
                throw SystemAudioCaptureError.noInputDevice
            }
            let formats = try inputStreams(on: microphone).map { try $0.virtualFormat }
            switch SystemAudioCapture.microphonePlan(streamChannels: formats.map(\.mChannelsPerFrame)) {
            case .record:
                return (microphone, formats[0], false)
            case .firstChannel:
                return (microphone, formats[0], true)
            case let .refuse(reason):
                throw SystemAudioCaptureError.coreAudio(
                    operation: reason,
                    status: kAudioHardwareUnsupportedOperationError
                )
            case .wait:
                guard clock.now < deadline else { throw SystemAudioCaptureError.microphoneNotReady }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// A file holding the first of the stream's channels. The IOProc still
    /// hands it every channel; the file's converter keeps channel 0 on the
    /// asynchronous writer's own thread, off the realtime one.
    static func createFirstChannelFile(
        at url: URL,
        streamFormat: AudioStreamBasicDescription,
        operation: String
    ) throws -> ExtAudioFileRef {
        // Core Audio streams are interleaved: one frame holds every channel.
        let channels = streamFormat.mChannelsPerFrame
        guard channels > 0, streamFormat.mBytesPerFrame % channels == 0 else {
            throw SystemAudioCaptureError.coreAudio(operation: operation, status: kAudioHardwareUnsupportedOperationError)
        }
        var mono = streamFormat
        mono.mChannelsPerFrame = 1
        mono.mBytesPerFrame = streamFormat.mBytesPerFrame / channels
        mono.mBytesPerPacket = mono.mBytesPerFrame * streamFormat.mFramesPerPacket
        let file = try createFile(at: url, format: mono, operation: operation)
        do {
            var client = streamFormat
            try check(
                ExtAudioFileSetProperty(
                    file, kExtAudioFileProperty_ClientDataFormat,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client
                ),
                operation
            )
            var converter: AudioConverterRef?
            var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
            try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter), operation)
            guard let converter else {
                throw SystemAudioCaptureError.coreAudio(operation: operation, status: kAudioHardwareUnspecifiedError)
            }
            var channelMap: [Int32] = [0]
            try check(
                AudioConverterSetProperty(
                    converter, kAudioConverterChannelMap,
                    UInt32(MemoryLayout<Int32>.size * channelMap.count), &channelMap
                ),
                operation
            )
            // The documented way to make the file follow a changed converter:
            // a NULL configuration.
            var config: Unmanaged<CFArray>?
            try check(
                ExtAudioFileSetProperty(
                    file, kExtAudioFileProperty_ConverterConfig,
                    UInt32(MemoryLayout<Unmanaged<CFArray>?>.size), &config
                ),
                operation
            )
        } catch {
            ExtAudioFileDispose(file)
            throw error
        }
        return file
    }

    private static func createFile(
        at url: URL,
        format: AudioStreamBasicDescription,
        operation: String
    ) throws -> ExtAudioFileRef {
        var file: ExtAudioFileRef?
        var fileFormat = format
        try check(
            ExtAudioFileCreateWithURL(
                url as CFURL,
                kAudioFileCAFType,
                &fileFormat,
                nil,
                AudioFileFlags.eraseFile.rawValue,
                &file
            ),
            operation
        )
        guard let file else {
            throw SystemAudioCaptureError.coreAudio(
                operation: operation,
                status: kAudioHardwareUnspecifiedError
            )
        }
        return file
    }

    /// Why a live-audio ring can't be built from these formats, or nil when
    /// it can. The ring reads raw `Float` samples straight out of the IOProc's
    /// buffers, so it needs Float32, packed, interleaved PCM and a known rate
    /// — anything else would read as garbage.
    private static func liveAudioUnsupportedReason(
        microphone: AudioStreamBasicDescription,
        system: AudioStreamBasicDescription
    ) -> String? {
        guard system.mSampleRate > 0 else { return "no clock rate" }
        guard isFloatPackedInterleaved(system) else { return "system stream not Float32 packed interleaved" }
        guard isFloatPackedInterleaved(microphone) else { return "microphone stream not Float32 packed interleaved" }
        return nil
    }

    /// One channel makes interleaved and non-interleaved the same bytes, so
    /// the non-interleaved flag only disqualifies a format with two or more
    /// channels (several buffers per stream — the ring reads one).
    private static func isFloatPackedInterleaved(_ format: AudioStreamBasicDescription) -> Bool {
        guard format.mFormatID == kAudioFormatLinearPCM,
              (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0,
              format.mBitsPerChannel == 32,
              format.mChannelsPerFrame > 0,
              format.mBytesPerFrame == 4 * format.mChannelsPerFrame else {
            return false
        }
        return format.mChannelsPerFrame == 1 || (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
    }

    /// A ~30 s ring at the given formats' rate, or nil when
    /// `liveAudioUnsupportedReason` already refused them. `capacityFrames`
    /// overrides the ~30 s default; test-only (a real session never passes
    /// it).
    private static func liveRing(
        microphone: AudioStreamBasicDescription,
        system: AudioStreamBasicDescription,
        firstChannelOnly: Bool,
        capacityFrames: Int? = nil
    ) -> LiveAudioRing? {
        guard liveAudioUnsupportedReason(microphone: microphone, system: system) == nil else { return nil }
        let streamChannels = Int(microphone.mChannelsPerFrame)
        let channels = firstChannelOnly ? 1 : streamChannels
        let capacity = capacityFrames ?? Int((system.mSampleRate * 30).rounded(.up))
        return LiveAudioRing(
            sampleRate: system.mSampleRate,
            capacity: capacity,
            streamMicrophoneChannels: streamChannels,
            microphoneChannels: channels
        )
    }

    private static func waitForInputStreams(
        on aggregate: AudioHardwareAggregateDevice,
        count: Int
    ) async throws -> [AudioHardwareStream] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if let streams = try? inputStreams(on: aggregate), streams.count == count {
                return streams
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw SystemAudioCaptureError.coreAudio(
            operation: String(localized: "The microphone and the tap didn’t appear among the Core Audio inputs"),
            status: kAudioHardwareNotRunningError
        )
    }
}

/// Production meeting backend: captures the global system mix and the user's
/// microphone into separate CAF files in one durable session directory.
actor SystemAudioCapture: MeetingCaptureBackend {
    /// What to do with the default microphone, by its input streams.
    enum MicrophonePlan: Equatable, Sendable {
        /// Mono or stereo: the track is written as it comes.
        case record
        /// Three or more channels: only the first is written.
        case firstChannel
        /// No stream or no channel yet: read the device again shortly.
        case wait
        /// Never usable as it is; the reason.
        case refuse(String)
    }

    /// The plan for a microphone whose input streams carry these channel
    /// counts. Kept free of Core Audio, so the decision can be tested. No
    /// stream or no channel is a device being connected or reconfigured.
    /// Three or more come from voice processing (1→3, 2→7 channels, as when a
    /// browser call takes the microphone), multichannel interfaces and
    /// virtual devices. Only the first is written: mixing would add whatever
    /// else the device carries, and a track of sixteen would only fill the
    /// disk. Whether the voice is in the first is not known, so the recording
    /// says it kept one channel of N (see `stop()`).
    nonisolated static func microphonePlan(streamChannels: [UInt32]) -> MicrophonePlan {
        guard let channels = streamChannels.first else { return .wait }
        guard streamChannels.count == 1 else {
            return .refuse(String(localized: "The microphone must have one input stream"))
        }
        switch channels {
        case 0: return .wait
        case 1, 2: return .record
        default: return .firstChannel
        }
    }

    /// The formats of the two files the IOProc writes.
    enum TrackFormats: Sendable {
        /// The microphone stream's format and the system file's.
        case record(microphone: AudioStreamBasicDescription, system: AudioStreamBasicDescription)
        /// Never written as it is; the reason.
        case refuse(String)
    }

    /// The files' formats, by the aggregate's clock rate, its two input
    /// streams and the channels the microphone itself reports. Kept free of
    /// Core Audio, so the decision can be tested.
    ///
    /// Both files take the clock's rate. The microphone is the clock, and the
    /// tap is resampled to it by drift compensation, yet the tap's stream keeps
    /// declaring the tap's own rate: AirPods in headset mode run at 24 kHz,
    /// and on hardware the aggregate delivered 24 kHz, 480 frames a cycle on
    /// both streams, while the tap's stream said 48 kHz. A file made at the
    /// declared rate would play twice as fast. The IOProc's equal-frames check
    /// guards this while recording.
    nonisolated static func trackFormats(
        clockRate: Double,
        microphone: AudioStreamBasicDescription,
        system: AudioStreamBasicDescription,
        microphoneChannels: UInt32
    ) -> TrackFormats {
        guard microphone.mChannelsPerFrame == microphoneChannels,
              system.mChannelsPerFrame == 1,
              microphone.mBytesPerFrame > 0,
              system.mBytesPerFrame > 0,
              clockRate > 0,
              microphone.mSampleRate == clockRate else {
            return .refuse(String(localized: "Core Audio couldn’t match the formats of the combined device"))
        }
        var system = system
        system.mSampleRate = clockRate
        return .record(microphone: microphone, system: system)
    }

    private var tapRecorder: SystemAudioTapRecorder?
    private var sessionDirectory: URL?
    private var systemURL: URL?
    private var startedAt: Date?
    private var activity: NSObjectProtocol?
    #if DEBUG
    /// Test-only: where an adopted session's clock stops, whatever the pace
    /// its cycles came at.
    private var endedAtForTesting: Date?
    #endif

    /// Creates and destroys one process tap. That proves only that a tap can be
    /// made: macOS asks for the recording permission when an aggregate device
    /// with the tap first starts recording, so this says nothing about it.
    nonisolated static func canCreateProcessTap() -> Bool {
        do {
            let description = CATapDescription(monoGlobalTapButExcludeProcesses: [])
            description.name = "Murmurly system audio source check"
            description.isPrivate = true
            guard let tap = try AudioHardwareSystem.shared.makeProcessTap(
                description: description
            ) else { return false }
            defer { AudioHardwareDestroyProcessTap(tap.id) }
            return true
        } catch {
            AppLog.error("permissions", "system audio source check failed: \(error)")
            return false
        }
    }

    /// The folder is the recorder's, made for this session; whatever stops
    /// the start, a refusal before the tap included, removes it, so no empty
    /// or half-made folder passes for a recording.
    func start(in directory: URL) async throws -> Date {
        do {
            guard tapRecorder == nil else { throw SystemAudioCaptureError.alreadyRunning }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                throw SystemAudioCaptureError.microphoneUnavailable
            }
            try Task.checkCancellation()

            let systemURL = directory.appendingPathComponent("system.caf")
            let microphoneURL = directory.appendingPathComponent("microphone.caf")
            let recorder = SystemAudioTapRecorder()
            do {
                try await recorder.start(systemURL: systemURL, microphoneURL: microphoneURL)
                try Task.checkCancellation()
            } catch {
                _ = try? recorder.stop()
                throw error
            }

            sessionDirectory = directory
            self.systemURL = systemURL
            let captureStartedAt = Date()
            startedAt = captureStartedAt
            tapRecorder = recorder
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "Recording a meeting"
            )
            AppLog.info("meeting", "capture started: \(directory.path)")
            return captureStartedAt
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// `tapRecorder` is set only at the end of a successful `start` and
    /// cleared as the first line of `stop`, both inside this actor, so a
    /// call arriving while a stop is under way safely sees nil.
    func writtenSeconds() async -> TimeInterval? {
        tapRecorder?.writtenSeconds()
    }

    /// Same lifetime guarantee as `writtenSeconds()`: nil once `stop()` has
    /// cleared `tapRecorder`.
    func liveAudio() async -> LiveAudio? {
        tapRecorder?.liveAudio()
    }

    func stop() async throws -> [URL] {
        guard let recorder = tapRecorder,
              let directory = sessionDirectory,
              let systemURL else {
            throw SystemAudioCaptureError.notRunning
        }
        tapRecorder = nil
        sessionDirectory = nil
        self.systemURL = nil
        let captureStartedAt = startedAt ?? Date()
        startedAt = nil
        defer {
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        }

        #if DEBUG
        let captureEndedAt = endedAtForTesting ?? Date()
        endedAtForTesting = nil
        #else
        let captureEndedAt = Date()
        #endif
        var issues: [String] = []
        var enqueuedFrames: Int64?
        var skippedCycles: Int64 = 0
        var skippingSinceFrame: Int64?
        var silence: (start: Int64, end: Int64, frames: Int64)?
        var microphoneChannels: (input: Int, written: Int)?
        do {
            let report = try recorder.stop()
            enqueuedFrames = report.enqueuedFrames
            skippedCycles = report.skippedCycles
            skippingSinceFrame = report.skippingSinceFrame
            silence = report.silence
            issues += report.issues
            microphoneChannels = report.microphoneChannels
        } catch {
            issues.append(error.localizedDescription)
        }

        // The queue count is not proof of what reached the disk: measure both
        // closed tracks. Unreadable or a write/close error → failed; any
        // measured shortfall or mismatch → suspect, with the reason recorded.
        let microphoneURL = directory.appendingPathComponent("microphone.caf")
        let systemFrames = Self.measuredFrames(at: systemURL)
        let microphoneFrames = Self.measuredFrames(at: microphoneURL)
        if systemFrames == nil { issues.append(String(localized: "system.caf can’t be read")) }
        if microphoneFrames == nil { issues.append(String(localized: "microphone.caf can’t be read")) }
        let failed = !issues.isEmpty
        if let enqueuedFrames {
            for (name, frames) in [("system.caf", systemFrames), ("microphone.caf", microphoneFrames)] {
                if let frames, frames != enqueuedFrames {
                    issues.append(String(localized: "\(name): \(frames) of \(enqueuedFrames) accepted frames written"))
                }
            }
        }
        if let systemFrames, let microphoneFrames, systemFrames != microphoneFrames {
            issues.append(String(
                localized: "tracks differ in length: system.caf \(systemFrames), microphone.caf \(microphoneFrames) frames"
            ))
        }
        // Only the first of three or more channels was written: whether the
        // voice was in it is not known, so the recording says so instead of
        // passing for a whole one.
        let firstChannelOnly = microphoneChannels.map { $0.written < $0.input } ?? false
        if firstChannelOnly, let microphoneChannels {
            issues.append(String(
                localized: "Only the first of \(microphoneChannels.input) microphone channels was recorded"
            ))
        }
        if let silence, recorder.sampleRate > 0 {
            // The tracks are whole, but the voice on this side is missing
            // from them: the microphone was muted, or the headset gave its
            // voice channel to another device. Said at the times the
            // transcript shows, as one span from the first long silence to
            // the last, with the length of the silence alone.
            let rate = recorder.sampleRate
            let time = { (frames: Int64) in TranscriptSegment.timecode(Double(frames) / rate) }
            issues.append(String(
                localized: "The microphone sent only silence for \(time(silence.frames)) between \(time(silence.start)) and \(time(silence.end)): it was muted or taken by another device"
            ))
        }
        let wallDuration = captureEndedAt.timeIntervalSince(captureStartedAt)
        if let systemFrames, recorder.sampleRate > 0 {
            let audioDuration = Double(systemFrames) / recorder.sampleRate
            if let skippingSinceFrame {
                // Skipped to the very stop: the stream never came back, and
                // what came before is all there is. Said at the time the
                // transcript shows.
                let end = TranscriptSegment.timecode(Double(skippingSinceFrame) / recorder.sampleRate)
                issues.append(String(
                    localized: "The microphone or the system audio dropped out at \(end) and did not come back: nothing after that was recorded"
                ))
            } else if skippedCycles > 0 {
                // A stream dropped out: both tracks are whole around the gap,
                // so the recording is kept and says how much is missing. The
                // clock tells it, not the skipped frames: while the headset is
                // gone the aggregate runs at the tap's rate, and for moments
                // Core Audio delivers no cycle at all.
                let missing = max(wallDuration - audioDuration, 0.1)
                    .formatted(.number.precision(.fractionLength(1)))
                issues.append(String(
                    localized: "About \(missing) s is missing from both tracks: the microphone or the system audio dropped out"
                ))
            }
            // Skipped cycles explain audio shorter than the clock, never
            // longer: tracks ahead of the clock mean a wrong rate.
            let excess = audioDuration - wallDuration
            if skippedCycles > 0 ? excess > 2 : abs(excess) > 2 {
                let audio = audioDuration.formatted(.number.precision(.fractionLength(1)))
                let wall = wallDuration.formatted(.number.precision(.fractionLength(1)))
                issues.append(String(localized: "audio lasts \(audio) s while the clock says \(wall) s"))
            }
        }
        let state = failed ? "failed" : (issues.isEmpty ? "done" : "suspect")

        let formatter = ISO8601DateFormatter()
        let metadata = MeetingMetadata(
            startedAt: formatter.string(from: captureStartedAt),
            endedAt: formatter.string(from: captureEndedAt),
            sampleRate: recorder.sampleRate,
            state: state,
            segments: [
                .init(
                    index: 0,
                    system: systemURL.lastPathComponent,
                    mic: microphoneURL.lastPathComponent,
                    frames: systemFrames,
                    micFrames: microphoneFrames,
                    enqueuedFrames: enqueuedFrames,
                    micInputChannels: microphoneChannels?.input,
                    micRecordedChannel: firstChannelOnly ? 1 : nil
                ),
            ],
            issues: issues.isEmpty ? nil : issues
        )
        var metadataError: Error?
        do {
            try await MainActor.run {
                try RecordingsStore().writeMetadata(metadata, to: directory)
            }
        } catch {
            metadataError = error
        }
        if failed || metadataError != nil {
            let message = ([metadataError?.localizedDescription].compactMap { $0 } + issues)
                .joined(separator: "; ")
            AppLog.error("meeting", "capture stopped with error; preserved at \(directory.path): \(message)")
            throw SystemAudioCaptureError.captureFailed(message: message, savedAt: directory)
        }
        if state == "suspect" {
            AppLog.error("meeting", "capture suspect: \(issues.joined(separator: "; "))")
        }
        AppLog.info("meeting", "capture saved: \(directory.path)")
        return [systemURL, microphoneURL]
    }

    /// Frames a closed track really holds, or nil when it cannot be read.
    private nonisolated static func measuredFrames(at url: URL) -> Int64? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return file.length
    }
}

#if DEBUG
extension SystemAudioTapRecorder {
    /// Test-only: a recorder in the state a running tap leaves behind, without
    /// Core Audio. Both CAFs come from the real `createFile` and stay open with
    /// the given frames written synchronously; `enqueuedFrames` stands in for
    /// the IOProc's queue count. The real `stop()` then closes and reports.
    /// A microphone of three or more channels gets the file `start()` makes
    /// for it; its samples are 0.1 in `microphoneSignalChannel` only.
    static func adoptedForTesting(
        systemURL: URL,
        microphoneURL: URL,
        sampleRate: Double,
        systemFrames: UInt32,
        microphoneFrames: UInt32,
        enqueuedFrames: Int64,
        microphoneChannels: UInt32 = 1,
        microphoneSignalChannel: UInt32 = 0,
        declaredSystemRate: Double? = nil,
        liveCapacityFrames: Int? = nil,
        microphoneNonInterleaved: Bool = false
    ) throws -> SystemAudioTapRecorder {
        func format(channels: UInt32, rate: Double, nonInterleaved: Bool = false) -> AudioStreamBasicDescription {
            var flags: AudioFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
            if nonInterleaved { flags |= kAudioFormatFlagIsNonInterleaved }
            return AudioStreamBasicDescription(
                mSampleRate: rate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: flags,
                mBytesPerPacket: 4 * channels,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4 * channels,
                mChannelsPerFrame: channels,
                mBitsPerChannel: 32,
                mReserved: 0
            )
        }
        let systemFile = try createFile(
            at: systemURL, format: format(channels: 1, rate: sampleRate), operation: "test system track"
        )
        let microphoneFile = microphoneChannels >= 3
            ? try createFirstChannelFile(
                at: microphoneURL,
                streamFormat: format(channels: microphoneChannels, rate: sampleRate),
                operation: "test microphone track"
            )
            : try createFile(
                at: microphoneURL, format: format(channels: microphoneChannels, rate: sampleRate),
                operation: "test microphone track"
            )
        let tracks = [
            (systemFile, systemFrames, UInt32(1), UInt32(0)),
            (microphoneFile, microphoneFrames, microphoneChannels, microphoneSignalChannel),
        ]
        for (file, frames, channels, signal) in tracks where frames > 0 {
            var samples = (0..<Int(frames * channels)).map { $0 % Int(channels) == Int(signal) ? Float(0.1) : 0 }
            try samples.withUnsafeMutableBytes { raw in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: channels,
                        mDataByteSize: UInt32(raw.count),
                        mData: raw.baseAddress
                    )
                )
                try check(ExtAudioFileWrite(file, frames, &list), "test track write")
            }
        }
        // Goes through the real `trackFormats`/`liveRing`, like `start()`, so
        // a declared tap rate different from the clock is refused the same
        // way (test 2). The non-interleaved flag only varies this decision
        // call, never the file's own format.
        let live: LiveAudioRing?
        switch SystemAudioCapture.trackFormats(
            clockRate: sampleRate,
            microphone: format(channels: microphoneChannels, rate: sampleRate, nonInterleaved: microphoneNonInterleaved),
            system: format(channels: 1, rate: declaredSystemRate ?? sampleRate),
            microphoneChannels: microphoneChannels
        ) {
        case let .record(microphoneFormat, systemFormat):
            live = liveRing(
                microphone: microphoneFormat,
                system: systemFormat,
                firstChannelOnly: microphoneChannels >= 3,
                capacityFrames: liveCapacityFrames
            )
        case .refuse:
            live = nil
        }
        let runtime = SystemAudioRuntime(
            systemFile: systemFile,
            microphoneFile: microphoneFile,
            systemBufferIndex: 0,
            microphoneBufferIndex: 1,
            systemBytesPerFrame: 4,
            microphoneBytesPerFrame: 4 * microphoneChannels,
            sampleRate: sampleRate,
            live: live
        )
        runtime.frames = enqueuedFrames
        runtime.writtenFrames.store(enqueuedFrames, ordering: .relaxed)
        // There is no ring to overflow here: a test hands cycles over far
        // faster than a device's clock, and `writesSynchronouslyForTesting`
        // is set before the first `deliverCycleForTesting`.
        runtime.writesSynchronouslyForTesting = true
        let recorder = SystemAudioTapRecorder()
        recorder.runtime = runtime
        recorder.sampleRate = sampleRate
        return recorder
    }

    /// Test-only: one cycle through the real IOProc, handed over the way Core
    /// Audio does it: one buffer per entry of `frames`, in the adopted
    /// session's stream order (system, then microphone), every system sample
    /// 0.1 and every microphone sample `microphone` (0 is the exact silence
    /// of a microphone that sends nothing). A 0 in `frames` is an empty
    /// buffer; a missing entry, a stream that is gone.
    /// `systemSamples`/`microphoneSamples`, given, replace the constant
    /// signal for that stream (length: frames × that stream's channels,
    /// interleaved, the whole cycle in one array — only used when the count
    /// matches). `failingWrite` makes this one cycle's write fail without
    /// touching either file (see `SystemAudioRuntime.failsWritesForTesting`).
    func deliverCycleForTesting(
        frames: [UInt32],
        microphone: Float = 0.1,
        systemSamples: [Float]? = nil,
        microphoneSamples: [Float]? = nil,
        failingWrite: Bool = false
    ) -> OSStatus {
        guard let runtime else { return kAudioHardwareNotRunningError }
        runtime.failsWritesForTesting = failingWrite
        let list = AudioBufferList.allocate(maximumBuffers: max(frames.count, 1))
        list.count = frames.count
        defer {
            for buffer in list { buffer.mData?.deallocate() }
            free(list.unsafeMutablePointer)
        }
        for (index, count) in frames.enumerated() {
            let bytesPerFrame = index == 0 ? runtime.systemBytesPerFrame : runtime.microphoneBytesPerFrame
            let samples = Int(count * bytesPerFrame) / MemoryLayout<Float>.size
            var data: UnsafeMutableRawPointer?
            if samples > 0 {
                let memory = UnsafeMutablePointer<Float>.allocate(capacity: samples)
                let provided = index == 0 ? systemSamples : microphoneSamples
                if let provided, provided.count == samples {
                    provided.withUnsafeBufferPointer { buffer in
                        memory.initialize(from: buffer.baseAddress!, count: samples)
                    }
                } else {
                    memory.initialize(repeating: index == 0 ? 0.1 : microphone, count: samples)
                }
                data = UnsafeMutableRawPointer(memory)
            }
            list[index] = AudioBuffer(
                mNumberChannels: bytesPerFrame / UInt32(MemoryLayout<Float>.size),
                mDataByteSize: count * bytesPerFrame,
                mData: data
            )
        }
        var now = AudioTimeStamp()
        var inputTime = AudioTimeStamp()
        var outputTime = AudioTimeStamp()
        var output = AudioBufferList()
        return murmurlySystemAudioIOProc(
            AudioObjectID(kAudioObjectUnknown), &now, list.unsafePointer, &inputTime, &output, &outputTime,
            Unmanaged.passUnretained(runtime).toOpaque()
        )
    }
}

extension SystemAudioCapture {
    /// Test-only: fills the fields `start()` fills, so the real `stop()` runs.
    func adoptSessionForTesting(
        directory: URL,
        sampleRate: Double,
        systemFrames: UInt32,
        microphoneFrames: UInt32,
        enqueuedFrames: Int64,
        startedAt: Date,
        endedAt: Date? = nil,
        microphoneChannels: UInt32 = 1,
        microphoneSignalChannel: UInt32 = 0,
        declaredSystemRate: Double? = nil,
        liveCapacityFrames: Int? = nil,
        microphoneNonInterleaved: Bool = false
    ) throws {
        let systemURL = directory.appendingPathComponent("system.caf")
        tapRecorder = try SystemAudioTapRecorder.adoptedForTesting(
            systemURL: systemURL,
            microphoneURL: directory.appendingPathComponent("microphone.caf"),
            sampleRate: sampleRate,
            systemFrames: systemFrames,
            microphoneFrames: microphoneFrames,
            enqueuedFrames: enqueuedFrames,
            microphoneChannels: microphoneChannels,
            microphoneSignalChannel: microphoneSignalChannel,
            declaredSystemRate: declaredSystemRate,
            liveCapacityFrames: liveCapacityFrames,
            microphoneNonInterleaved: microphoneNonInterleaved
        )
        sessionDirectory = directory
        self.systemURL = systemURL
        self.startedAt = startedAt
        endedAtForTesting = endedAt
    }

    /// Test-only: one IOProc cycle for the adopted session
    /// (`SystemAudioTapRecorder.deliverCycleForTesting`).
    @discardableResult
    func deliverCycleForTesting(
        frames: [UInt32],
        microphone: Float = 0.1,
        systemSamples: [Float]? = nil,
        microphoneSamples: [Float]? = nil,
        failingWrite: Bool = false
    ) -> OSStatus {
        tapRecorder?.deliverCycleForTesting(
            frames: frames,
            microphone: microphone,
            systemSamples: systemSamples,
            microphoneSamples: microphoneSamples,
            failingWrite: failingWrite
        ) ?? kAudioHardwareNotRunningError
    }
}
#endif
