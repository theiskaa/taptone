/// Four kicks a second apart after a short lead-in, without audio. Reports each kick's number (1...4).
package enum KickTest {
    package static let count = 4

    @MainActor
    package static func run(
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        kick: (Int) -> Void
    ) async throws {
        for number in 1...count {
            try await sleep(number == 1 ? .seconds(2) : .seconds(1))
            try Task.checkCancellation()
            kick(number)
        }
    }
}
