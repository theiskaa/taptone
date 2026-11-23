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

    public init?(sampleRate: Double) {
        guard (8_000...384_000).contains(sampleRate) else { return nil }
        left = Channel(rate: sampleRate)
        right = left
        attack = 1 - exp(-1 / (sampleRate * 0.004))
        release = 1 - exp(-1 / (sampleRate * 0.007))
    }

    public mutating func push(_ left: Float, _ right: Float) {
        let l = Self.normalized(left)
        let r = Self.normalized(right)
        let a = self.left.push(l)
        let b = self.right.push(r)
        // Average power rather than samples so anti-phase lows still register.
        let bass = (a * a + b * b) * 0.5
        bassPower += (bass > bassPower ? attack : release) * (bass - bassPower)
        let full = (l * l + r * r) * 0.5
        fullPower += (full > fullPower ? attack : release) * (full - fullPower)
    }

    /// Normalized intensity (0...1) for bass between −42 and −12 dBFS, or nil below the gate.
    public var weight: Double? {
        // A loud upper-band attack can briefly excite the low-pass filter without a bass note.
        guard bassPower >= 0.01 * fullPower else { return nil }
        let db = 10 * log10(max(1e-12, bassPower))
        guard db >= -42 else { return nil }
        return min(1, (db + 42) / 30)
    }

    private static func normalized(_ sample: Float) -> Double {
        sample.isFinite ? Double(min(1, max(-1, sample))) : 0
    }

    private struct Channel: Sendable {
        var high: Biquad
        var lowA: Biquad
        var lowB: Biquad

        init(rate: Double) {
            high = Biquad(rate: rate, frequency: 38, q: 1 / sqrt(2), highPass: true)
            // Fourth-order Butterworth low pass keeps loud midrange out of the bass envelope.
            lowA = Biquad(rate: rate, frequency: 165, q: 0.5411961)
            lowB = Biquad(rate: rate, frequency: 165, q: 1.306563)
        }

        mutating func push(_ sample: Double) -> Double {
            lowB.push(lowA.push(high.push(sample)))
        }
    }

    private struct Biquad: Sendable {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1 = 0.0, z2 = 0.0

        init(rate: Double, frequency: Double, q: Double, highPass: Bool = false) {
            let angle = 2 * Double.pi * frequency / rate
            let cosine = cos(angle)
            let alpha = sin(angle) / (2 * q)
            b0 = (highPass ? 1 + cosine : 1 - cosine) / (2 * (1 + alpha))
            b1 = (highPass ? -2 : 2) * b0
            b2 = b0
            a1 = -2 * cosine / (1 + alpha)
            a2 = (1 - alpha) / (1 + alpha)
        }

        mutating func push(_ sample: Double) -> Double {
            let result = b0 * sample + z1
            z1 = b1 * sample - a1 * result + z2
            z2 = b2 * sample - a2 * result
            return result
        }
    }
}
