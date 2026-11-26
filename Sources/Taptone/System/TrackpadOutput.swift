import AppKit
import CoreGraphics
import os
import TaptoneAudio
import TaptoneCore
import TaptoneHaptics

/// What the trackpad does for one session: the motor voice when the actuator opens, otherwise a fixed
/// AppKit tap on each kick, or nothing when there's no Force Touch trackpad. Create one per session
/// and stop it once.
@MainActor
final class TrackpadOutput {
    enum Mode { case motor, taps, none }

    let device: OutputDevice?
    let mode: Mode
    private let voice: MotorVoice?
    private var taps = TapRateLimiter()
    private var isMuted = false
    /// The player's kick count at the last `update`.
    private var reportedKicks = 0

    init(settings: Settings, surroundings: AudioSurroundings.State, onFailure: @escaping @Sendable () -> Void) {
        device = OutputDevice.current()
        voice = MotorVoice(intensity: settings.intensity, preferExternal: Self.lidIsClosed, onFailure: onFailure)
        // The motor's symbols loaded but no actuator opened: there's no Force Touch trackpad. Without the
        // symbols, as on a future macOS that drops them, AppKit taps still reach one.
        mode = voice != nil ? .motor : TrackpadActuator.isSupported ? .none : .taps
        apply(settings)
        follow(surroundings)
    }

    var usesMotor: Bool { mode == .motor }

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

    /// Mute silences the trackpad; with Follow volume, the volume scales what the motor hears.
    func follow(_ surroundings: AudioSurroundings.State) {
        isMuted = surroundings.isMuted
        voice?.setOutput(gain: surroundings.outputGain)
    }

    /// The motor's live state, for display. Nil for AppKit taps.
    func reading() -> HapticPlayer.Reading? { voice?.player.reading() }

    /// Call on each capture update: kicks played since the last call, and the motor's peak level.
    func update(beat: UInt64?, now: UInt64) -> (kicks: Int, motorLevel: Float) {
        guard let voice else {
            guard mode == .taps, !isMuted, let beat, taps.accept(beat: beat, now: now) else { return (0, 0) }
            Self.tap()
            return (1, 0)
        }
        let reading = voice.player.takeReading()
        defer { reportedKicks = reading.kicks }
        return (reading.kicks - reportedKicks, reading.peakLevel)
    }

    /// One kick now, without audio.
    func kick() {
        if let voice { voice.player.kick() } else if mode == .taps { Self.tap() }
    }

    func stop() { voice?.player.stop() }

    private static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    /// No built-in display is on: a closed MacBook, where an external trackpad is the one in use.
    private static var lidIsClosed: Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return false }
        return !displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) != 0 }
    }
}

/// Analysis on the capture worker, playback on the player's thread.
private final class MotorVoice: Sendable {
    let player: HapticPlayer
    private struct Tuning {
        var sensitivity = BeatDetector.Sensitivity.normal
        var followsVolume = false
        /// What the output volume leaves of the signal; 0 while muted.
        var outputGain: Float = 1
    }
    /// Set from the main thread, read once per packet; the analysis itself runs outside the lock.
    private let tuning = OSAllocatedUnfairLock(initialState: Tuning())
    /// Only touched from `consume`, which the capture worker calls one packet at a time.
    private nonisolated(unsafe) var analyzer: HapticAnalyzer?

    init?(intensity: HapticIntensity, preferExternal: Bool, onFailure: @escaping @Sendable () -> Void) {
        guard let actuator = TrackpadActuator.open(preferExternal: preferExternal) else { return nil }
        player = HapticPlayer(output: actuator, latencyNs: 0, intensity: intensity, onFailure: onFailure)
    }

    /// A backstop: the player's thread keeps running, with the actuator open, until it's stopped. The
    /// app always stops it first, which makes this a no-op.
    deinit { player.stop() }

    func consume(_ packet: CapturePCM) {
        let current = tuning.withLock { $0 }
        if analyzer?.sampleRate != packet.sampleRate {
            analyzer = HapticAnalyzer(sampleRate: packet.sampleRate, sensitivity: current.sensitivity)
        } else if packet.discontinuity {
            analyzer?.reset()
        }
        // Mutated in place: a copy would duplicate the analyzer's buffers on every packet.
        if analyzer?.sensitivity != current.sensitivity { analyzer?.sensitivity = current.sensitivity }
        analyzer?.followsVolume = current.followsVolume
        // The tap hears apps before the output volume applies, so apply it here when following it.
        let gain = current.followsVolume ? current.outputGain : 1
        let stereo = gain == 1 ? packet.stereo : packet.stereo.map { $0 * gain }
        var cues: [HapticCue] = []
        analyzer?.analyze(stereo, hostTimeNs: packet.hostTimeNs) { cues.append($0) }
        // Muted: keep analyzing, so unmuting picks up mid-song, but play nothing.
        if current.outputGain > 0 { cues.forEach(player.append) }
    }

    func configure(sensitivity: BeatDetector.Sensitivity, followsVolume: Bool) {
        tuning.withLock { tuning in
            tuning.sensitivity = sensitivity
            tuning.followsVolume = followsVolume
        }
    }

    func setOutput(gain: Float) {
        tuning.withLock { $0.outputGain = gain }
    }
}
