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

    @Test func rejectsInvalidSampleRates() {
        #expect(BassEnvelope(sampleRate: 0) == nil)
        #expect(BassEnvelope(sampleRate: .nan) == nil)
        #expect(BassEnvelope(sampleRate: .infinity) == nil)
    }
}
