import Foundation

/// Scales audio toward a steady reference loudness, so haptics follow a song's own dynamics rather than
/// how far the volume is turned up. The capture tap hears each app after its volume is applied, so the
/// range covers nearly the whole volume scale.
/// Gain follows the recent peak of short-window power: instant attack, slow release, held through silence.
/// Sound under `floorDBFS` right now, such as room tone or a hum nobody can hear, is muted rather than
/// lifted to full strength, even while the slow peak still remembers louder music.
struct LoudnessNormalizer: Sendable {
    static let targetPeakDBFS = -6.0
    static let maximumBoostDB = 60.0
    static let maximumCutDB = 12.0
    /// Below this, a window counts as silence and leaves the gain unchanged.
    static let silenceDBFS = -100.0
    /// Quieter than anything worth feeling, even with the volume well down.
    static let floorDBFS = -78.0
    static let releaseDBPerSecond = 3.0
    /// How fast "right now" forgets: quick enough to mute a hum within a second, slow enough to ride
    /// through the gaps between notes.
    static let recentReleaseDBPerSecond = 60.0

    private let releasePerWindowDB: Double
    private let recentReleasePerWindowDB: Double
    private var peakDB: Double?
    private var recentDB: Double?
    private(set) var gain = 1.0

    init(windowSeconds: Double) {
        releasePerWindowDB = Self.releaseDBPerSecond * windowSeconds
        recentReleasePerWindowDB = Self.recentReleaseDBPerSecond * windowSeconds
    }

    /// Update from one window's mean power (before gain). The new gain applies to the next window.
    mutating func update(meanPower: Double) {
        let level = 10 * log10(max(meanPower, 1e-12))
        let recent = max(level, (recentDB ?? level) - recentReleasePerWindowDB)
        recentDB = recent
        guard level > Self.silenceDBFS else { return }
        let peak = max(level, (peakDB ?? level) - releasePerWindowDB)
        peakDB = peak
        guard peak >= Self.floorDBFS, recent >= Self.floorDBFS else {
            gain = 0
            return
        }
        let change = min(Self.maximumBoostDB, max(-Self.maximumCutDB, Self.targetPeakDBFS - peak))
        gain = pow(10, change / 20)
    }
}
