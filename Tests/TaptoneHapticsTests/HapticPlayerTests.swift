import Foundation
import os
import TaptoneCore
import TaptoneHaptics
import Testing

@Suite struct HapticPlayerTests {
    private static let ms: UInt64 = 1_000_000

    @Test func playsEachCueWhenItsAudioIsHeardAndGoesQuietAfter() async throws {
        let clock = VirtualClock(startNs: 1_000 * Self.ms, running: false)
        let motor = FakeMotor(clock: clock)
        let latency = 150 * Self.ms
        let player = HapticPlayer(output: motor, latencyNs: latency, intensity: .medium,
                                  clock: clock.now, sleep: clock.sleep, onFailure: {})
        // Audio captured from 900 ms to 1,100 ms; heard from 1,050 ms to 1,250 ms.
        for step: UInt64 in 0...40 {
            player.append(HapticCue(timeNs: (900 + step * 5) * Self.ms, body: 0.6, pitchHz: 55,
                                    onset: step == 20 ? 1 : nil))
        }
        clock.run()
        // The last cue is heard at 1,250 ms and spent 50 ms later; then the player rests without polling,
        // so the virtual clock, which only moves when the player sleeps, stops there.
        try await motor.waitUntilClock(passes: 1_300 * Self.ms)
        #expect(player.stop())

        let played = motor.played
        let first = try #require(played.first)
        #expect((1_048 * Self.ms...1_056 * Self.ms).contains(first.time))
        let kick = try #require(played.first { $0.segment.isKick })
        #expect((1_148 * Self.ms...1_156 * Self.ms).contains(kick.time))
        let last = try #require(played.last)
        #expect(last.time < 1_250 * Self.ms + HapticTimeline.maximumCueAgeNs + 150 * Self.ms)
        // Back to back, never overlapping.
        for (previous, next) in zip(played, played.dropFirst()) {
            #expect(next.time >= previous.time + previous.segment.durationNs)
        }
        #expect(player.takeReading().kicks == 1)
        #expect(motor.closed)
    }

    /// With nothing to play, the thread waits instead of waking 100 times a second, and a kick still
    /// plays at once.
    @Test func restsWithoutPollingAndWakesForAKick() async throws {
        let clock = VirtualClock(startNs: 1_000 * Self.ms, running: true)
        let motor = FakeMotor(clock: clock)
        let player = HapticPlayer(output: motor, latencyNs: 0, intensity: .medium,
                                  clock: clock.now, sleep: clock.sleep, onFailure: {})
        try await Task.sleep(for: .milliseconds(100))
        // Polling would have slept, and so moved the clock, about ten times by now.
        #expect(clock.now() < 1_020 * Self.ms)
        #expect(motor.played.isEmpty)
        player.kick()
        for _ in 0..<500 where !motor.played.contains(where: { $0.segment.isKick }) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(motor.played.contains { $0.segment.isKick })
        #expect(player.stop())
        #expect(motor.closed)
    }

    @Test func failsClosedAfterRepeatedDriverErrors() async throws {
        let clock = VirtualClock(startNs: 1_000 * Self.ms)
        let motor = FakeMotor(clock: clock, accepts: false)
        let failed = OSAllocatedUnfairLock(initialState: false)
        let player = HapticPlayer(output: motor, latencyNs: 0, intensity: .light,
                                  clock: clock.now, sleep: clock.sleep, onFailure: { failed.withLock { $0 = true } })
        player.kick()
        for _ in 0..<200 where !motor.closed { try await Task.sleep(for: .milliseconds(5)) }
        #expect(motor.closed)
        #expect(failed.withLock { $0 })
        #expect(motor.played.count == 3)
        #expect(player.stop())
    }

    @Test func stopClosesTheMotorOnceAndPlaysNothingAfter() {
        let clock = VirtualClock(startNs: 0)
        let motor = FakeMotor(clock: clock)
        let player = HapticPlayer(output: motor, latencyNs: 0, intensity: .medium,
                                  clock: clock.now, sleep: clock.sleep, onFailure: {})
        #expect(player.stop())
        #expect(player.stop())
        let played = motor.played.count
        player.kick()
        player.append(HapticCue(timeNs: 0, body: 1))
        usleep(20_000)
        #expect(motor.closed)
        #expect(motor.played.count == played)
    }
}

/// Virtual host time that advances only when the player sleeps, and only once running.
private final class VirtualClock: Sendable {
    private let state: OSAllocatedUnfairLock<(time: UInt64, running: Bool)>

    init(startNs: UInt64, running: Bool = true) { state = OSAllocatedUnfairLock(initialState: (startNs, running)) }

    func run() { state.withLock { $0.running = true } }

    var now: HapticPlayer.Clock { { [state] in state.withLock { $0.time } } }

    var sleep: HapticPlayer.Sleep {
        { [state] deadline in
            while !state.withLock({ $0.running }) { usleep(100) }
            state.withLock { $0.time = max($0.time, deadline) }
            usleep(20) // Keep the virtual loop from monopolizing a core.
        }
    }
}

private final class FakeMotor: HapticOutput, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (played: [(time: UInt64, segment: HapticSegment)](), closed: false))
    private let clock: VirtualClock
    private let accepts: Bool

    init(clock: VirtualClock, accepts: Bool = true) {
        self.clock = clock
        self.accepts = accepts
    }

    var played: [(time: UInt64, segment: HapticSegment)] { state.withLock { $0.played } }
    var closed: Bool { state.withLock { $0.closed } }

    func play(_ segment: HapticSegment) -> Bool {
        let now = clock.now()
        state.withLock { $0.played.append((now, segment)) }
        return accepts
    }

    func close() -> Bool {
        state.withLock { $0.closed = true }
        return true
    }

    func waitUntilClock(passes deadline: UInt64) async throws {
        for _ in 0..<2_000 where clock.now() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(clock.now() >= deadline)
    }
}
