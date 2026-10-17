import AudioToolbox
import AVFoundation
import Foundation
import XCTest
@testable import Murmurly

private actor RefusingMeetingCapture: MeetingCaptureBackend {
    private let error: SystemAudioCaptureError
    init(_ error: SystemAudioCaptureError) { self.error = error }
    func start(in _: URL) async throws -> Date { throw error }
    func stop() async throws -> [URL] { [] }
}

/// A Mac with no input device at all: no built-in microphone and the
/// headset disconnected.
@MainActor
final class MissingMicrophoneTests: XCTestCase {
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The real capture and coordinator; only the device answer is faked.
    /// Without the check the capture went on to AVAudioEngine, whose
    /// installTap raised an NSException and the app quit unexpectedly.
    func testDictationWithoutInputDeviceShowsTheErrorAndKeepsRunning() async throws {
        let mic = MicCapture(levelMeter: MicrophoneLevelMeter(), hasInputDevice: { false })
        let indicator = RecordingIndicator(renderingEnabled: false)
        let coordinator = DictationCoordinator(mic: mic, indicator: indicator)

        coordinator.beginCaptureForTesting()

        let idle = await eventually { coordinator.state == .idle }
        XCTAssertTrue(idle, "the start must fail, not record or hang")
        XCTAssertEqual(
            indicator.presentedState,
            .dictationFailure(message: "Microphone unavailable (no input device)")
        )
        let leftover = try await mic.stop()
        XCTAssertNil(leftover, "nothing was left half-started")
    }

    /// The capture's answer reaches the menu's second line: with no input
    /// device the next step is to connect one; a refused permission keeps
    /// pointing to Permissions.
    func testFailedMeetingHintNamesTheMissingDeviceNotPermissions() async {
        let noDevice = recorder(failingWith: .noInputDevice)
        noDevice.toggle()
        let noDeviceFailed = await eventually { noDevice.state.failureHint != nil }
        XCTAssertTrue(noDeviceFailed)
        XCTAssertEqual(noDevice.state.failureHint, "Connect a microphone, then choose Record Meeting")

        let noPermission = recorder(failingWith: .microphoneUnavailable)
        noPermission.toggle()
        let noPermissionFailed = await eventually { noPermission.state.failureHint != nil }
        XCTAssertTrue(noPermissionFailed)
        XCTAssertEqual(
            noPermission.state.failureHint,
            "Check Settings → Permissions, then choose Record Meeting"
        )
    }

    /// Seen in a live run: Firefox took the microphone, which for a
    /// moment had no channels (or, with voice processing, three). One not
    /// ready yet is waited for; three or more channels are no reason to refuse.
    func testMicrophonePlanWaitsForANotReadyDeviceAndTakesTheFirstOfManyChannels() {
        XCTAssertEqual(SystemAudioCapture.microphonePlan(streamChannels: [1]), .record)
        XCTAssertEqual(SystemAudioCapture.microphonePlan(streamChannels: [2]), .record)
        XCTAssertEqual(
            SystemAudioCapture.microphonePlan(streamChannels: [0]), .wait,
            "a microphone without channels yet is refused at once"
        )
        XCTAssertEqual(
            SystemAudioCapture.microphonePlan(streamChannels: []), .wait,
            "a microphone without its stream yet is refused at once"
        )
        XCTAssertEqual(
            SystemAudioCapture.microphonePlan(streamChannels: [3]), .firstChannel,
            "three channels of voice processing are refused"
        )
        XCTAssertEqual(SystemAudioCapture.microphonePlan(streamChannels: [7]), .firstChannel)
        guard case .refuse = SystemAudioCapture.microphonePlan(streamChannels: [1, 1]) else {
            return XCTFail("two input streams are taken for one microphone track")
        }
    }

    /// Three channels, as voice processing makes them: the track keeps the
    /// first, written the way the IOProc writes (asynchronously, every channel
    /// handed over), and read back as a mono file holding only that channel.
    func testThreeChannelMicrophoneIsWrittenAsItsFirstChannel() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("first-channel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("microphone.caf")
        let stream = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 12, mFramesPerPacket: 1, mBytesPerFrame: 12,
            mChannelsPerFrame: 3, mBitsPerChannel: 32, mReserved: 0
        )
        let frames = 512
        let frame: [Float] = [0.5, -0.25, 0.75]
        var samples = (0..<frames * frame.count).map { frame[$0 % frame.count] }

