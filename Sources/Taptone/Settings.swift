import Foundation
import Observation
import TaptoneCore

/// Preferences shared by the menu, the main window, and the welcome window. Saved as they change.
@Observable @MainActor
final class Settings {
    /// Wide enough for Bluetooth and AirPlay outputs that report their latency wrong.
    static let syncOffsetRangeMs = -300...300
    static let syncOffsetStepMs = 10

    var intensity: HapticIntensity { didSet { save(intensity.rawValue, "intensity") } }
    var sensitivity: BeatDetector.Sensitivity { didSet { save(sensitivity.rawValue, "sensitivity") } }
    /// Added to the output's reported latency, for devices that report it wrong.
    var syncOffsetMs: Int { didSet { save(syncOffsetMs, "syncOffsetMs") } }
    /// Haptics get weaker as the volume goes down. Off: they keep the same strength at any volume.
    var followsVolume: Bool { didSet { save(followsVolume, "followsVolume") } }
    /// Haptics pause while an app uses the microphone, as during a call.
    var pausesDuringCalls: Bool { didSet { save(pausesDuringCalls, "pausesDuringCalls") } }
    /// Bundle IDs of apps whose audio Taptone leaves out.
    var ignoredApps: [String] { didSet { save(ignoredApps, "ignoredApps") } }
    /// ⌃⌥⌘P pauses or resumes from anywhere.
    var pauseShortcut: Bool { didSet { save(pauseShortcut, "pauseShortcut") } }
    var checksForUpdates: Bool { didSet { save(checksForUpdates, "checksForUpdates") } }
    /// When a pause ends: `.distantFuture` until resumed, nil when not paused. Survives a relaunch.
    var pausedUntil: Date? { didSet { save(pausedUntil, "pausedUntil") } }
    var didShowWelcome: Bool { didSet { save(didShowWelcome, "didShowWelcome") } }

    /// Bookkeeping that nothing displays, so changing it doesn't call `onChange`.
    @ObservationIgnored var lastUpdateCheck: Date? {
        get { defaults.object(forKey: "lastUpdateCheck") as? Date }
        set { defaults.set(newValue, forKey: "lastUpdateCheck") }
    }
    @ObservationIgnored var declinedMoveToApplications: Bool {
        get { defaults.bool(forKey: "declinedMoveToApplications") }
        set { defaults.set(newValue, forKey: "declinedMoveToApplications") }
    }

    /// Called after any change, so the running session can follow.
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        intensity = defaults.string(forKey: "intensity").flatMap(HapticIntensity.init(rawValue:)) ?? .medium
        sensitivity = defaults.string(forKey: "sensitivity").flatMap(BeatDetector.Sensitivity.init(rawValue:)) ?? .normal
        syncOffsetMs = Self.syncOffsetRangeMs.clamped(defaults.integer(forKey: "syncOffsetMs"))
        followsVolume = defaults.bool(forKey: "followsVolume")
        pausesDuringCalls = defaults.object(forKey: "pausesDuringCalls") as? Bool ?? true
        ignoredApps = defaults.stringArray(forKey: "ignoredApps") ?? []
        pauseShortcut = defaults.bool(forKey: "pauseShortcut")
        checksForUpdates = defaults.object(forKey: "checksForUpdates") as? Bool ?? true
        pausedUntil = (defaults.object(forKey: "pausedUntil") as? Date).flatMap { $0 > .now ? $0 : nil }
        didShowWelcome = defaults.bool(forKey: "didShowWelcome")
    }

    private func save(_ value: Any?, _ key: String) {
        defaults.set(value, forKey: key)
        onChange()
    }
}

extension BeatDetector.Sensitivity {
    /// How many kicks get through: Fewer only takes clear ones.
    var title: String {
        switch self {
        case .low: "Fewer"
        case .normal: "Normal"
        case .high: "More"
        }
    }
}

private extension ClosedRange<Int> {
    func clamped(_ value: Int) -> Int { Swift.min(upperBound, Swift.max(lowerBound, value)) }
}
