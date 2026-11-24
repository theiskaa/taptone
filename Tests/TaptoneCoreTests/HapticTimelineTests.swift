import TaptoneCore
import Testing

@Suite struct HapticTimelineTests {
    private let ms: UInt64 = 1_000_000

    @Test func holdsCuesUntilTheirAudioIsHeard() {
        var timeline = HapticTimeline()
        for step: UInt64 in 1...40 { timeline.append(HapticCue(timeNs: step * 5 * ms, body: Double(step) / 40)) }
        #expect(timeline.take(at: 2 * ms).cue == nil)
        #expect(timeline.take(at: 52 * ms).cue?.timeNs == 50 * ms)
        #expect(timeline.take(at: 52 * ms).cue?.timeNs == 50 * ms)
        #expect(timeline.take(at: 199 * ms).cue?.timeNs == 195 * ms)
    }

    @Test func reportsEachKickOnceEvenWhenStepsAreSkipped() {
        var timeline = HapticTimeline()
        timeline.append(HapticCue(timeNs: 10 * ms, body: 0.5, onset: 0.7))
        timeline.append(HapticCue(timeNs: 15 * ms, body: 0.5))
        timeline.append(HapticCue(timeNs: 20 * ms, body: 0.5, onset: 0.9))
        timeline.append(HapticCue(timeNs: 25 * ms, body: 0.5))
        #expect(timeline.take(at: 26 * ms).onset == 0.9)
        #expect(timeline.take(at: 27 * ms).onset == nil)
    }

    @Test func dropsLateKicksAndStaleCues() {
        var timeline = HapticTimeline()
        timeline.append(HapticCue(timeNs: 10 * ms, body: 0.5, onset: 1))
        let late = timeline.take(at: 10 * ms + HapticTimeline.maximumKickLatenessNs + 1)
        #expect(late.onset == nil)
        #expect(late.cue == nil)
        timeline.append(HapticCue(timeNs: 200 * ms, body: 0.5))
        #expect(timeline.take(at: 200 * ms + HapticTimeline.maximumCueAgeNs).cue != nil)
        #expect(timeline.take(at: 201 * ms + HapticTimeline.maximumCueAgeNs).cue == nil)
    }

    @Test func staysBoundedAndIgnoresOutOfOrderCues() {
        var timeline = HapticTimeline()
        for step: UInt64 in 1...2_000 { timeline.append(HapticCue(timeNs: step * ms, body: 0)) }
        timeline.append(HapticCue(timeNs: 5 * ms, body: 1, onset: 1))
        #expect(timeline.count == HapticTimeline.capacity)
        let now = timeline.take(at: 2_000 * ms)
        #expect(now.cue?.timeNs == 2_000 * ms)
        #expect(now.onset == nil)
        #expect(timeline.count == 1)
    }
}
