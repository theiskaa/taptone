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
/// Speech is held back (syllables drop its low harmonics out together with the rest of the voice), plucked
/// notes that show a steady pitch at once land softer than kicks, and bass that holds without changing slowly
/// fades so a drone doesn't wear on you.
/// Push packets in order, and call `reset()` after a gap.
public struct HapticAnalyzer: Sendable {
    public static let hopSeconds = 0.005
    /// Weakest onset worth playing, after weighting by how much of the attack is kick-band bass.
    static let minimumOnset = 0.15
    /// A plucked note plays at this fraction of a kick of the same strength.
    static let pluckScale = 0.4

    public let sampleRate: Double
    private var envelope: BassEnvelope
    private var detector: BeatDetector
    private var pitch: BassPitchTracker
    private var loudness: LoudnessNormalizer
    private var voice: VoiceGate
    private var habituation = Habituation()
    private var hopPower = 0.0
    private let hopSize: Int
    private let nsPerFrame: Double
    private let attackFrames: Int
    private let holdFrames: Int
    private let smoothStep: Double
    private var smoothBass = 0.0
    private var hopBass = 0.0
    private var hopDeep = 0.0
    private var hopFull = 0.0
    private var deepA: Biquad
    private var deepB: Biquad
    /// The voice gate's latest weight, for attacks decided between hops.
    private var speech = 1.0
    private var inHop = 0
    private var onset: Double?
    private var pending: PendingOnset?
    /// An attack that has been decided, waiting for the next cue: its bass weight then and its scale.
    private var decided: (weight: Double, scale: Double)?
    /// Hops to ignore beats for at the start and after a reset: a fresh detector reads any bass
    /// already playing as a hit.
    private var warmupHops = HapticAnalyzer.warmupHops

    public init?(sampleRate: Double, sensitivity: BeatDetector.Sensitivity = .normal) {
        guard let envelope = BassEnvelope(sampleRate: sampleRate) else { return nil }
        self.sampleRate = sampleRate
        self.envelope = envelope
        detector = BeatDetector(sampleRate: sampleRate)
        detector.sensitivity = sensitivity
        pitch = BassPitchTracker(sampleRate: sampleRate)
        loudness = LoudnessNormalizer(windowSeconds: Self.hopSeconds)
        voice = VoiceGate(hopSeconds: Self.hopSeconds)
        hopSize = max(1, Int((Self.hopSeconds * sampleRate).rounded()))
        nsPerFrame = 1_000_000_000 / sampleRate
        attackFrames = Int(0.020 * sampleRate)
        holdFrames = Int(0.025 * sampleRate)
        smoothStep = 1 - exp(-1 / (sampleRate * 0.008))
        deepA = Biquad(rate: sampleRate, frequency: 65, q: 0.5411961)
        deepB = Biquad(rate: sampleRate, frequency: 65, q: 1.306563)
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
        voice = VoiceGate(hopSeconds: Self.hopSeconds)
        habituation = Habituation()
        hopPower = 0
        smoothBass = 0
        hopBass = 0
        hopDeep = 0
        hopFull = 0
        speech = 1
        deepA = Biquad(rate: sampleRate, frequency: 65, q: 0.5411961)
        deepB = Biquad(rate: sampleRate, frequency: 65, q: 1.306563)
        inHop = 0
        onset = nil
        pending = nil
        decided = nil
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
            if !followsVolume { loudness.limit(sample: max(abs(rawLeft), abs(rawRight))) }
            let gain = followsVolume ? 1 : loudness.gain
            let left = Float(rawLeft * gain)
            let right = Float(rawRight * gain)
            envelope.push(left, right)
            pitch.push(Double(left + right) * 0.5)
            smoothBass += (envelope.bassLevel - smoothBass) * smoothStep
            hopBass += envelope.instantBass
            let deep = deepB.push(deepA.push(Double(left + right) * 0.5))
            hopDeep += deep * deep
            hopFull += Double(left * left + right * right) * 0.5
            // A kick carries real bass: the detector's band share and the envelope's bass-ratio gate reject
            // snare, hat, and melody attacks.
            if let reading = detector.push(left: left, right: right), reading.isBeat, pending == nil,
               let weight = envelope.weight {
                pending = PendingOnset(weight: weight, share: Double(reading.bassShare),
                                       startFrame: pitch.frame - attackFrames,
                                       deadline: pitch.frame + holdFrames, peak: smoothBass)
                decide()
            }
            if let held = pending, smoothBass > held.peak { pending?.peak = smoothBass }
            inHop += 1
            guard inHop >= hopSize else { continue }
            inHop = 0
            loudness.update(meanPower: hopPower / Double(hopSize))
            hopPower = 0
            let time = hostTimeNs &+ UInt64(Double(frame + 1) * nsPerFrame)
            speech = voice.update(bass: hopBass / Double(hopSize), deep: hopDeep / Double(hopSize),
                                  full: hopFull / Double(hopSize))
            hopBass = 0
            hopDeep = 0
            hopFull = 0
            if pending != nil { decide() }
            land()
            if warmupHops > 0 {
                warmupHops -= 1
                onset = nil
                pending = nil
            }
            let weight = (envelope.weight ?? 0) * speech
            let fade = habituation.update(weight: weight, pitchHz: pitch.hertz, onset: onset != nil,
                                          seconds: Self.hopSeconds)
            emit(HapticCue(timeNs: time, body: weight * fade, pitchHz: pitch.hertz, onset: onset))
            onset = nil
        }
    }

    /// Plays the held attack as a kick or a softer pluck once that's clear; it rides on the next cue.
    private mutating func decide() {
        guard let held = pending else { return }
        let scale: Double
        switch classify(held) {
        case .wait: return
        case .kick: scale = 1
        case .pluck: scale = Self.pluckScale
        }
        pending = nil
        let attack = (weight: held.weight, scale: Self.dominance(held.share) * scale)
        if attack.scale > decided?.scale ?? 0 { decided = attack }
    }

    /// The decided attack's strength, from the bass level now: the envelope lags the attack that set it off.
    private mutating func land() {
        guard let attack = decided else { return }
        decided = nil
        let weight = max(attack.weight, envelope.weight ?? 0)
        let strength = (0.35 + 0.65 * weight) * attack.scale * speech
        guard strength >= Self.minimumOnset else { return }
        onset = max(onset ?? 0, min(1, strength))
    }

    /// How much of an attack's window is kick-band bass, as a weight. A kick's first window holds only
    /// part of it (its attack starts above the band); a snare or a chime holds almost none.
    static func dominance(_ share: Double) -> Double { min(1, max(0, (share - 0.04) / 0.14)) }

    private enum Attack { case wait, kick, pluck }

    /// A kick dives in pitch or dies away; a plucked note settles on a steady pitch and keeps ringing.
    /// Only an attack already showing two matching periods waits (up to `holdFrames`) for a third, so kicks
    /// and low notes, which can't show a pitch that fast, play at once.
    private func classify(_ held: PendingOnset) -> Attack {
        let periods = pitch.recent.filter { $0.frame - Int($0.period) >= held.startFrame }.map(\.period)
        if zip(periods, periods.dropFirst()).contains(where: { $1 > $0 * 1.10 }) { return .kick }
        if smoothBass < held.peak * 0.5 { return .kick }
        func agree(_ last: [Double]) -> Bool {
            let sorted = last.sorted()
            return (sorted[sorted.count - 1] - sorted[0]) / sorted[sorted.count / 2] <= 0.08
        }
        if periods.count >= 3, agree(Array(periods.suffix(3))) { return .pluck }
        if periods.count >= 2, agree(Array(periods.suffix(2))), pitch.frame < held.deadline { return .wait }
        return .kick
    }
}

