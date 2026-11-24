import TaptoneCore
import Testing

@Suite struct ActivityHistoryTests {
    @Test func rollsTheChartWithoutLosingSessionTotals() {
        let window = ActivityHistory.durationNs
        var history = ActivityHistory()
        history.record(at: 1, levelDBFS: -24, motorLevel: 0.3, kicks: 1)
        history.record(at: 2, levelDBFS: -14, kicks: 2)
        history.record(at: window + 2, levelDBFS: -32)

        #expect(history.samples.map(\.timeNs) == [2, window + 2])
        #expect(history.kickCount == 3)
    }

    @Test func boundsHistoryAndRejectsOutOfOrderOrInvalidReadings() {
        var history = ActivityHistory()
        for time: UInt64 in 0..<1_000 {
            history.record(at: time, levelDBFS: -40, motorLevel: .nan, kicks: -1)
        }
        history.record(at: 998, levelDBFS: -12, kicks: 1)
        #expect(history.samples.count == 256)
        #expect(history.samples.last?.timeNs == 999)
        #expect(history.samples.allSatisfy { $0.motorLevel == 0 && $0.kicks == 0 })
        #expect(history.kickCount == 0)
    }
}
