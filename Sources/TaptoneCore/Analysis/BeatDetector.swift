import Foundation

/// Detects kick-drum attacks with causal 20 ms energy windows and 10 ms hops in a 45–130 Hz band.
/// A window is an attack when it rises clearly above the last ~100 ms, judged in decibels against how much
/// that band has been fluctuating: over a steady sub-bass a small rise counts, over a rumble it takes a big one.
/// Attacks whose window is mostly outside the band (snares, toms' upper shells, notification sounds) are ignored.
/// This is deliberately an onset detector, not a tempo estimator.
public struct BeatDetector: Sendable {
    public enum Sensitivity: String, CaseIterable, Sendable {
        case low, normal, high

        /// `floor`: least band power; `riseDB`: least rise over the last ~100 ms; `sigmas`: least rise in
        /// units of the recent mean window-to-window jitter; `edgeDB`: least rise over the window 20 ms earlier;
        /// `baseline`: least ratio to the last ~650 ms of band power.
        fileprivate var thresholds: (floor: Float, riseDB: Float, sigmas: Float, edgeDB: Float, baseline: Float) {
            switch self {
            case .low: (0.0001, 3.0, 4.5, 2.0, 2.0)
            case .normal: (0.000025, 2.0, 4.0, 1.5, 1.5)
            case .high: (0.000006, 1.5, 3.0, 1.0, 1.25)
            }
        }
    }

    public struct Reading: Sendable {
        public let levelDBFS: Float
        public let isBeat: Bool
        /// Share of this window's power inside the kick band (0...1): near 1 for a kick on its own.
        public let bassShare: Float
    }

    /// A beat needs at least this share of its window's power in the kick band.
    static let minimumShare: Float = 0.05
    static let jitterCapDB: Float = 6
    /// The 20 ms edge must also stand out from the jitter: a wobble or a rumble keeps moving, a kick jumps.
    static let edgeSigmas: Float = 3.0
    /// Within 150 ms of a beat, a second one must come within this of the first one's peak: a double kick
    /// hits as hard, a bass note starting under the kick's tail doesn't.
    static let followUpDB: Float = 3

    public var sensitivity: Sensitivity = .normal

    private let hopSize: Int
    private let minimumSpacing: Int
    private let meanStep: Float
    private let jitterStep: Float
    private let baselineStep: Float
    private var baseline: Float = 0
    private var leftBand: KickBand
    private var rightBand: KickBand
    private var samplesInHop = 0
    private var index = 0
    private var hopBass: Float = 0
    private var hopFull: Float = 0
    private var lastHopBass: Float = 0
    private var lastHopFull: Float = 0
    /// Recent window level in dB and its jitter, from windows before the current one.
    private var meanDB: Float?
    private var jitterDB: Float = 0
    private var lastLevel: Float?
    private var earlierLevel: Float?
    private var lastBeat: Int?
    /// Loudest window since the last beat, while a follow-up could still come.
    private var lastBeatPeakDB: Float = 0
    private let followUpWindow: Int
    private var swallowing = false

    public init(sampleRate: Double) {
        precondition(sampleRate.isFinite && (8_000...384_000).contains(sampleRate))
        hopSize = Int((0.010 * sampleRate).rounded())
        // Spacing alone leaves room for 16th-note double kicks at 170 BPM (88 ms), not for one kick read twice.
        minimumSpacing = Int((0.080 * sampleRate).rounded())
        followUpWindow = Int((0.150 * sampleRate).rounded())
        meanStep = 1 - exp(-0.010 / 0.100)
        jitterStep = 1 - exp(-0.010 / 0.250)
        baselineStep = 1 - exp(-0.010 / 0.650)
        leftBand = KickBand(rate: sampleRate)
        rightBand = leftBand
    }

    /// Feed one stereo frame. For mono, pass the same sample in both channels.
    public mutating func push(left: Float, right: Float) -> Reading? {
        let l = left.clampedSample
        let r = right.clampedSample
        let a = leftBand.push(l)
        let b = rightBand.push(r)
        // Combine power, not samples: anti-phase channels must not cancel.
        hopBass += (a * a + b * b) * 0.5
        hopFull += (l * l + r * r) * 0.5
        index += 1
        samplesInHop += 1
        guard samplesInHop == hopSize else { return nil }

        let bass = hopBass / Float(hopSize)
        let full = hopFull / Float(hopSize)
        let window = (bass + lastHopBass) * 0.5
        let windowFull = (full + lastHopFull) * 0.5
        let share = windowFull > 0 ? min(1, window / windowFull) : 0
        let threshold = sensitivity.thresholds
        // Silence reads as a little under the floor, so coming out of it isn't a 60 dB swing in the statistics,
        // and a faint rumble hovering at the floor doesn't look like it keeps jumping off it.
        let level = 10 * log10(max(window, threshold.floor * 0.25))
        let mean = meanDB ?? level
        let rise = level - mean

        let attack = window >= threshold.floor
            && rise > max(threshold.riseDB, threshold.sigmas * jitterDB)
            && level - (earlierLevel ?? lastLevel ?? level) > max(threshold.edgeDB, Self.edgeSigmas * jitterDB)
            && window > baseline * threshold.baseline
            && share >= Self.minimumShare
            && (lastBeat.map { index - $0 >= minimumSpacing } ?? true)
        let followsUp = lastBeat.map { index - $0 >= followUpWindow || level >= lastBeatPeakDB - Self.followUpDB } ?? true
        // A rejected follow-up stays rejected until it stops rising, so it can't slip in late in its own rise.
        if attack, !followsUp { swallowing = true }
        if let lastLevel, level <= lastLevel { swallowing = false }
        let isBeat = attack && followsUp && !swallowing
        if isBeat {
            lastBeat = index
            lastBeatPeakDB = level
        } else if let lastBeat, index - lastBeat < followUpWindow {
            lastBeatPeakDB = max(lastBeatPeakDB, level)
        }

        // Fluctuation is the mean window-to-window jitter: near zero over a held sub or a kick's smooth decay,
        // several dB over a rumble. Each step's say is capped, so one kick doesn't hide the next.
        jitterDB += (min(Self.jitterCapDB, abs(level - (lastLevel ?? level))) - jitterDB) * jitterStep
        meanDB = mean + rise * meanStep
        baseline += (window - baseline) * baselineStep
        earlierLevel = lastLevel
        lastLevel = level
        lastHopBass = bass
        lastHopFull = full
        samplesInHop = 0
        hopBass = 0
        hopFull = 0
        return Reading(levelDBFS: 10 * log10(max(full, 1e-9)), isBeat: isBeat, bassShare: share)
    }
}

/// 45 Hz second-order high-pass into a 130 Hz fourth-order Butterworth low-pass: a kick's fundamental
/// and most of its pitch dive, with snare shells (190–220 Hz) 13–18 dB down.
private struct KickBand: Sendable {
    private var high: Biquad
    private var low: ButterworthLowPass

    init(rate: Double) {
        high = Biquad(rate: rate, frequency: 45, q: 1 / sqrt(2), highPass: true)
        low = ButterworthLowPass(rate: rate, frequency: 130)
    }

    mutating func push(_ sample: Float) -> Float {
        Float(low.push(high.push(Double(sample))))
    }
}
