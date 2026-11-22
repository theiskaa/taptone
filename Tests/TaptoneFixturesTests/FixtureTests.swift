import Foundation
@testable import TaptoneFixtures
import Testing

@Suite struct FixtureTests {
    @Test func waveHeaderAndOnsetsDescribeTheSameStereoSamples() {
        let clip = Fixture.kicks(bpm: 120, antiPhase: true)
        let data = clip.waveData
        func int32(_ offset: Int) -> Int { data[offset..<offset + 4].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) } }

        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(int32(4) == data.count - 8)
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(int32(24) == 48_000)
        #expect(int32(40) == clip.pcm.count * 2)
        #expect(clip.onsets.count == 20)
        #expect(clip.onsets.first == 48_000)
        #expect(clip.onsets.last == 504_000)
        #expect(clip.pcm.prefix(96_000).allSatisfy { $0 == 0 })
        #expect(clip.pcm.suffix(96_000).allSatisfy { $0 == 0 })
        #expect(clip.pcm[96_002] != 0)
        #expect(clip.pcm[96_002] == -clip.pcm[96_003])
    }

    @Test func scoreMatchesCueAtMostOnceAndCountsMissesAndExtras() {
        // Start and end boundaries are inclusive; cue 146 is too late for the first onset.
        let score = BeatScore(onsets: [100, 200, 300, 400], cues: [89, 90, 146, 245, 291, 300], sampleRate: 1_000)
        #expect(score.lags == [-10, 45, -9])
        #expect(score.misses == 1)
        #expect(score.extras == 3)
        #expect(score.precision == 0.5)
        #expect(score.recall == 0.75)
        #expect(score.p95Frames == 45)
    }

    @Test func labelsAreNotDerivedFromDetectorOutput() {
        let clip = Fixture.kicks(bpm: 150)
        let score = BeatScore(onsets: clip.onsets, cues: clip.detect(sensitivity: .normal), sampleRate: Fixture.sampleRate)
        #expect(score.expected == 20)
        #expect(score.misses == 0)
        #expect(score.extras == 0)
        #expect(clip.onsets.first == Fixture.sampleRate)
    }
}