/// An attack waiting up to `deadline` for the pitch tracker to say whether it was a kick or a note.
private struct PendingOnset: Sendable {
    /// Bass weight when it was detected.
    let weight: Double
    /// Share of kick-band power in the window that triggered it.
    let share: Double
    /// Where the attack's window began; only periods after it describe the attack.
    let startFrame: Int
    let deadline: Int
    var peak: Double
}

/// Recognizes speech by its rhythm: syllables make the low harmonics and the rest of the voice drop out
/// together several times a second, while the low end carries under about half the power and almost nothing
/// below 65 Hz, where voices don't reach. A note starting out of silence, bass under an independent melody,
/// bass that dominates the mix, or bass with real depth passes untouched.
struct VoiceGate: Sendable {
    private let smoothStep: Double
    private let shareStep: Double
    private let peakRelease: Double
    private let dipDecay: Double
    private var bass = 0.0
    private var rest = 0.0
    /// Slow power averages, so each ratio is weighted by loudness rather than skewed by filter tails.
    private var slowBass = 0.0
    private var slowDeep = 0.0
    private var slowFull = 0.0
    private var peakBass = -100.0
    private var peakRest = -100.0
    private var armed = false
    /// Shared drop-outs, decaying over about two seconds, so a breath between sentences doesn't reset it.
    private var dips = 0.0

    /// Both levels this far under their recent peaks at once count as a shared drop-out.
    static let dipDB = 12.0
    /// Both must come back within this of their peaks before the next one counts.
    static let returnDB = 6.0

    init(hopSeconds: Double) {
        smoothStep = 1 - exp(-hopSeconds / 0.020)
        shareStep = 1 - exp(-hopSeconds / 0.150)
        peakRelease = 30 * hopSeconds
        dipDecay = exp(-hopSeconds / 2.0)
    }

