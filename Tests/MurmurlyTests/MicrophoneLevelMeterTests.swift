import AVFoundation
import Foundation
import XCTest
@testable import Murmurly

final class MicrophoneLevelMeterTests: XCTestCase {
    func testRMSDecibelCurveUsesMeasuredSpeechRange() {
        let cases: [(decibels: Float, height: CGFloat)] = [
            (-60, 5.0),
            (-45, 5.0),
            (-40, 7.5),
            (-27, 14.0),
            (-15, 14.0),
        ]

        for testCase in cases {
            let linearRMS = pow(10, testCase.decibels / 20)
            XCTAssertEqual(
                MicrophoneLevelMeter.normalizedHeight(for: linearRMS),
                testCase.height,
                accuracy: 0.06,
                "Unexpected height at \(testCase.decibels) dB"
            )
        }
    }

    func testNormalizationRejectsInvalidValuesAndClampsBothEnds() {
        let minimum = MicrophoneLevelMeter.minimumHeight
        XCTAssertEqual(MicrophoneLevelMeter.normalizedHeight(for: 0), minimum)
        XCTAssertEqual(MicrophoneLevelMeter.normalizedHeight(for: -1), minimum)
        XCTAssertEqual(MicrophoneLevelMeter.normalizedHeight(for: .nan), minimum)
        XCTAssertEqual(MicrophoneLevelMeter.normalizedHeight(for: .infinity), minimum)
        XCTAssertEqual(MicrophoneLevelMeter.normalizedHeight(for: 0.000_001), minimum)
        XCTAssertEqual(
            MicrophoneLevelMeter.normalizedHeight(for: 1),
            MicrophoneLevelMeter.maximumHeight
        )
    }

    func testSingleLoudSampleDoesNotProduceAHighBar() throws {
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)
        )
        buffer.frameLength = 4_096
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.initialize(repeating: 0, count: 4_096)
        samples[0] = 1

        let rms = MicCapture.rootMeanSquare(in: buffer)

        XCTAssertEqual(rms, 1 / sqrt(4_096), accuracy: 0.000_001)
        XCTAssertLessThan(
            MicrophoneLevelMeter.normalizedHeight(for: rms),
            (MicrophoneLevelMeter.minimumHeight + MicrophoneLevelMeter.maximumHeight) / 2
        )
    }

    func testAtomicLevelReturnsMaximumThenClears() {
        let meter = MicrophoneLevelMeter()
        meter.record(level: 0.25)
        meter.record(level: .nan)
        meter.record(level: 0.75)
        meter.record(level: 0.5)
        meter.record(level: .infinity)

        XCTAssertEqual(meter.takeLevel(), 0.75)
        XCTAssertEqual(meter.takeLevel(), 0)

        meter.record(level: 0.4)
        meter.reset()
        XCTAssertEqual(meter.takeLevel(), 0)
    }
}
