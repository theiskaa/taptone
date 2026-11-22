import TaptoneCore
import Testing

@Suite @MainActor struct TapTestTests {
    @Test func hasFourTapsAtPredictableTimes() async throws {
        var elapsed: Duration = .zero
        var taps: [Duration] = []
        try await TapTest.run(sleep: { elapsed += $0 }, requestTap: { taps.append(elapsed) })
        #expect(taps == [.seconds(2), .seconds(3), .seconds(4), .seconds(5)])
    }

    @Test func cancellationWhileWaitingDoesNotRequestAnyMoreTaps() async {
        let task = Task { @MainActor in
            var waits = 0
            var taps = 0
            do {
                try await TapTest.run(sleep: { _ in
                    waits += 1
                    if waits == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                }, requestTap: { taps += 1 })
                Issue.record("Cancelled tap test ran to completion")
            } catch is CancellationError {
                #expect(taps == 1)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        await task.value
    }
}
