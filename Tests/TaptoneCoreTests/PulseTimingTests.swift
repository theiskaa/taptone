import TaptoneCore
import Testing

@Suite struct PulseTimingTests {
    @Test func ignoresStaleAndFarFutureRequests() {
        #expect(PulseTiming.isFresh(881_000_000, at: 1_000_000_000))
        #expect(!PulseTiming.isFresh(880_000_000, at: 1_000_000_000))
        #expect(PulseTiming.isFresh(1_024_000_000, at: 1_000_000_000))
        #expect(!PulseTiming.isFresh(1_025_000_000, at: 1_000_000_000))
    }

    @Test func preventsBurstsWithoutExpiringTheSession() {
        var limiter = TapRateLimiter()
        let cases: [(beatMS: UInt64, nowMS: UInt64, accepted: Bool)] = [
            (880, 1_000, false), // Too late; does not consume a tap slot.
            (1_000, 1_000, true),
            (1_139, 1_139, false), // Too soon after the last tap.
            (1_140, 1_140, true),
            (1_139, 1_139, false), // An out-of-order clock value is ignored.
            (61_000, 61_000, true), // Live tapping has no trial timer.
        ]
        for sample in cases {
            let accepted = limiter.accept(beat: sample.beatMS * 1_000_000, now: sample.nowMS * 1_000_000)
            #expect(accepted == sample.accepted, "Beat at \(sample.beatMS) ms, now \(sample.nowMS) ms")
        }
    }
}
