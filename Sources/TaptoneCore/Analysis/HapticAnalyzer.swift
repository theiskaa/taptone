import Foundation

/// One analysis step of the haptic voice, stamped in the Core Audio host clock of the captured audio.
public struct HapticCue: Sendable, Equatable {
    public let timeNs: UInt64
    /// Sustained bass intensity (0...1); zero when there's no bass.
    public let body: Double
    /// Stable bass fundamental, if one was found. Octave errors are harmless: the synth folds by octaves.
    public let pitchHz: Double?
    /// Strength (0...1) of a bass attack detected in this step.
    public let onset: Double?

    public init(timeNs: UInt64, body: Double, pitchHz: Double? = nil, onset: Double? = nil) {
        self.timeNs = timeNs
        self.body = body
        self.pitchHz = pitchHz
        self.onset = onset
    }
}

/// Turns stereo PCM into a haptic cue every 5 ms: bass body, bass pitch, and kick onsets.
/// Input is normalized first, so a quiet app feels like a loud one, unless `followsVolume` is set.
/// Push packets in order, and call `reset()` after a gap.
public struct HapticAnalyzer: Sendable {
    public static let hopSeconds = 0.005
    public let sampleRate: Double
    private var envelope: BassEnvelope
    private var detector: BeatDetector
    private var pitch: BassPitchTracker
    private var loudness: LoudnessNormalizer
    private var hopPower = 0.0
    private let hopSize: Int
    private let nsPerFrame: Double
    private var inHop = 0
    private var onset: Double?
    /// Hops to ignore beats for after a reset: a fresh detector reads any bass already playing as a hit.
    private var warmupHops = 0

    public init?(sampleRate: Double, sensitivity: BeatDetector.Sensitivity = .normal) {
        guard let envelope = BassEnvelope(sampleRate: sampleRate) else { return nil }
        self.sampleRate = sampleRate
        self.envelope = envelope
        detector = BeatDetector(sampleRate: sampleRate)
        detector.sensitivity = sensitivity
        pitch = BassPitchTracker(sampleRate: sampleRate)
        loudness = LoudnessNormalizer(windowSeconds: Self.hopSeconds)
        hopSize = max(1, Int((Self.hopSeconds * sampleRate).rounded()))
        nsPerFrame = 1_000_000_000 / sampleRate
    }

    /// Feel the level as heard: turning the volume down makes the haptics weaker too.
    public var followsVolume = false

    /// Starts the detectors over after a gap in the audio, keeping the loudness reference, so a glitch
    /// doesn't jump straight to full boost.
    public mutating func reset() {
        let sensitivity = detector.sensitivity
        envelope = BassEnvelope(sampleRate: sampleRate)!
        detector = BeatDetector(sampleRate: sampleRate)
        detector.sensitivity = sensitivity
        pitch = BassPitchTracker(sampleRate: sampleRate)
        hopPower = 0
        inHop = 0
        onset = nil
        warmupHops = Self.warmupHops
    }

    private static let warmupHops = 6 // 30 ms

    public var sensitivity: BeatDetector.Sensitivity {
        get { detector.sensitivity }
        set { detector.sensitivity = newValue }
    }

    /// `stereo` is interleaved left/right; `hostTimeNs` is the time of its first frame.
    public mutating func analyze(_ stereo: [Float], hostTimeNs: UInt64, emit: (HapticCue) -> Void) {
        for frame in 0..<(stereo.count / 2) {
            let rawLeft = Double(stereo[2 * frame].clampedSample)
            let rawRight = Double(stereo[2 * frame + 1].clampedSample)
            hopPower += (rawLeft * rawLeft + rawRight * rawRight) * 0.5
            let gain = followsVolume ? 1 : loudness.gain
            let left = Float(rawLeft * gain)
            let right = Float(rawRight * gain)
            envelope.push(left, right)
            pitch.push(Double(left + right) * 0.5)
            // A kick carries real bass: the envelope's bass-ratio gate rejects snare, hat, and melody attacks.
            if detector.push(left: left, right: right)?.isBeat == true, let weight = envelope.weight {
                // Quiet kicks still land; loud ones hit harder.
                onset = max(onset ?? 0, 0.55 + 0.45 * weight)
            }
            inHop += 1
            guard inHop >= hopSize else { continue }
            inHop = 0
            loudness.update(meanPower: hopPower / Double(hopSize))
            hopPower = 0
            let time = hostTimeNs &+ UInt64(Double(frame + 1) * nsPerFrame)
            if warmupHops > 0 {
                warmupHops -= 1
                onset = nil
            }
            emit(HapticCue(timeNs: time, body: envelope.weight ?? 0, pitchHz: pitch.hertz, onset: onset))
            onset = nil
        }
    }
}
