import Foundation

/// RBJ second-order section in transposed direct form II. Shared by the causal bass analyzers.
struct Biquad: Sendable {
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
        // After a signal fades to digital silence the state decays into subnormal numbers, which are
        // very slow on Intel. Nothing that small is audible.
        if abs(z1) < 1e-20 { z1 = 0 }
        if abs(z2) < 1e-20 { z2 = 0 }
        return result
    }
}
