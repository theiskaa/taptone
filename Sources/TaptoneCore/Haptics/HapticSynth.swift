import Foundation

/// How hard the trackpad plays. Values are driver command levels, not measured force.
public enum HapticIntensity: String, CaseIterable, Sendable {
    case light, medium, strong

    /// Peak command level for a full-strength kick.
    public var kickLevel: Double {
        switch self {
        case .light: 0.40
        case .medium: 0.60
        case .strong: 0.85
        }
    }

    /// Command level for sustained bass at full weight. Kept below kicks so attacks stand out.
    public var bodyLevel: Double {
        switch self {
        case .light: 0.15
        case .medium: 0.24
        case .strong: 0.34
        }
    }
}

/// One waveform request: a sine at `frequencyHz` for a whole number of cycles, at a constant level.
public struct HapticSegment: Sendable, Equatable {
    public let frequencyHz: Double
    public let durationNs: UInt64
    public let level: Float
    public let isKick: Bool
}

/// Renders the cue being heard right now into back-to-back motor segments.
/// Sustained bass becomes a carrier tuned to the bass note (folded into the motor's range);
/// kicks add a short pitch-diving thump on top.
public struct HapticSynth: Sendable {
    /// Hard ceiling for any request, whatever the intensity.
    public static let maximumLevel: Float = 0.9
    public static let restingHz = 160.0
    /// Carriers stay where a fingertip feels them best and the motor can follow.
    public static let carrierRange = 100.0...280.0
    static let idleLevel = 0.015
    public static let bodyGate = 0.03
    static let kickSeconds = 0.150
    /// A bass note fades in over this long instead of starting with a click.
    static let attackSeconds = 0.015
    /// Under each kick the body steps back, then returns over this long, so the hit stands out.
    static let duckSeconds = 0.080
    static let duckDepth = 0.35

    public var intensity: HapticIntensity
    public private(set) var carrierHz = restingHz
    private var body = 0.0
    private var kick: (startNs: UInt64, strength: Double)?
    private var lastNs: UInt64?

    public init(intensity: HapticIntensity = .medium) {
        self.intensity = intensity
    }

    /// Fold a bass note by octaves to the carrier nearest `current`, so the motor hums in tune and
    /// small pitch changes never jump an octave.
    public static func carrier(for pitchHz: Double, near current: Double = restingHz) -> Double {
        guard pitchHz.isFinite, pitchHz > 0 else { return current }
        var best = current
        var distance = Double.infinity
        for octave in -4...4 {
            let candidate = pitchHz * pow(2, Double(octave))
            guard carrierRange.contains(candidate) else { continue }
            let gap = abs(log2(candidate / current))
            if gap < distance { (best, distance) = (candidate, gap) }
        }
        return best
    }

    /// `cue` is the analysis step heard now (nil when none is current); `onset` is a newly due kick.
    public mutating func next(at now: UInt64, cue: HapticCue?, onset: Double?) -> HapticSegment? {
        let seconds = lastNs.map { now > $0 ? Double(now - $0) / 1_000_000_000 : 0 } ?? 0
        lastNs = now
        if let onset, onset.isFinite { kick = (now, min(1, max(0, onset))) }

        let weight = cue.map { $0.body.isFinite ? min(1, max(0, $0.body)) : 0 } ?? 0
        let target = weight >= Self.bodyGate ? intensity.bodyLevel * pow(weight, 0.8) : 0
        // 15 ms attack, 30 ms release: notes start without a click, held notes stay smooth, staccato stays short.
        if target >= body {
            // Out of rest, the first segment counts as one step so a note never opens at full level.
            let step = body == 0 ? 0.006 : min(0.010, seconds)
            body = min(target, body + intensity.bodyLevel * step / Self.attackSeconds)
        } else {
            body += (target - body) * (1 - exp(-seconds / 0.030))
        }
        if target == 0, body < Self.idleLevel { body = 0 }

        if let pitch = cue?.pitchHz, weight >= Self.bodyGate {
            let goal = Self.carrier(for: pitch, near: carrierHz)
            carrierHz *= pow(goal / carrierHz, 1 - exp(-seconds / 0.015))
        }

        var kickLevel = 0.0
        var kickHz = carrierHz
        var duck = 1.0
        if let kick {
            let age = Double(now - kick.startNs) / 1_000_000_000
            if age > Self.kickSeconds {
                self.kick = nil
            } else {
                kickLevel = intensity.kickLevel * kick.strength * exp(-age / 0.045)
                kickHz = carrierHz + (320 - carrierHz) * exp(-age / 0.015)
                duck = Self.duckDepth + (1 - Self.duckDepth) * min(1, age / Self.duckSeconds)
            }
        }

        let bodyLevel = body * duck
        let isKick = kickLevel > bodyLevel
        let level = max(bodyLevel, kickLevel)
        guard level >= Self.idleLevel else { return nil }
        let hertz = isKick ? kickHz : carrierHz
        // Whole cycles keep consecutive segments phase-continuous. ~6 ms keeps the envelope responsive.
        let cycles = isKick ? 1 : max(1, (0.006 * hertz).rounded())
        let duration = UInt64((cycles / hertz * 1_000_000_000).rounded())
        return HapticSegment(frequencyHz: hertz, durationNs: duration,
                             level: min(Self.maximumLevel, Float(level)), isKick: isKick)
    }
}
