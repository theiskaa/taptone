import Foundation
import TaptoneCore
import Testing

/// How the analysis feels across real kinds of audio: no drone from hum or room noise, held bass that
/// settles instead of wearing on you, voices kept off the trackpad, and kicks that are kicks.
@Suite struct HapticFeelTests {
    private static let rate = 48_000.0

    // MARK: Quiet noise

    /// A hum or rumble below anything worth feeling isn't lifted into a drone.
    @Test(arguments: [-60.0, -70.0])
    func quietHumIsNeverLifted(levelDBFS: Double) throws {
        let amplitude = pow(10, levelDBFS / 20) * 2.squareRoot()
        let cues = try analyze(seconds: 6) { amplitude * sin(2 * .pi * 60 * $0) }
        #expect(cues.allSatisfy { $0.body < HapticSynth.bodyGate && $0.onset == nil })
    }

    /// A steady hum loud enough to pass the floor still fades away instead of droning on.
    @Test func steadyHumFadesOut() throws {
        let amplitude = pow(10, -50.0 / 20) * 2.squareRoot()
        let cues = try analyze(seconds: 11) { amplitude * sin(2 * .pi * 60 * $0) }
        #expect(mean(cues, 0.5...1.5) > 0.1)
        #expect(cues.filter { seconds($0) > 9.5 }.allSatisfy { $0.body < HapticSynth.bodyGate })
    }

    // MARK: Held bass

    /// A held note settles to well under half after a few seconds and comes straight back on a new note.
    @Test func heldBassSettlesAndANewNoteBringsItBack() throws {
        let cues = try analyze(seconds: 5) { time in 0.4 * sin(2 * .pi * (time < 4 ? 60 : 73.42) * time) }
        let fresh = mean(cues, 0.5...1.0)
        #expect(fresh > 0.8)
        #expect((0.3 * fresh...0.55 * fresh).contains(mean(cues, 3.5...3.9)))
        #expect(mean(cues, 4.1...4.5) > 0.85 * fresh)
    }

    /// A drone with nothing new in it for several seconds fades out entirely.
    @Test func unchangingDroneFadesOut() throws {
        let cues = try analyze(seconds: 11) { time in 0.4 * sin(2 * .pi * 32.7 * time) + 0.2 * sin(2 * .pi * 65.4 * time) }
        #expect(mean(cues, 0.5...1.0) > 0.8)
        #expect(mean(cues, 10.5...11) < 0.05)
    }

    // MARK: Voices

    /// Speech in the bass range (a podcast, a call) doesn't buzz the trackpad or knock on it, once the first
    /// couple of syllables have shown it's speech.
    @Test(arguments: [85.0, 110.0, 210.0])
    func voicesStayOffTheTrackpad(pitchHz: Double) throws {
        let cues = try analyze(seconds: 8) { voice($0, pitchHz: pitchHz) }.filter { seconds($0) > 1 }
        #expect(cues.filter { $0.body >= HapticSynth.bodyGate }.count < cues.count / 8)
        #expect(cues.allSatisfy { $0.onset == nil })
    }

    /// Real bass lines, low and high, still play while voices are held back.
    @Test(arguments: [[41.2, 41.2, 49, 55], [82.41, 82.41, 98, 110]])
    func bassLinesStillPlay(notes: [Double]) throws {
        let cues = try analyze(seconds: 4) { 0.35 * pluckLine($0, notes: notes, step: 0.5) }
        let held = cues.filter { seconds($0) > 1 }
        #expect(held.filter { $0.body > 0.3 }.count >= held.count * 9 / 10)
    }

    // MARK: Kicks

    /// Snares, with or without a low shell, and a chime aren't kicks.
    @Test(arguments: [190.0, 220.0, 300.0])
    func upperDrumsAndChimesAreNotKicks(hertz: Double) throws {
        var noise = Noise()
        let cues = try analyze(seconds: 6) { time in
            let hit = (time + 0.25).truncatingRemainder(dividingBy: 0.5)
            let tone = 0.5 * sin(2 * .pi * hertz * hit) * exp(-hit * 30)
            return hertz < 300 ? tone + 0.5 * noise.next() * exp(-hit * 25) : tone
        }
        #expect(cues.allSatisfy { $0.onset == nil })
    }

    /// Kicks in a pop mix (snare, hats, a bass line, a voice on top) and kicks over a held sub-bass both land.
    @Test(arguments: [false, true])
    func kicksLandInADenseMix(overSub: Bool) throws {
        var noise = Noise()
        let cues = try analyze(seconds: 8) { time in
            let beat = time.truncatingRemainder(dividingBy: 0.5)
            var sample = 0.45 * kick(beat)
            if overSub {
                sample += 0.4 * sin(2 * .pi * 50 * time)
            } else {
                let snare = (time + 0.5).truncatingRemainder(dividingBy: 1)
                let hat = time.truncatingRemainder(dividingBy: 0.25)
                sample += 0.3 * (0.5 * noise.next() * exp(-snare * 25) + 0.5 * sin(2 * .pi * 190 * snare) * exp(-snare * 30))
                sample += 0.06 * noise.next() * exp(-hat * 60)
                sample += 0.25 * pluckLine(time, notes: [55, 55, 65.41, 49], step: 0.25, decay: 2)
                sample += voice(time, pitchHz: 220) + 0.06 * sin(2 * .pi * 523.25 * time)
            }
            return sample
        }
        let kicks = cues.filter { $0.onset != nil && seconds($0) > 1 }.map(seconds)
        let beats = stride(from: 1.5, to: 7.9, by: 0.5)
        let landed = beats.filter { beat in kicks.contains { (beat - 0.005...beat + 0.040).contains($0) } }
        #expect(landed.count >= beats.underestimatedCount * 9 / 10)
        #expect(kicks.count <= landed.count + 1)
        #expect(cues.filter { seconds($0) > 1 }.compactMap(\.onset).allSatisfy { $0 >= 0.45 })
    }

