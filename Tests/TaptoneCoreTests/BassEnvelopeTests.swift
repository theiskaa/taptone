import Foundation
import TaptoneCore
import Testing

@Suite struct BassEnvelopeTests {
    @Test(arguments: [8_000.0, 44_100.0, 48_000.0, 96_000.0, 384_000.0])
    func tracksHeldAntiPhaseBassAndPreservesDynamicsAcrossSampleRates(rate: Double) throws {
        var envelope = try #require(BassEnvelope(sampleRate: rate))
        let split = Int(rate * 0.10)
        let attack = Int(rate * 0.02)
        let note: (Int) -> Float = { Float(sin(2 * .pi * 82.41 * Double($0) / rate)) }
        for index in 0..<attack {
            let sample = 0.07 * note(index)
            envelope.push(sample, -sample)
        }
        #expect(envelope.weight != nil)
        for index in attack..<split {
            let sample = 0.07 * note(index)
            envelope.push(sample, -sample)
        }
        let quiet = try #require(envelope.weight)
        for index in split..<(split * 2) {
            let sample = 0.35 * note(index)
            envelope.push(sample, -sample)
        }
        let loud = try #require(envelope.weight)
        #expect(loud - quiet >= 0.35)
        for _ in 0..<Int(rate * 0.060) { envelope.push(0, 0) }
        #expect(envelope.weight == nil)
    }

    @Test func rejectsUpperBandAudioAndIgnoresNonFiniteSamples() throws {
        var envelope = try #require(BassEnvelope(sampleRate: 48_000))
        envelope.push(.nan, -.infinity)
        for index in 0..<4_800 {
            let sample = Float(0.8 * sin(2 * .pi * 587.33 * Double(index) / 48_000))
            envelope.push(sample, sample)
            if index.isMultiple(of: 480) { #expect(envelope.weight == nil) }
        }
        #expect(envelope.weight == nil)
    }

    @Test(arguments: [220.0, 246.94, 329.63])
    func rejectsMidrangeDuringBothTheNoteAndItsRelease(frequency: Double) throws {
        let levels = try analyze(bassHz: frequency, bassLevel: 0.40, melodyLevel: 0)
        #expect(levels.isEmpty)
    }

    @Test(arguments: [41.20, 82.41, 146.83])
    func detectsLowAndUpperBassAndReturnsToRest(frequency: Double) throws {
        let levels = try analyze(bassHz: frequency, bassLevel: 0.17, melodyLevel: 0.40)
        let first = try #require(levels.first)
        let last = try #require(levels.last)
        #expect(first.ms <= 140)
        #expect(levels.filter { (150..<320).contains($0.ms) }.count == 17)
        #expect(last.ms <= 370)
    }

    @Test func detectsTheSameHeldNoteInARecordingTwentyDecibelsQuieter() throws {
        let quiet = try analyze(bassHz: 82.41, bassLevel: 0.007, melodyLevel: 0.040)
        let normal = try analyze(bassHz: 82.41, bassLevel: 0.070, melodyLevel: 0.400)
        #expect(quiet.filter { (150..<320).contains($0.ms) }.count == 17)
        #expect(quiet.first?.ms == normal.first?.ms)
        #expect(quiet.last?.ms == normal.last?.ms)
    }

    @Test func louderBassStillProducesMoreOutputAboveTheOldCeiling() throws {
        let loud = try analyze(bassHz: 82.41, bassLevel: 0.45, melodyLevel: 0.12)
        let louder = try analyze(bassHz: 82.41, bassLevel: 0.75, melodyLevel: 0.12)
        let heldA = try #require(loud.first { $0.ms == 250 })
        let heldB = try #require(louder.first { $0.ms == 250 })
        #expect(heldB.weight - heldA.weight >= 0.035)
        #expect(heldB.weight <= 1)
    }

    @Test func rejectsInvalidSampleRates() {
        #expect(BassEnvelope(sampleRate: 0) == nil)
        #expect(BassEnvelope(sampleRate: .nan) == nil)
        #expect(BassEnvelope(sampleRate: .infinity) == nil)
    }

    /// Labelled exercise: bass note at 100–350 ms, with 20 ms edges and optional continuous melody.
    private func analyze(bassHz: Double, bassLevel: Double, melodyLevel: Double) throws -> [(ms: Int, weight: Double)] {
        let rate = 48_000.0
        var envelope = try #require(BassEnvelope(sampleRate: rate))
        var levels: [(Int, Double)] = []
        for sample in 0..<24_000 {
            let time = Double(sample) / rate
            let noteTime = time - 0.100
            let shape = max(0, min(1, noteTime / 0.020, (0.250 - noteTime) / 0.020))
            let bass = shape * bassLevel * sin(2 * .pi * bassHz * noteTime)
            let melody = min(1, time / 0.020) * melodyLevel * sin(2 * .pi * 587.33 * time)
            envelope.push(Float(melody + bass), Float(melody - bass))
            if (sample + 1).isMultiple(of: 480), let weight = envelope.weight {
                levels.append(((sample + 1) / 48, weight))
            }
        }
        return levels
    }
}
