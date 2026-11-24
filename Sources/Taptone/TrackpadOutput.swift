import AppKit
import os
import TaptoneAudio
import TaptoneCore
import TaptoneHaptics

/// What the trackpad does for one session: the motor voice when the actuator opens,
/// otherwise a fixed AppKit tap on each kick. Create one per session and stop it once.
@MainActor
final class TrackpadOutput {
    let device: OutputDevice?
    private let voice: MotorVoice?
    private var taps = TapRateLimiter()

    init(settings: Settings, onFailure: @escaping @Sendable () -> Void) {
        device = OutputDevice.current()
        voice = MotorVoice(intensity: settings.intensity, onFailure: onFailure)
        apply(settings)
    }

    var usesMotor: Bool { voice != nil }

    /// The motor analyzes PCM itself; AppKit taps only need beat events.
    var consumePCM: CaptureEngine.ConsumePCM? {
        guard let voice else { return nil }
        return { voice.consume($0) }
    }

    func apply(_ settings: Settings) {
        guard let voice else { return }
        voice.player.setIntensity(settings.intensity)
        voice.configure(sensitivity: settings.sensitivity, followsVolume: settings.followsVolume)
        let delay = Int64(device?.latencyNs ?? 0) + Int64(settings.syncOffsetMs) * 1_000_000
        voice.player.setLatency(UInt64(max(0, delay)))
    }

    /// The motor's live state, for display. Nil for AppKit taps.
    func reading() -> HapticPlayer.Reading? { voice?.player.reading() }

    /// Call on each capture update: kicks played since the last call, and the motor's peak level.
    func update(beat: UInt64?, now: UInt64) -> (kicks: Int, motorLevel: Float) {
        guard let voice else {
            guard let beat, taps.accept(beat: beat, now: now) else { return (0, 0) }
            Self.tap()
            return (1, 0)
        }
        let reading = voice.player.takeReading()
        defer { reportedKicks = reading.kicks }
        return (reading.kicks - reportedKicks, reading.peakLevel)
    }

    /// One kick now, without audio.
    func kick() {
        if let voice { voice.player.kick() } else { Self.tap() }
    }

    func stop() { voice?.player.stop() }

    private var reportedKicks = 0

    private static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }
}

/// Analysis on the capture worker, playback on the player's thread.
private final class MotorVoice: Sendable {
    let player: HapticPlayer
    private let state = OSAllocatedUnfairLock<(analyzer: HapticAnalyzer?, sensitivity: BeatDetector.Sensitivity,
                                               followsVolume: Bool)>(initialState: (nil, .normal, false))

    init?(intensity: HapticIntensity, onFailure: @escaping @Sendable () -> Void) {
        guard let actuator = TrackpadActuator.open() else { return nil }
        player = HapticPlayer(output: actuator, latencyNs: 0, intensity: intensity, onFailure: onFailure)
    }

    func consume(_ packet: CapturePCM) {
        let cues = state.withLock { state -> [HapticCue] in
            if state.analyzer?.sampleRate != packet.sampleRate {
                state.analyzer = HapticAnalyzer(sampleRate: packet.sampleRate, sensitivity: state.sensitivity)
                state.analyzer?.followsVolume = state.followsVolume
            } else if packet.discontinuity {
                state.analyzer?.reset()
            }
            var cues: [HapticCue] = []
            state.analyzer?.analyze(packet.stereo, hostTimeNs: packet.hostTimeNs) { cues.append($0) }
            return cues
        }
        cues.forEach(player.append)
    }

    func configure(sensitivity: BeatDetector.Sensitivity, followsVolume: Bool) {
        state.withLock { state in
            state.sensitivity = sensitivity
            state.followsVolume = followsVolume
            state.analyzer?.sensitivity = sensitivity
            state.analyzer?.followsVolume = followsVolume
        }
    }
}
