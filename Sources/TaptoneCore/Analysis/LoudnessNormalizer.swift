import Foundation

/// Scales audio toward a steady reference loudness, so haptics follow a song's own dynamics rather than
/// how far the volume is turned up. The capture tap hears each app after its volume is applied, so the
/// range covers nearly the whole volume scale.
/// Gain follows the recent peak of short-window power: instant attack, slow release, held through silence.
/// Lifting is limited: music peaking near −42 dBFS still reaches full strength, but quieter sound is lifted
/// less and less (an expander below `kneeDBFS`), and sound under `floorDBFS`, such as room tone or a hum
/// nobody can hear, is muted rather than lifted to full strength, even while the slow peak still remembers
/// louder music.
struct LoudnessNormalizer: Sendable {
    static let targetPeakDBFS = -6.0
    static let maximumBoostDB = 36.0
    static let maximumCutDB = 12.0
    /// Below this peak, every decibel quieter loses `expansion` more decibels of boost.
    static let kneeDBFS = -44.0
    static let expansion = 3.0
    /// Below this, a window counts as silence and leaves the gain unchanged.
    static let silenceDBFS = -100.0
    /// Quieter than anything worth feeling, even with the volume well down.
    static let floorDBFS = -60.0
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

    /// Within a window, never lift a sample past full scale: out of silence the gain is set by a quiet first
    /// window, and the hit that follows would otherwise clip and read weaker than it is.
    mutating func limit(sample: Double) {
        let magnitude = abs(sample)
        if magnitude * gain > 1 { gain = 1 / magnitude }
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
        var change = min(Self.maximumBoostDB, max(-Self.maximumCutDB, Self.targetPeakDBFS - peak))
        if peak < Self.kneeDBFS { change -= Self.expansion * (Self.kneeDBFS - peak) }
        gain = pow(10, change / 20)
    }
}