    /// A kick fires at once; it isn't held back waiting for a pitch.
    @Test func kicksAreNotDelayed() throws {
        let cues = try analyze(seconds: 3) { 0.8 * kick($0.truncatingRemainder(dividingBy: 0.5)) }
        let kicks = cues.filter { $0.onset != nil }.map(seconds)
        #expect(kicks.count == 6)
        for (index, time) in kicks.enumerated() { #expect((0...0.025).contains(time - Double(index) * 0.5)) }
    }

    // MARK: Helpers

    private func analyze(seconds: Double, sample: (Double) -> Double) throws -> [HapticCue] {
        var analyzer = try #require(HapticAnalyzer(sampleRate: Self.rate))
        analyzer.settle()
        var cues: [HapticCue] = []
        let frames = Int(Self.rate * seconds)
        var stereo: [Float] = []
        stereo.reserveCapacity(960)
        for start in stride(from: 0, to: frames, by: 480) {
            stereo.removeAll(keepingCapacity: true)
            for index in start..<min(frames, start + 480) {
                let value = Float(sample(Double(index) / Self.rate))
                stereo += [value, value]
            }
            analyzer.analyze(stereo, hostTimeNs: UInt64((Double(start) / Self.rate * 1e9).rounded())) { cues.append($0) }
        }
        return cues
    }

    private func seconds(_ cue: HapticCue) -> Double { Double(cue.timeNs) / 1e9 }

    private func mean(_ cues: [HapticCue], _ range: ClosedRange<Double>) -> Double {
        let bodies = cues.filter { range.contains(seconds($0)) }.map(\.body)
        return bodies.reduce(0, +) / Double(max(1, bodies.count))
    }

    /// Speech-like: a harmonic voice with formants, syllables about 4.5 a second, a pause every few words,
    /// and intonation (phase integrated, so the pitch really is what it says).
    private func voice(_ time: Double, pitchHz: Double) -> Double {
        let syllable = 0.22
        let index = Int(time / syllable)
        let phase = time - Double(index) * syllable
        guard index % 7 != 6, time.truncatingRemainder(dividingBy: 3) <= 2.5, phase < 0.18 else { return 0 }
        let formants: [(hertz: Double, gain: Double, width: Double)] = pitchHz > 150
            ? [(750, 6, 90), (1_900, 4, 130), (2_900, 2.5, 160)]
            : [(500, 6, 80), (1_500, 4, 120), (2_500, 2.5, 150)]
        let offset = 1 + 0.05 * sin(Double(index) * 1.7)
        let wobble = 2 * Double.pi * 0.7
        let f0 = pitchHz * (offset + 0.12 * sin(wobble * time))
        let cycle = 2 * .pi * pitchHz * (offset * time - 0.12 * cos(wobble * time) / wobble)
        var sum = 0.0
        var harmonic = 1
        while Double(harmonic) * f0 < 4_000 {
            let hertz = f0 * Double(harmonic)
            let gain = 1 + formants.reduce(0) { $0 + $1.gain / (1 + pow((hertz - $1.hertz) / $1.width, 2)) }
            sum += gain / Double(harmonic) * sin(cycle * Double(harmonic))
            harmonic += 1
        }
        return 0.2 * sin(.pi * phase / 0.18) * sum / 6
    }

    /// A plucked bass string: a few harmonics, the higher ones dying faster.
    private func pluckLine(_ time: Double, notes: [Double], step: Double, decay: Double = 3) -> Double {
        let index = Int(time / step)
        let phase = time - Double(index) * step
        let hertz = notes[index % notes.count]
        let harmonics = [1.0, 0.6, 0.4, 0.3, 0.2, 0.12, 0.08, 0.06]
        let sum = harmonics.enumerated().reduce(0.0) { sum, item in
            let n = Double(item.offset + 1)
            return sum + item.element * sin(2 * .pi * hertz * n * phase) * exp(-phase * decay * n * 0.5)
        }
        return sum * min(1, phase / 0.003)
    }

    /// A kick drum: a pitch dive from 150 to 50 Hz under a quick decay.
    private func kick(_ time: Double) -> Double {
        let phase = 2 * .pi * (50 * time + 100 * (1 - exp(-time * 40)) / 40)
        return sin(phase) * exp(-time * 18) * min(1, time / 0.001)
    }

    private struct Noise {
        private var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
    }
}
