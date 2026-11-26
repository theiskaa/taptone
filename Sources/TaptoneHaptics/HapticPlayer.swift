import Foundation
import os
import TaptoneCore

/// Where rendered segments go. Called only from the player's thread, which also closes it.
public protocol HapticOutput: AnyObject {
    func play(_ segment: HapticSegment) -> Bool
    @discardableResult func close() -> Bool
}

/// Plays cues on its own timing thread, each when the audio it describes reaches the listener.
/// Starts on creation; feed it from any thread and call `stop` once.
public final class HapticPlayer: @unchecked Sendable {
    /// What the motor is doing, for display.
    public struct Reading: Sendable, Equatable {
        public var kicks = 0
        /// Host time of the last kick played.
        public var lastKickNs: UInt64?
        /// Command level of the segment playing now; zero while idle.
        public var level: Float = 0
        /// Highest command level since the last `takeReading()`.
        public var peakLevel: Float = 0
        /// Sustained bass intensity being followed (0...1), without kicks.
        public var body = 0.0
        public var carrierHz = HapticSynth.restingHz
        /// The bass note being followed, while there is one.
        public var pitchHz: Double?

        public init() {}
    }

    public typealias Clock = @Sendable () -> UInt64
    public typealias Sleep = @Sendable (_ untilNs: UInt64) -> Void

    private struct Shared {
        var timeline = HapticTimeline()
        var intensity: HapticIntensity
        var latencyNs: UInt64
        var manualKick: Double?
        var reading = Reading()
        var stopping = false
        /// The thread is waiting for work, so the next cue, kick, or stop should wake it.
        var waiting = false

        /// Clears `waiting`, returning whether the thread needs a signal.
        mutating func wakeIfWaiting() -> Bool {
            defer { waiting = false }
            return waiting
        }
    }

    /// Fail closed after this many consecutive driver refusals.
    static let failureLimit = 3
    /// While the motor rests between cues, how often to look for the next one: up to 10 ms late on a
    /// kick, well inside the timeline's lateness allowance.
    static let restingPollNs: UInt64 = 10_000_000
    /// With no cues at all (nothing playing), the thread waits to be woken instead of polling; this is
    /// only a backstop.
    static let idleWait = DispatchTimeInterval.seconds(1)

    private let shared: OSAllocatedUnfairLock<Shared>
    private let output: HapticOutput
    private let clock: Clock
    private let sleep: Sleep
    private let onFailure: @Sendable () -> Void
    private let finished = DispatchSemaphore(value: 0)
    private let wake = DispatchSemaphore(value: 0)

    /// `latencyNs` is how long after its capture timestamp the audio is heard.
    public init(output: HapticOutput, latencyNs: UInt64, intensity: HapticIntensity,
                clock: @escaping Clock = HostClock.nowNs, sleep: @escaping Sleep = HostClock.sleep(untilNs:),
                onFailure: @escaping @Sendable () -> Void) {
        self.output = output
        self.clock = clock
        self.sleep = sleep
        self.onFailure = onFailure
        shared = OSAllocatedUnfairLock(initialState: Shared(intensity: intensity, latencyNs: latencyNs))
        let thread = Thread { [self] in run() }
        thread.name = "com.theiskaa.taptone.haptics"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    public func append(_ cue: HapticCue) {
        if shared.withLock({ state in state.timeline.append(cue); return state.wakeIfWaiting() }) { wake.signal() }
    }

    public func setIntensity(_ intensity: HapticIntensity) { shared.withLock { $0.intensity = intensity } }

    public func setLatency(_ latencyNs: UInt64) { shared.withLock { $0.latencyNs = latencyNs } }

    /// Play a kick now, independent of audio.
    public func kick(strength: Double = 1) {
        let wakes = shared.withLock { state in
            state.manualKick = max(state.manualKick ?? 0, strength)
            return state.wakeIfWaiting()
        }
        if wakes { wake.signal() }
    }

    public func reading() -> Reading { shared.withLock { $0.reading } }

    /// The current reading, then restart its peak.
    public func takeReading() -> Reading {
        shared.withLock { state in
            defer { state.reading.peakLevel = 0 }
            return state.reading
        }
    }

    /// Ends the thread, which then closes the output. Returns false if a driver call outlived `timeout`.
    @discardableResult
    public func stop(timeout: DispatchTimeInterval = .milliseconds(250)) -> Bool {
        let (first, wakes) = shared.withLock { state in
            defer { state.stopping = true }
            return (!state.stopping, state.wakeIfWaiting())
        }
        if wakes { wake.signal() }
        return !first || finished.wait(timeout: .now() + timeout) == .success
    }

    private func run() {
        defer {
            output.close()
            finished.signal()
        }
        var synth = HapticSynth(intensity: shared.withLock { $0.intensity })
        var failures = 0
        var next = clock()
        while true {
            let now = clock()
            let step = shared.withLock { state -> (cue: HapticCue?, onset: Double?, intensity: HapticIntensity)? in
                guard !state.stopping else { return nil }
                let taken = state.timeline.take(at: now > state.latencyNs ? now - state.latencyNs : 0)
                defer { state.manualKick = nil }
                return (taken.cue, [taken.onset, state.manualKick].compactMap { $0 }.max(), state.intensity)
            }
            guard let step else { return }
            synth.intensity = step.intensity
            // After a scheduling hiccup, restart from now instead of bunching segments to catch up.
            if now > next &+ 5_000_000 { next = now }
            let segment = synth.next(at: now, cue: step.cue, onset: step.onset)
            let played = segment.map(output.play) ?? true
            let carrierHz = synth.carrierHz
            shared.withLock { state in
                state.reading.level = played ? segment?.level ?? 0 : 0
                state.reading.peakLevel = max(state.reading.peakLevel, state.reading.level)
                state.reading.body = step.cue?.body ?? 0
                state.reading.carrierHz = carrierHz
                // Hold the last note through a pitchless moment (a kick); clear it when the bass stops.
                state.reading.pitchHz = (step.cue?.body ?? 0) > 0 ? step.cue?.pitchHz ?? state.reading.pitchHz : nil
                if played, segment?.isKick == true, step.onset != nil {
                    state.reading.kicks += 1
                    state.reading.lastKickNs = now
                }
            }
            guard let segment else {
                // Nothing playing at all: wait to be woken rather than wake 100 times a second for hours.
                let idle = shared.withLock { state in
                    let heard = now > state.latencyNs ? now - state.latencyNs : 0
                    state.waiting = !state.stopping && state.manualKick == nil && state.timeline.isSpent(at: heard)
                    return state.waiting
                }
                if idle {
                    _ = wake.wait(timeout: .now() + Self.idleWait)
                    shared.withLock { $0.waiting = false }
                    next = clock()
                } else {
                    next = now &+ Self.restingPollNs
                    sleep(next)
                }
                continue
            }
            if played {
                failures = 0
            } else {
                failures += 1
                guard failures < Self.failureLimit else {
                    shared.withLock { $0.stopping = true }
                    onFailure()
                    return
                }
            }
            next = max(next, now) &+ segment.durationNs
            sleep(next)
        }
    }
}
