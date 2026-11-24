import Foundation
import Observation
import TaptoneCore

/// Preferences shared by the menu, the Activity window, and the welcome window. Saved as they change.
@Observable @MainActor
final class Settings {
    static let syncOffsetRangeMs = -100...100
    static let syncOffsetStepMs = 10

    var intensity: HapticIntensity { didSet { save(intensity.rawValue, "intensity") } }
    var sensitivity: BeatDetector.Sensitivity { didSet { save(sensitivity.rawValue, "sensitivity") } }
    /// Added to the output's reported latency, for devices that report it wrong.
    var syncOffsetMs: Int { didSet { save(syncOffsetMs, "syncOffsetMs") } }
    /// Haptics get weaker as the volume goes down. Off: they keep the same strength at any volume.
    var followsVolume: Bool { didSet { save(followsVolume, "followsVolume") } }
    var didShowWelcome: Bool { didSet { save(didShowWelcome, "didShowWelcome") } }

    /// Called after any change, so the running session can follow.
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        intensity = defaults.string(forKey: "intensity").flatMap(HapticIntensity.init(rawValue:)) ?? .medium
        sensitivity = defaults.string(forKey: "sensitivity").flatMap(BeatDetector.Sensitivity.init(rawValue:)) ?? .normal
        syncOffsetMs = Self.syncOffsetRangeMs.clamped(defaults.integer(forKey: "syncOffsetMs"))
        followsVolume = defaults.bool(forKey: "followsVolume")
        didShowWelcome = defaults.bool(forKey: "didShowWelcome")
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
        onChange()
    }
}

private extension ClosedRange<Int> {
    func clamped(_ value: Int) -> Int { Swift.min(upperBound, Swift.max(lowerBound, value)) }
}
