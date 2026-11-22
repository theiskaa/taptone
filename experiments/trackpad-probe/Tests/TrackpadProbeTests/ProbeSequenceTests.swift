@testable import TaptoneTrackpadProbe
import Testing

@Suite struct ProbeSequenceTests {
    @Test func onlyExplicitOptionsSelectActuation() throws {
        #expect(try ProbeMode(arguments: []) == .dryRun)
        #expect(try ProbeMode(arguments: ["--dry-run"]) == .dryRun)
        #expect(try ProbeMode(arguments: ["--check"]) == .check)
        #expect(try ProbeMode(arguments: ["-h"]) == .help)
        #expect(try ProbeMode(arguments: ["--run"]) == .run)
        #expect(try ProbeMode(arguments: ["--live"]) == .live)
        #expect(throws: ProbeError.self) { try ProbeMode(arguments: ["--live", "--run"]) }
        #expect(throws: ProbeError.self) { try ProbeMode(arguments: ["--run", "--check"]) }
        #expect(throws: ProbeError.self) { try ProbeMode(arguments: ["--strength", "1"]) }
    }

    @Test func requestsTwoGentleAndTwoFirmerPulsesAtOneSecondIntervals() throws {
        var elapsed = 0.0
        var times: [Double] = []
        var strengths: [ProbeSequence.Strength] = []
        try ProbeSequence.run(wait: { elapsed += $0 }, check: {}) { strength in
            times.append(elapsed)
            strengths.append(strength)
        }
        #expect(times == [2, 3, 4, 5])
        #expect(strengths == [.gentle, .gentle, .firmer, .firmer])
        #expect(abs(elapsed - 5.020) < 0.0001)
        #expect(ProbeSequence.durationMs == 20)
        #expect(ProbeSequence.frequencyHz == 200)
        #expect(strengths.map(\.level) == [0.20, 0.20, 0.40, 0.40])
    }

    @Test func cancelBeforeRequestStopsTheRestOfTheSequence() {
        var count = 0
        #expect(throws: ProbeError.self) {
            try ProbeSequence.run(wait: { _ in }, check: {
                if count == 1 { throw ProbeError(message: "cancelled") }
            }, request: { _ in count += 1 })
        }
        #expect(count == 1)
    }

    @Test func aFailedRequestDoesNotRetryOrAdvance() {
        var attempted: [ProbeSequence.Strength] = []
        #expect(throws: ProbeError.self) {
            try ProbeSequence.run(wait: { _ in }, check: {}) { strength in
                attempted.append(strength)
                if strength == .firmer { throw ProbeError(message: "driver error") }
            }
        }
        #expect(attempted == [.gentle, .gentle, .firmer])
    }
}
