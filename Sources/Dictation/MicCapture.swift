import AVFoundation
import CoreAudio
import Foundation

protocol MicCapturing: Sendable {
    func start() async throws
    func stop() async throws -> URL?
}

private final class CaptureErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func record(_ error: Error) {
        lock.lock()
        if self.error == nil { self.error = error }
        lock.unlock()
    }

    func snapshot() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

/// Serial isolation for AVAudioEngine. In particular, engine.start() never runs
/// on MainActor, so the hotkey and watchdog remain responsive during Core Audio
/// stalls. A fresh engine is used for every attempt to bind the current input.
actor MicCapture: MicCapturing {
    enum CaptureError: LocalizedError, Sendable {
        case noInputDevice
        case configurationChanged

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return String(localized: "Microphone unavailable (no input device)")
            case .configurationChanged:
                return String(localized: "The audio device changed during recording")
            }
        }
    }

    /// Capture failed after audio reached the file. Like a meeting's
    /// `captureFailed`, the file is handed over instead of being deleted.
    struct PartialRecording: LocalizedError, Sendable {
        let url: URL
        /// Short and user-facing; the full error goes to the log.
        let reason: String

        var errorDescription: String? { String(localized: "Recording interrupted: \(reason)") }
    }

    private var engine: AVAudioEngine?
    private var url: URL?
    private var errorBox: CaptureErrorBox?
    private var configurationObserver: NSObjectProtocol?
    private var isRecording = false
    private let levelMeter: MicrophoneLevelMeter
    /// Asked before the engine is built; tests stand in for a Mac without one.
    private let hasInputDevice: @Sendable () -> Bool

    init(
        levelMeter: MicrophoneLevelMeter,
        hasInputDevice: @escaping @Sendable () -> Bool = MicCapture.systemHasInputDevice
    ) {
        self.levelMeter = levelMeter
        self.hasInputDevice = hasInputDevice
    }

    /// Core Audio's default input, which is none when the Mac has no microphone.
    nonisolated static func systemHasInputDevice() -> Bool {
        (try? AudioHardwareSystem.shared.defaultInputDevice) != nil
    }

    nonisolated static func rootMeanSquare(in buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else { return 0 }

        var sumOfSquares: Double = 0
        var sampleCount = 0
        if buffer.format.isInterleaved {
            let samples = channels[0]
            for index in 0..<(frameCount * channelCount) {
                let sample = samples[index]
                guard sample.isFinite else { continue }
                sumOfSquares += Double(sample) * Double(sample)
                sampleCount += 1
            }
        } else {
            for channel in 0..<channelCount {
                let samples = channels[channel]
                for frame in 0..<frameCount {
                    let sample = samples[frame]
                    guard sample.isFinite else { continue }
                    sumOfSquares += Double(sample) * Double(sample)
                    sampleCount += 1
                }
            }
        }

        guard sampleCount > 0 else { return 0 }
        return Float(sqrt(sumOfSquares / Double(sampleCount)))
    }

    func start() async throws {
        guard !isRecording else { return }
        try Task.checkCancellation()
        levelMeter.reset()
        // Without an input device the engine still offers a plausible tap
        // format, and installTap raises an NSException that Swift cannot catch.
        guard hasInputDevice() else { throw CaptureError.noInputDevice }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")
        let errors = CaptureErrorBox()

        do {
            let file = try AVAudioFile(forWriting: outputURL, settings: format.settings)
            let levelMeter = self.levelMeter
            // The same exception when the tap format is not the hardware's: a
            // device that left or is reconfiguring since the check above. Read
            // last, so only installTap itself is left in that window.
            let hardware = input.inputFormat(forBus: 0)
            guard hardware.channelCount > 0, hardware.sampleRate == format.sampleRate else {
                throw CaptureError.noInputDevice
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                levelMeter.record(level: Self.rootMeanSquare(in: buffer))
                // Nothing after the first failure: the kept file must be a
                // continuous prefix of the dictation, not audio with a hole.
                guard errors.snapshot() == nil else { return }
                do {
                    try file.write(from: buffer)
                } catch {
                    errors.record(error)
                }
            }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }

            self.engine = engine
            self.url = outputURL
            self.errorBox = errors
            self.isRecording = true
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { _ in
                errors.record(CaptureError.configurationChanged)
            }

            if Task.isCancelled {
                _ = try? await stop()
                throw CancellationError()
            }
            AppLog.info("mic", "recording @ \(Int(format.sampleRate)) Hz, \(format.channelCount)ch")
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    /// nil means no active recording; a URL means a complete file. After a write
    /// or device-change failure, captured audio comes back as `PartialRecording`;
    /// only a file without audio is removed before the original error is thrown.
    func stop() async throws -> URL? {
        guard isRecording else { return nil }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRecording = false

        let outputURL = url
        let capturedError = errorBox?.snapshot()
        url = nil
        errorBox = nil

        if let capturedError {
            AppLog.error("mic", "recording failed: \(capturedError.localizedDescription)")
            if let outputURL {
                guard Self.holdsNoAudio(outputURL) else {
                    throw PartialRecording(url: outputURL, reason: Self.shortReason(for: capturedError))
                }
                try? FileManager.default.removeItem(at: outputURL)
            }
            throw capturedError
        }
        AppLog.info("mic", "recording stopped")
        return outputURL
    }

    #if DEBUG
    /// Test-only: stands in for a started session by filling the fields that
    /// start() fills, so the real stop() runs without AVAudioEngine.
    func adoptRecordingForTesting(url: URL, error: Error?) {
        let box = CaptureErrorBox()
        if let error { box.record(error) }
        self.url = url
        errorBox = box
        isRecording = true
    }
    #endif

    /// True only when emptiness is proven: the file is missing, has zero bytes,
    /// or reads as zero frames. Anything unknown, including an unreadable size
    /// or an unreadable non-empty file, is kept so the audio can be recovered.
    nonisolated static func holdsNoAudio(_ url: URL) -> Bool {
        let size: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let value = (attributes[.size] as? NSNumber)?.int64Value else { return false }
            size = value
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return true
        } catch {
            return false
        }
        guard size > 0 else { return true }
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length == 0
    }

    private nonisolated static func shortReason(for error: Error) -> String {
        if case CaptureError.configurationChanged? = error as? CaptureError {
            return String(localized: "the audio device changed")
        }
        return String(localized: "audio recording error")
    }
}