    /// Feed one hop's mean power below 150 Hz, below 65 Hz, and in all. Returns the weight to keep (0...1):
    /// near 0 for speech.
    mutating func update(bass bassPower: Double, deep deepPower: Double, full fullPower: Double) -> Double {
        bass += (bassPower - bass) * smoothStep
        rest += (max(0, fullPower - bassPower) - rest) * smoothStep
        slowBass += (bassPower - slowBass) * shareStep
        slowDeep += (deepPower - slowDeep) * shareStep
        slowFull += (fullPower - slowFull) * shareStep
        let x = 10 * log10(max(bass, 1e-7))
        let y = 10 * log10(max(rest, 1e-7))
        peakBass = max(x, peakBass - peakRelease)
        peakRest = max(y, peakRest - peakRelease)
        if x > peakBass - Self.returnDB, y > peakRest - Self.returnDB { armed = true }
        dips *= dipDecay
        if armed, x < peakBass - Self.dipDB, y < peakRest - Self.dipDB {
            dips += 1
            armed = false
        }
        let together = min(1, max(0, (dips - 1) / 2))
        guard together > 0 else { return 1 }
        let share = slowFull > 0 ? slowBass / slowFull : 1
        let depth = slowBass > 0 ? slowDeep / slowBass : 1
        let bassHeavy = min(1, max(0, (share - 0.45) / 0.15))
        let deep = min(1, max(0, (depth - 0.20) / 0.30))
        return 1 - together * (1 - max(bassHeavy, deep))
    }
}

/// Lets a held, unchanging bass fade: after `holdSeconds` it drifts to `settleFactor`, and after
/// `fadeAfterSeconds` with still nothing new it fades out, like a hum. A new attack, a new note, or a clear
/// change of level brings it straight back.
struct Habituation: Sendable {
    static let holdSeconds = 1.5
    static let settleFactor = 0.4
    static let settleSeconds = 0.8
    static let fadeAfterSeconds = 6.0
    static let fadeSeconds = 1.5
    /// A rise of level, in body weight (about 5 dB), that counts as something new.
    static let levelChange = 0.15
    /// A pitch change (in octaves, after folding octave errors) that counts as a new note: about a semitone.
    static let pitchChange = 0.07

    private var steady = 0.0
    private var smoothed = 0.0
    private var reference = 0.0
    private var heldPitch: Double?
    private var candidate: (hertz: Double, seconds: Double)?
    /// How much of the last ~200 ms had a pitch: noise only locks now and then, and its slips aren't notes.
    private var pitched = 0.0
    private var risingSeconds = 0.0

    /// Returns the factor (0...1) to scale this hop's body by.
    mutating func update(weight: Double, pitchHz: Double?, onset: Bool, seconds: Double) -> Double {
        guard weight >= HapticSynth.bodyGate else {
            self = Habituation()
            return 1
        }
        smoothed += (weight - smoothed) * (1 - exp(-seconds / 0.060))
        reference += (smoothed - reference) * (1 - exp(-seconds / 1.0))
        // Only a rise that lasts is news: a held note's own decay, or a rumble's flickers, aren't.
        risingSeconds = smoothed > reference + Self.levelChange ? risingSeconds + seconds : 0
        var changed = onset || risingSeconds >= 0.040
        pitched += ((pitchHz == nil ? 0 : 1) - pitched) * (1 - exp(-seconds / 0.200))
        if let pitchHz, pitchHz > 0, pitched > 0.5 {
            if let held = heldPitch, Self.octaves(pitchHz, from: held) > Self.pitchChange {
                if let current = candidate, Self.octaves(pitchHz, from: current.hertz) < Self.pitchChange / 2 {
                    candidate = (current.hertz, current.seconds + seconds)
                } else {
                    candidate = (pitchHz, seconds)
                }
                // A new note must hold for 30 ms, so a tracker slip in noise isn't news.
                if let current = candidate, current.seconds >= 0.030 {
                    changed = true
                    heldPitch = current.hertz
                    candidate = nil
                }
            } else {
                candidate = nil
                if heldPitch == nil { heldPitch = pitchHz }
            }
        }
        if changed {
            steady = 0
            reference = smoothed
        } else {
            steady += seconds
        }
        return Self.factor(afterSteady: steady)
    }

    static func factor(afterSteady seconds: Double) -> Double {
        guard seconds > holdSeconds else { return 1 }
        let settled = settleFactor + (1 - settleFactor) * exp(-(seconds - holdSeconds) / settleSeconds)
        guard seconds > fadeAfterSeconds else { return settled }
        return settled * exp(-(seconds - fadeAfterSeconds) / fadeSeconds)
    }

    private static func octaves(_ hertz: Double, from reference: Double) -> Double {
        let distance = log2(hertz / reference)
        return abs(distance - distance.rounded())
    }
}
