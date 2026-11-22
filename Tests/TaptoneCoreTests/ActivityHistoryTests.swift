import TaptoneCore
import Testing

@Suite struct ActivityHistoryTests {
    @Test func rollsTheChartWithoutLosingSessionTotals() {
        let window = ActivityHistory.durationNs
        var history = ActivityHistory()
        history.record(at: 1, levelDBFS: -24, beatTimeNs: 1, tapRequested: false)
        history.record(at: 2, levelDBFS: -14, beatTimeNs: 2, tapRequested: true)
        history.record(at: window + 2, levelDBFS: -32, beatTimeNs: nil, tapRequested: false)

        #expect(history.samples.map(\.timeNs) == [2, window + 2])
        #expect(history.beatCount == 2)
        #expect(history.tapCount == 1)
    }

    @Test func boundsHistoryAndRejectsOutOfOrderReadings() {
        var history = ActivityHistory()
        for time: UInt64 in 0..<1_000 {
            history.record(at: time, levelDBFS: -40, beatTimeNs: nil, tapRequested: false)
        }
        history.record(at: 998, levelDBFS: -12, beatTimeNs: 998, tapRequested: true)
        #expect(history.samples.count == 256)
        #expect(history.samples.last?.timeNs == 999)
        #expect(history.beatCount == 0)
        #expect(history.tapCount == 0)
    }
}
