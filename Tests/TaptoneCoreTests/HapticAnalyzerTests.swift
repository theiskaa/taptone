import Foundation
import TaptoneCore
import Testing

@Suite struct HapticAnalyzerTests {
    @Test(arguments: [44_100.0, 48_000.0, 96_000.0])
    func emitsACueEveryFiveMillisecondsOnTheCaptureClock(rate: Double) throws {
        var analyzer = try #require(HapticAnalyzer(sampleRate: rate))
        analyzer.settle()
        var cues: [HapticCue] = []
        let start: UInt64 = 5_000_000_000
        analyzer.analyze([Float](repeating: 0, count: Int(rate) * 2), hostTimeNs: start) { cues.append($0) }
        #expect((199...201).contains(cues.count))
        let gaps = zip(cues.dropFirst(), cues).map { Double($0.timeNs - $1.timeNs) / 1_000_000 }
        #expect(gaps.allSatisfy { abs($0 - 5) < 0.05 })
        #expect(cues.allSatisfy { $0.body == 0 && $0.onset == nil && $0.pitchHz == nil })
    }

    @Test(arguments: [41.2, 55.0, 82.41, 110.0, 146.83])
    func tracksTheBassNoteUnderAMelody(hertz: Double) throws {
        let cues = try analyze(seconds: 0.6) { time in
            let bass = 0.3 * sin(2 * .pi * hertz * time)
            let melody = 0.25 * sin(2 * .pi * 587.33 * time)
            return (bass + melody, bass + melody)
        }
        let held = cues.filter { $0.timeNs >= 200_000_000 }
        let pitched = held.compactMap(\.pitchHz)
        #expect(pitched.count >= held.count * 9 / 10)
        #expect(pitched.allSatisfy { abs($0 - hertz) / hertz < 0.02 })
        #expect(held.allSatisfy { $0.body > 0.5 })
    }

    @Test func melodyAloneHasNoBassBodyOrPitch() throws {
        let cues = try analyze(seconds: 0.6) { time in
            let melody = 0.4 * sin(2 * .pi * 440 * time) + 0.2 * sin(2 * .pi * 659.25 * time)
            return (melody, melody)
        }
        #expect(cues.allSatisfy { $0.body == 0 })
        #expect(cues.allSatisfy { $0.onset == nil })
    }

    @Test func marksEachKickOnceAtAnyVolume() throws {
        func kicks(gain: Float) throws -> [HapticCue] {
            var demo = DemoBeat(bpm: 120)
            var analyzer = try #require(HapticAnalyzer(sampleRate: DemoBeat.sampleRate))
            analyzer.settle()
            var cues: [HapticCue] = []
            let samples = (0..<Int(DemoBeat.sampleRate * 3)).flatMap { _ -> [Float] in
                let sample = demo.nextSample() * gain
                return [sample, sample]
            }
            analyzer.analyze(samples, hostTimeNs: 0) { cues.append($0) }
            return cues.filter { $0.onset != nil }
        }
        let loud = try kicks(gain: 1)
        // Normalized: a quiet copy plays the same kicks at the same strength, the first one out of silence
        // included (within one 5 ms hop, while the gain settles), because the gain never lifts a sample past
        // full scale.
        let quiet = try kicks(gain: 0.1)
        #expect(loud.count == 6)
        for (index, cue) in loud.enumerated() {
            #expect((0...40_000_000).contains(Int(cue.timeNs) - index * 500_000_000))
        }
        #expect(quiet.count == loud.count)
        if let first = loud.first, let quietFirst = quiet.first {
            #expect(abs(Int(first.timeNs) - Int(quietFirst.timeNs)) <= 10_000_000)
        }
        #expect(quiet.dropFirst().map(\.timeNs) == loud.dropFirst().map(\.timeNs))
        #expect(zip(loud, quiet).allSatisfy { abs(($0.onset ?? 0) - ($1.onset ?? 0)) < 0.1 })
    }

