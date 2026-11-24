import Foundation

/// Causal bass pitch from the period between upward zero crossings of a low-passed signal.
/// Reports a pitch only once three consecutive periods agree, so kicks and noise read as "no pitch".
struct BassPitchTracker: Sendable {
    private let sampleRate: Double
    private var high: Biquad
    private var lowA: Biquad
    private var lowB: Biquad
    private let powerStep: Double
    private let shortestPeriod: Double
    private let longestPeriod: Double
    private var power = 0.0
    private var previous = 0.0
    private var armed = false
    private var sinceCrossing = 0.0
    private var hasCrossing = false
    private var periods: [Double] = []

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        high = Biquad(rate: sampleRate, frequency: 35, q: 1 / sqrt(2), highPass: true)
        lowA = Biquad(rate: sampleRate, frequency: 180, q: 0.5411961)
        lowB = Biquad(rate: sampleRate, frequency: 180, q: 1.306563)
        powerStep = 1 - exp(-1 / (sampleRate * 0.020))
        shortestPeriod = sampleRate / 320
        longestPeriod = sampleRate / 35
        periods.reserveCapacity(3)
    }

    var hertz: Double? {
        guard periods.count == 3 else { return nil }
        let sorted = periods.sorted()
        guard (sorted[2] - sorted[0]) / sorted[1] <= 0.08 else { return nil }
        return sampleRate / sorted[1]
    }

    mutating func push(_ sample: Double) {
        let value = lowB.push(lowA.push(high.push(sample)))
        power += powerStep * (value * value - power)
        sinceCrossing += 1
        defer { previous = value }
        let rms = sqrt(power)
        guard rms >= 0.002 else {
            clear()
            return
        }
        if sinceCrossing > longestPeriod * 1.2 { periods.removeAll(keepingCapacity: true) }
        if value < -0.3 * rms { armed = true }
        guard armed, previous < 0, value >= 0 else { return }
        armed = false
        // Interpolate the crossing inside this sample interval.
        let crossing = sinceCrossing - 1 + previous / (previous - value)
        sinceCrossing -= crossing
        if hasCrossing, (shortestPeriod...longestPeriod).contains(crossing) {
            if periods.count == 3 { periods.removeFirst() }
            periods.append(crossing)
        } else if hasCrossing {
            periods.removeAll(keepingCapacity: true)
        }
        hasCrossing = true
    }

    private mutating func clear() {
        armed = false
        hasCrossing = false
        periods.removeAll(keepingCapacity: true)
    }
}
