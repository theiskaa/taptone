/// Audio-independent reference pattern: four single taps with a short setup delay.
package enum TapTest {
    @MainActor
    package static func run(
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        requestTap: () -> Void
    ) async throws {
        for delay in [Duration.seconds(2), .seconds(1), .seconds(1), .seconds(1)] {
            try await sleep(delay)
            try Task.checkCancellation()
            requestTap()
        }
    }
}
