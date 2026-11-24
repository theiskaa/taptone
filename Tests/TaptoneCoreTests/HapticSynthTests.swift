import Foundation
import TaptoneCore
import Testing

@Suite struct HapticSynthTests {
    @Test func foldsBassNotesIntoTheMotorRangeWithoutOctaveJumps() {
        #expect(abs(HapticSynth.carrier(for: 41.2) - 164.8) < 0.01)
        #expect(abs(HapticSynth.carrier(for: 110) - 220) < 0.01)
        // Where two octaves fit, stay on the one nearest the current carrier.
        #expect(abs(HapticSynth.carrier(for: 139, near: 270) - 278) < 0.01)
        #expect(abs(HapticSynth.carrier(for: 139, near: 130) - 139) < 0.01)
        #expect(abs(HapticSynth.carrier(for: 60, near: 250) - 240) < 0.01)
        #expect(abs(HapticSynth.carrier(for: 60, near: 110) - 120) < 0.01)
        #expect(HapticSynth.carrier(for: .nan, near: 150) == 150)
    }

    @Test func silenceProducesNothing() {
        var synth = HapticSynth()
        for step in 0..<100 {
            #expect(synth.next(at: UInt64(step) * 5_000_000, cue: HapticCue(timeNs: 0, body: 0), onset: nil) == nil)
            #expect(synth.next(at: UInt64(step) * 5_000_000 + 1, cue: nil, onset: nil) == nil)
        }
    }

    @Test func heldBassIsAContinuousWholeCycleCarrierAtTheNotePitch() throws {
        var synth = HapticSynth(intensity: .medium)
        var now: UInt64 = 0
        var segments: [HapticSegment] = []
        while now < 400_000_000 {
            let next = synth.next(at: now, cue: HapticCue(timeNs: now, body: 0.8, pitchHz: 55), onset: nil)
            let segment = try #require(next)
            segments.append(segment)
            now += segment.durationNs
        }
        let settled = segments.suffix(20)
        for segment in settled {
            #expect(abs(segment.frequencyHz - 220) < 1)
            let cycles = Double(segment.durationNs) / 1e9 * segment.frequencyHz
            #expect(abs(cycles - cycles.rounded()) < 0.01)
            #expect((4_000_000...10_000_000).contains(segment.durationNs))
            #expect(!segment.isKick)
            #expect(abs(Double(segment.level) - HapticIntensity.medium.bodyLevel * pow(0.8, 0.8)) < 0.001)
        }
    }

    @Test func kickHitsHarderThanTheBodyThenDecaysIntoIt() throws {
        var synth = HapticSynth(intensity: .medium)
        var now: UInt64 = 0
        var segments: [(time: UInt64, segment: HapticSegment)] = []
        var onset: Double? = 1
        while now < 250_000_000 {
            let next = synth.next(at: now, cue: HapticCue(timeNs: now, body: 0.5), onset: onset)
            let segment = try #require(next)
            onset = nil
            segments.append((now, segment))
            now += segment.durationNs
        }
        let first = try #require(segments.first?.segment)
        #expect(first.isKick)
        #expect(abs(Double(first.level) - HapticIntensity.medium.kickLevel) < 0.001)
        #expect(first.frequencyHz > 300)
        let kick = segments.filter(\.segment.isKick)
        #expect(zip(kick.dropFirst(), kick).allSatisfy { $0.segment.level < $1.segment.level })
        #expect(zip(kick.dropFirst(), kick).allSatisfy { $0.segment.frequencyHz < $1.segment.frequencyHz })
        #expect(kick.last.map { $0.time < 150_000_000 } == true)
        #expect(segments.last?.segment.isKick == false)
    }

    @Test func releaseIsShortAndThenStops() throws {
        var synth = HapticSynth()
        _ = synth.next(at: 0, cue: HapticCue(timeNs: 0, body: 1), onset: nil)
        var now: UInt64 = 5_000_000
        var last: Float = 1
        while let segment = synth.next(at: now, cue: HapticCue(timeNs: now, body: 0), onset: nil) {
            #expect(segment.level < last)
            last = segment.level
            now += segment.durationNs
        }
        #expect(now < 150_000_000)
    }

    @Test(arguments: HapticIntensity.allCases)
    func neverExceedsTheHardCeiling(intensity: HapticIntensity) {
        var synth = HapticSynth(intensity: intensity)
        var now: UInt64 = 0
        for step in 0..<400 {
            let onset: Double? = step.isMultiple(of: 7) ? 5 : nil
            if let segment = synth.next(at: now, cue: HapticCue(timeNs: now, body: .infinity, pitchHz: 1e9), onset: onset) {
                #expect(segment.level <= HapticSynth.maximumLevel)
                #expect(segment.level <= Float(intensity.kickLevel) + 1e-6)
                now += segment.durationNs
            } else {
                now += 2_500_000
            }
        }
    }
}
