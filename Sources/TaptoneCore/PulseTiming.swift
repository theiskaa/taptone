/// Time checks shared by the capture worker and UI. All values are Core Audio host nanoseconds.
public enum PulseTiming {
    public static let maximumAge: UInt64 = 120_000_000
    private static let futureTolerance: UInt64 = 25_000_000

    public static func isFresh(_ time: UInt64, at now: UInt64) -> Bool {
        if time > now { return time - now < futureTolerance }
        return now - time < maximumAge
    }
}

/// A fresh instance per listening session prevents bursts if queued cues arrive together.
public struct TapRateLimiter {
    private var lastRequest: UInt64?
    private static let minimumSpacing: UInt64 = 140_000_000

    public init() {}

    public mutating func accept(beat: UInt64, now: UInt64) -> Bool {
        guard PulseTiming.isFresh(beat, at: now) else { return false }
        if let lastRequest, now < lastRequest || now - lastRequest < Self.minimumSpacing { return false }
        lastRequest = now
        return true
    }
}
