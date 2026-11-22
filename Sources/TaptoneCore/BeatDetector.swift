import Foundation

/// Detects bass attacks with causal 20 ms energy windows and 10 ms hops.
/// This is deliberately an onset detector, not a tempo estimator.
public struct BeatDetector {
    public enum Sensitivity: String, CaseIterable, Sendable {
        case low, normal, high

        fileprivate var thresholds: (floor: Float, rise: Float, baseline: Float) {
            switch self {
            case .low: (0.0001, 1.8, 3.0)
            case .normal: (0.000025, 1.5, 2.2)
            case .high: (0.000006, 1.3, 1.7)
            }
        }
    }

    public struct Reading: Sendable {
        public let levelDBFS: Float
        public let isBeat: Bool
    }

    public var sensitivity: Sensitivity = .normal

    private let hopSize: Int
    private let minimumSpacing: Int
    private let lower: Float
    private let upper: Float
    private let baselineStep: Float
    private var leftBand = BassBand()
    private var rightBand = BassBand()
    private var samplesInHop = 0
    private var index = 0
    private var hopBass: Float = 0
    private var hopFull: Float = 0
    private var lastHopBass: Float = 0
    private var lastWindow: Float = 0
    private var baseline: Float = 0
    private var lastBeat: Int?

    public init(sampleRate: Double) {
        precondition(sampleRate.isFinite && (8_000...384_000).contains(sampleRate))
        hopSize = Int((0.010 * sampleRate).rounded())
        minimumSpacing = Int((0.140 * sampleRate).rounded())
        lower = Self.coefficient(45, sampleRate)
        upper = Self.coefficient(180, sampleRate)
        baselineStep = 1 - exp(-Float(hopSize) / Float(sampleRate * 0.65))
    }

    /// Feed one stereo frame. For mono, pass the same sample in both channels.
    public mutating func push(left: Float, right: Float) -> Reading? {
        let l = Self.finiteSample(left)
        let r = Self.finiteSample(right)
        let a = leftBand.push(l, lower: lower, upper: upper)
        let b = rightBand.push(r, lower: lower, upper: upper)
        // Combine power, not samples: anti-phase channels must not cancel.
        hopBass += (a * a + b * b) * 0.5
        hopFull += (l * l + r * r) * 0.5
        index += 1
        samplesInHop += 1
        guard samplesInHop == hopSize else { return nil }

        let bass = hopBass / Float(hopSize)
        let full = hopFull / Float(hopSize)
        let window = (bass + lastHopBass) * 0.5
        let threshold = sensitivity.thresholds
        let isBeat = window >= threshold.floor
            && window > lastWindow * threshold.rise
            && window > baseline * threshold.baseline
            && (lastBeat.map { index - $0 >= minimumSpacing } ?? true)
        if isBeat { lastBeat = index }

        baseline += (window - baseline) * baselineStep
        lastHopBass = bass
        lastWindow = window
        samplesInHop = 0
        hopBass = 0
        hopFull = 0
        return Reading(levelDBFS: 10 * log10(max(full, 1e-9)), isBeat: isBeat)
    }

    private static func coefficient(_ cutoff: Double, _ sampleRate: Double) -> Float {
        Float(1 - exp(-2 * .pi * cutoff / sampleRate))
    }

    private static func finiteSample(_ sample: Float) -> Float {
        sample.isFinite ? min(1, max(-1, sample)) : 0
    }
}

private struct BassBand {
    private var hp1: Float = 0
    private var hp2: Float = 0
    private var lp1: Float = 0
    private var lp2: Float = 0

    mutating func push(_ sample: Float, lower: Float, upper: Float) -> Float {
        hp1 += lower * (sample - hp1)
        let high = sample - hp1
        hp2 += lower * (high - hp2)
        lp1 += upper * (high - hp2 - lp1)
        lp2 += upper * (lp1 - lp2)
        return lp2
    }
}
