import Foundation

/// Causal estimate of bass intensity, independent of the playback device or the beat detector.
/// Push normalized stereo PCM in order. Start a new envelope after a discontinuity.
public struct BassEnvelope: Sendable {
    private var left: Channel
    private var right: Channel
    private var bassPower = 0.0
    private var fullPower = 0.0
    private let attack: Double
    private let release: Double
    private let referenceRelease: Double

    public init?(sampleRate: Double) {
        guard (8_000...384_000).contains(sampleRate) else { return nil }
        left = Channel(rate: sampleRate)
        right = left
        attack = 1 - exp(-1 / (sampleRate * 0.004))
        release = 1 - exp(-1 / (sampleRate * 0.0055))
        referenceRelease = 1 - exp(-1 / (sampleRate * 0.015))
    }

    public mutating func push(_ left: Float, _ right: Float) {
        let l = Double(left.clampedSample)
        let r = Double(right.clampedSample)
        let a = self.left.push(l)
        let b = self.right.push(r)
        // Average power rather than samples so anti-phase lows still register.
        let bass = (a * a + b * b) * 0.5
        bassPower += (bass > bassPower ? attack : release) * (bass - bassPower)
        let full = (l * l + r * r) * 0.5
        // Keep the broadband reference through a short filter tail so a midrange release
        // cannot accidentally look like bass just because the raw input has gone quiet.
        fullPower += (full > fullPower ? attack : referenceRelease) * (full - fullPower)
    }

    /// Normalized bass intensity (0...1), or nil below the level and bass-ratio gates.
    public var weight: Double? {
        // A loud upper-band attack can briefly excite the low-pass filter without a bass note.
        guard bassPower >= 0.01 * fullPower else { return nil }
        let db = 10 * log10(max(1e-12, bassPower))
        guard db >= -49 else { return nil }
        // Keep quiet recordings responsive and leave room above −12 dBFS for loud accents.
        if db < -42 { return 0.04 * (db + 49) / 7 }
        if db < -12 { return 0.04 + 0.86 * (db + 42) / 30 }
        return min(1, 0.90 + 0.10 * (db + 12) / 12)
    }

    private struct Channel: Sendable {
        var high: Biquad
        var lowA: Biquad
        var lowB: Biquad
        var lowC: Biquad
        var lowD: Biquad

        init(rate: Double) {
            high = Biquad(rate: rate, frequency: 38, q: 1 / sqrt(2), highPass: true)
            // Eighth-order Butterworth: keep bass notes without tracking the 220–260 Hz midrange.
            lowA = Biquad(rate: rate, frequency: 150, q: 0.50979558)
            lowB = Biquad(rate: rate, frequency: 150, q: 0.60134489)
            lowC = Biquad(rate: rate, frequency: 150, q: 0.89997622)
            lowD = Biquad(rate: rate, frequency: 150, q: 2.56291545)
        }

        mutating func push(_ sample: Double) -> Double {
            lowD.push(lowC.push(lowB.push(lowA.push(high.push(sample)))))
        }
    }
}
