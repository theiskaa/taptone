import TaptoneCore

/// The private driver is undocumented. Keep one fixed-strength, bounded test per invocation.
struct LivePulseBudget {
    enum Decision { case send, stale, tooSoon, exhausted }

    static let maximumRequests = 20
    static let minimumSpacingNs: UInt64 = 250_000_000

    private(set) var count = 0
    private var lastCompletedAt: UInt64?

    func decision(beat: UInt64, now: UInt64) -> Decision {
        guard PulseTiming.isFresh(beat, at: now) else { return .stale }
        guard count < Self.maximumRequests else { return .exhausted }
        if let lastCompletedAt, now < lastCompletedAt || now - lastCompletedAt < Self.minimumSpacingNs {
            return .tooSoon
        }
        return .send
    }

    mutating func recordCompleted(at time: UInt64) {
        count += 1
        lastCompletedAt = time
    }
}