        let file = try SystemAudioTapRecorder.createFirstChannelFile(at: url, streamFormat: stream, operation: "test")
        let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 3, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            )
            return ExtAudioFileWriteAsync(file, UInt32(frames), &list)
        }
        XCTAssertEqual(status, noErr)
        XCTAssertEqual(ExtAudioFileDispose(file), noErr)

        let written = try AVAudioFile(forReading: url)
        XCTAssertEqual(written.fileFormat.channelCount, 1)
        XCTAssertEqual(written.length, AVAudioFramePosition(frames))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: written.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
        try written.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        XCTAssertEqual(Set((0..<Int(buffer.frameLength)).map { channel[$0] }), [0.5], "not the first channel alone")
    }

    /// AirPods measured live: the headset's microphone runs at 24 kHz, and so
    /// does the aggregate it clocks. The tap arrives resampled to it, 480
    /// frames a cycle on both streams, while its stream still declares 48 kHz.
    /// Such a recording was refused before it started; it is written, with the
    /// system file at the clock's rate, not at the rate the tap declares.
    func testHeadsetMicrophoneAt24kHzRecordsBothTracksAtTheClockRate() {
        let plan = SystemAudioCapture.trackFormats(
            clockRate: 24_000,
            microphone: Self.stream(rate: 24_000, channels: 1),
            system: Self.stream(rate: 48_000, channels: 1),
            microphoneChannels: 1
        )
        guard case let .record(microphone, system) = plan else {
            return XCTFail("a 24 kHz headset with a 48 kHz tap was refused: \(plan)")
        }
        XCTAssertEqual(microphone.mSampleRate, 24_000)
        XCTAssertEqual(system.mSampleRate, 24_000, "a file at the declared 48 kHz would play 24 kHz audio twice as fast")
        XCTAssertEqual(system.mChannelsPerFrame, 1)
        XCTAssertEqual(system.mBytesPerFrame, 4)
        XCTAssertEqual(system.mFormatFlags, kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
    }

    /// The microphone is the aggregate's clock; a stream of it running at
    /// another rate is a device caught mid-change, and nothing tells which
    /// rate the cycles will bring.
    func testMicrophoneStreamOffTheClockIsRefused() {
        let plan = SystemAudioCapture.trackFormats(
            clockRate: 24_000,
            microphone: Self.stream(rate: 48_000, channels: 1),
            system: Self.stream(rate: 48_000, channels: 1),
            microphoneChannels: 1
        )
        guard case .refuse = plan else {
            return XCTFail("a microphone stream off the aggregate's clock was written: \(plan)")
        }
    }

    /// What the files cannot hold is refused as before, and equal rates pass
    /// unchanged, a voice-processing microphone with all its channels.
    func testTrackFormatsPassEqualRatesAndRefuseWhatTheFilesCannotHold() {
        let mono = Self.stream(rate: 48_000, channels: 1)
        guard case let .record(microphone, system) = SystemAudioCapture.trackFormats(
            clockRate: 48_000, microphone: Self.stream(rate: 48_000, channels: 3), system: mono, microphoneChannels: 3
        ) else {
            return XCTFail("equal rates were refused")
        }
        XCTAssertEqual(microphone.mChannelsPerFrame, 3, "start() makes the first-channel file from the whole stream")
        XCTAssertEqual(microphone.mSampleRate, 48_000)
        XCTAssertEqual(system.mSampleRate, 48_000)

        var noBytes = mono
        noBytes.mBytesPerFrame = 0
        let refused: [(String, SystemAudioCapture.TrackFormats)] = [
            ("microphone channels changed", SystemAudioCapture.trackFormats(
                clockRate: 48_000, microphone: Self.stream(rate: 48_000, channels: 2), system: mono, microphoneChannels: 1
            )),
            ("stereo tap", SystemAudioCapture.trackFormats(
                clockRate: 48_000, microphone: mono, system: Self.stream(rate: 48_000, channels: 2), microphoneChannels: 1
            )),
            ("empty microphone frames", SystemAudioCapture.trackFormats(
                clockRate: 48_000, microphone: noBytes, system: mono, microphoneChannels: 1
            )),
            ("empty system frames", SystemAudioCapture.trackFormats(
                clockRate: 48_000, microphone: mono, system: noBytes, microphoneChannels: 1
            )),
        ]
        for (name, plan) in refused {
            guard case let .refuse(reason) = plan else {
                XCTFail("\(name) was written: \(plan)")
                continue
            }
            XCTAssertEqual(reason, "Core Audio couldn’t match the formats of the combined device", name)
        }
    }

    private static func stream(rate: Double, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0
        )
    }

    /// A recording that broke off on stop was saved as far as it went, so the
    /// permissions are not what to check. Live, a write error came with
    /// "Check Settings → Permissions, then choose Record Meeting".
    func testRecordingThatFailedOnStopDoesNotSendTheUserToPermissions() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-stop-\(UUID().uuidString) Meeting", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = MeetingRecorder(
            capture: AdoptedMeetingCapture(directory: folder, cycles: [[480, 480]], deleting: "system.caf"),
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero
        )

        recorder.toggle()
        let started = await eventually { recorder.state == .recording }
        XCTAssertTrue(started)
        recorder.toggle()
        let failed = await eventually {
            if case .failed = recorder.state { return true }
            return false
        }

        XCTAssertTrue(failed, "\(recorder.state)")
        XCTAssertNil(recorder.state.failureHint)
    }

    /// A microphone not ready yet is a matter of a moment, not of permissions.
    func testNotReadyMicrophoneHintSaysToWaitNotToCheckPermissions() async {
        let notReady = recorder(failingWith: .microphoneNotReady)
        notReady.toggle()
        let failed = await eventually { notReady.state.failureHint != nil }
        XCTAssertTrue(failed)
        XCTAssertEqual(notReady.state.failureHint, "Wait a moment, then choose Record Meeting")
    }

    private func recorder(failingWith error: SystemAudioCaptureError) -> MeetingRecorder {
        MeetingRecorder(
            capture: RefusingMeetingCapture(error),
            indicator: RecordingIndicator(renderingEnabled: false),
            hasMicrophoneAccess: { true },
            permissionPromptDelay: .zero
        )
    }
}
