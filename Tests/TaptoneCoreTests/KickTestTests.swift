import TaptoneCore
import Testing

@Suite @MainActor struct KickTestTests {
    @Test func hasFourNumberedKicksAtPredictableTimes() async throws {
        var elapsed: Duration = .zero
        var kicks: [(Int, Duration)] = []
        try await KickTest.run(sleep: { elapsed += $0 }, kick: { kicks.append(($0, elapsed)) })
        #expect(kicks.map(\.0) == [1, 2, 3, 4])
        #expect(kicks.map(\.1) == [.seconds(2), .seconds(3), .seconds(4), .seconds(5)])
    }

    @Test func cancellationWhileWaitingPlaysNoMoreKicks() async {
        let task = Task { @MainActor in
            var waits = 0
            var taps = 0
            do {
                try await KickTest.run(sleep: { _ in
                    waits += 1
                    if waits == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                }, kick: { _ in taps += 1 })
                Issue.record("Cancelled kick test ran to completion")
            } catch is CancellationError {
                #expect(taps == 1)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        await task.value
    }
}
