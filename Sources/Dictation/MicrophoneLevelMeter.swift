import CoreGraphics
import Foundation
import Synchronization

/// A lock-free RMS handoff from Core Audio to the 12 Hz indicator timeline.
/// Positive finite Float bit patterns preserve numeric ordering, so the audio
/// callback can publish the loudest buffer without a lock or allocation.
final class MicrophoneLevelMeter: Sendable {
    static let minimumHeight: CGFloat = 5
    static let maximumHeight: CGFloat = 14
    static let noiseFloorDB: Float = -45
    static let ceilingDB: Float = -27

    private let levelBits = Atomic<UInt32>(0)

    func record(level: Float) {
        guard level.isFinite, level > 0 else { return }
        let desired = level.bitPattern
        var current = levelBits.load(ordering: .relaxed)
        while current < desired {
            let result = levelBits.compareExchange(
                expected: current,
                desired: desired,
                ordering: .relaxed
            )
            guard !result.exchanged else { return }
            current = result.original
        }
    }

    func takeLevel() -> Float {
        Float(bitPattern: levelBits.exchange(0, ordering: .relaxed))
    }

    func reset() {
        levelBits.store(0, ordering: .relaxed)
    }

    static func normalizedHeight(for level: Float) -> CGFloat {
        guard level.isFinite, level > 0 else { return minimumHeight }
        let decibels = 20 * log10(level)
        guard decibels.isFinite else { return minimumHeight }
        let span = ceilingDB - noiseFloorDB
        let normalized = min(max((decibels - noiseFloorDB) / span, 0), 1)
        return minimumHeight
            + (maximumHeight - minimumHeight) * CGFloat(normalized)
    }
}