    /// Kick on 1 and 3, noise snare on 2 and 4, hats on eighths, a bass line with a one-second break, and a melody.
    /// 0.03 and 0.015 are the same mix 30 and 36 dB quieter, like the volume turned well down; the quietest peaks
    /// near −40 dBFS. (60 dB quieter, peaking near −64 dBFS, is no longer lifted: it sits with room tone and hum,
    /// which must stay unfelt.)
    @Test(arguments: [1.0, 0.03, 0.015])
    func followsAFullMix(gain: Double) throws {
        var noise: UInt64 = 0x9E37_79B9_7F4A_7C15
        func white() -> Double {
            noise = noise &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(noise >> 11) / Double(1 << 53) * 2 - 1
        }
        let notes: [(start: Double, hertz: Double)] = [(0.1, 55), (1.1, 65.41), (2.1, 41.2)]
        let melody = [440.0, 523.25, 659.25, 587.33]
        let cues = try analyze(seconds: 4) { time in
            var sample = 0.0
            let beat = time.truncatingRemainder(dividingBy: 1)
            sample += 0.7 * sin(2 * .pi * 85 * beat) * exp(-beat * 38)
            let snare = (time + 0.5).truncatingRemainder(dividingBy: 1)
            sample += 0.5 * white() * exp(-snare / 0.06)
            sample += 0.2 * white() * exp(-time.truncatingRemainder(dividingBy: 0.25) / 0.015)
            if let note = notes.last(where: { time >= $0.start }), time < note.start + 0.8 {
                let edge = min(1, (time - note.start) / 0.01, (note.start + 0.8 - time) / 0.01)
                sample += 0.3 * edge * sin(2 * .pi * note.hertz * (time - note.start))
            }
            sample += 0.2 * sin(2 * .pi * melody[Int(time * 2) % melody.count] * time)
            return (sample * gain, sample * gain)
        }
        func seconds(_ cue: HapticCue) -> Double { Double(cue.timeNs) / 1e9 }

        let kicks = cues.filter { $0.onset != nil }.map(seconds)
        // The bass notes starting under each kick's tail are not kicks.
        let expected = [0.0, 1, 2, 3]
        #expect(kicks.count == expected.count)
        for (time, beat) in zip(kicks, expected) { #expect((0...0.04).contains(time - beat)) }

        for note in notes {
            let held = cues.filter { (note.start + 0.2...note.start + 0.75).contains(seconds($0)) }
            let carriers = held.compactMap(\.pitchHz).map { HapticSynth.carrier(for: $0) }
            let expected = HapticSynth.carrier(for: note.hertz)
            let inTune = carriers.filter { abs($0 - expected) / expected < 0.03 }
            #expect(inTune.count >= held.count * 7 / 10, "\(note.hertz) Hz: \(inTune.count)/\(held.count)")
            #expect(held.allSatisfy { $0.body > 0.3 })
        }
        let silentBass = cues.filter { (3.3...4).contains(seconds($0)) }
        #expect(silentBass.allSatisfy { $0.body == 0 })
    }

    /// With `followsVolume`, a quieter mix gives a weaker body instead of being lifted back up.
    @Test func followsTheVolumeWhenAsked() throws {
        func body(gain: Double, followsVolume: Bool) throws -> Double {
            let cues = try analyze(seconds: 1, followsVolume: followsVolume) { time in
                let sample = gain * 0.5 * sin(2 * .pi * 55 * time)
                return (sample, sample)
            }
            let held = cues.filter { $0.timeNs > 500_000_000 }.map(\.body)
            return held.reduce(0, +) / Double(held.count)
        }
        let loud = try body(gain: 1, followsVolume: true)
        #expect(loud > 0.3)
        #expect(try body(gain: 0.03, followsVolume: true) < loud / 2)
        #expect(abs(try body(gain: 0.03, followsVolume: false) - loud) < 0.1)
    }

    /// A hum or rumble far below anything audible, like room tone, never reaches the trackpad,
    /// even though quiet music is lifted to full strength.
    @Test(arguments: [-90.0, -84.0])
    func ignoresInaudibleRumble(levelDBFS: Double) throws {
        let amplitude = pow(10, levelDBFS / 20) * 2.squareRoot() // A sine's RMS is its peak over √2.
        let cues = try analyze(seconds: 3) { time in
            let sample = amplitude * sin(2 * .pi * 60 * time)
            return (sample, sample)
        }
        #expect(cues.allSatisfy { $0.body == 0 && $0.onset == nil })
    }

    /// Once loud music stops, a hum far below hearing stays unfelt, including 15–25 s later when the
    /// slow loudness peak has decayed far enough to lift it by the full boost.
    @Test func mutesAnInaudibleHumAfterMusic() throws {
        let hum = pow(10, -95.0 / 20) * 2.squareRoot()
        let cues = try analyze(seconds: 26) { time in
            let sample = time < 2 ? 0.45 * sin(2 * .pi * 55 * time) : hum * sin(2 * .pi * 60 * time)
            return (sample, sample)
        }
        let afterMusic = cues.filter { $0.timeNs > 3_500_000_000 }
        #expect(!afterMusic.isEmpty)
        #expect(afterMusic.allSatisfy { $0.body == 0 && $0.onset == nil })
    }

    /// A held note doesn't turn into a kick when the analyzer resets after a glitch.
    /// A session that starts mid-song (after headphones connect, a call ends, or the Mac wakes) picks up
    /// bass that's already playing; that's not a kick.
    @Test(arguments: [44_100.0, 48_000, 96_000, 192_000])
    func startingMidNoteDoesNotInventAKick(rate: Double) throws {
        for hertz in [45.0, 55, 80] {
            var analyzer = try #require(HapticAnalyzer(sampleRate: rate))
            let stereo = (0..<Int(rate / 2)).flatMap { index -> [Float] in
                let sample = Float(0.4 * sin(2 * .pi * hertz * (Double(index) / rate + 0.25)))
                return [sample, sample]
            }
            var onsets = 0
            analyzer.analyze(stereo, hostTimeNs: 0) { if $0.onset != nil { onsets += 1 } }
            #expect(onsets == 0, "\(hertz) Hz at \(rate) Hz")
        }
    }

    @Test func resetDoesNotInventAKick() throws {
        var analyzer = try #require(HapticAnalyzer(sampleRate: 48_000))
        func note(from start: Int) -> [Float] {
            (start..<start + 24_000).flatMap { index -> [Float] in
                let sample = Float(0.4 * sin(2 * .pi * 55 * Double(index) / 48_000))
                return [sample, sample]
            }
        }
        var onsets: [Double] = []
        analyzer.analyze(note(from: 0), hostTimeNs: 0) { if let onset = $0.onset { onsets.append(onset) } }
        let beforeReset = onsets.count
        analyzer.reset()
        analyzer.analyze(note(from: 24_000), hostTimeNs: 500_000_000) { if let onset = $0.onset { onsets.append(onset) } }
        #expect(onsets.count == beforeReset)
    }

    /// After a glitch, the detectors start over but the loudness reference stays: a mix that just got
    /// 30 dB quieter isn't lifted back to full strength at once, as a fresh analyzer would.
    @Test func resetKeepsTheLoudnessReference() throws {
        func bass(_ gain: Double) -> [Float] {
            (0..<48_000).flatMap { index -> [Float] in
                let sample = Float(gain * 0.5 * sin(2 * .pi * 55 * Double(index) / 48_000))
                return [sample, sample]
            }
        }
        func meanBody(_ cues: [HapticCue]) -> Double { cues.dropFirst(40).map(\.body).reduce(0, +) / Double(cues.count - 40) }

        var kept = try #require(HapticAnalyzer(sampleRate: 48_000))
        kept.analyze(bass(1), hostTimeNs: 0) { _ in }
        kept.reset()
        var afterReset: [HapticCue] = []
        kept.analyze(Array(bass(0.03).prefix(48_000)), hostTimeNs: 0) { afterReset.append($0) }

        var fresh = try #require(HapticAnalyzer(sampleRate: 48_000))
        var fromScratch: [HapticCue] = []
        fresh.analyze(Array(bass(0.03).prefix(48_000)), hostTimeNs: 0) { fromScratch.append($0) }

        #expect(meanBody(fromScratch) > 0.3)
        #expect(meanBody(afterReset) < meanBody(fromScratch) / 2)
    }

    @Test func rejectsInvalidSampleRates() {
        #expect(HapticAnalyzer(sampleRate: 0) == nil)
        #expect(HapticAnalyzer(sampleRate: .nan) == nil)
    }

    private func analyze(seconds: Double, rate: Double = 48_000, followsVolume: Bool = false,
                         sample: (Double) -> (Double, Double)) throws -> [HapticCue] {
        var analyzer = try #require(HapticAnalyzer(sampleRate: rate))
        analyzer.settle()
        analyzer.followsVolume = followsVolume
        var stereo: [Float] = []
        for index in 0..<Int(rate * seconds) {
            let (left, right) = sample(Double(index) / rate)
            stereo += [Float(left), Float(right)]
        }
        var cues: [HapticCue] = []
        analyzer.analyze(stereo, hostTimeNs: 0) { cues.append($0) }
        return cues
    }
}

extension HapticAnalyzer {
    /// A fresh analyzer ignores its first 30 ms, so a test signal that starts on a kick gets a short silent lead-in.
    mutating func settle() {
        analyze([Float](repeating: 0, count: Int(sampleRate * 0.05) * 2), hostTimeNs: 0) { _ in }
    }
}
