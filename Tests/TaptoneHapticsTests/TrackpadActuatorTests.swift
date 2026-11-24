import Foundation
import TaptoneCore
import TaptoneHaptics
import Testing

/// Drives the real motor: one Light kick. Opt in with TAPTONE_MOTOR_CHECK=1 on a Mac with a Force Touch trackpad.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TAPTONE_MOTOR_CHECK"] == "1"))
struct TrackpadActuatorTests {
    @Test func playsOneKickOnTheRealMotor() async throws {
        #expect(TrackpadActuator.isSupported)
        let actuator = try #require(TrackpadActuator.open())
        let player = HapticPlayer(output: actuator, latencyNs: 0, intensity: .light, onFailure: {})
        player.kick()
        try await Task.sleep(for: .milliseconds(300))
        let reading = player.takeReading()
        #expect(player.stop())
        #expect(reading.kicks == 1)
        #expect(reading.peakLevel > 0.3)
    }
}
