/// Holds analysis cues until the audio they describe reaches the listener.
/// Ask for the moment being heard (`now − output latency`); older cues are discarded, never replayed.
public struct HapticTimeline: Sendable {
    public static let capacity = 512
    /// A cue this old no longer describes what's playing (capture stalled or stopped).
    public static let maximumCueAgeNs: UInt64 = 50_000_000
    /// A kick due longer ago than this would feel late; skip it rather than play it out of time.
    public static let maximumKickLatenessNs: UInt64 = 60_000_000

    private var cues: [HapticCue] = []
    private var kicksThroughNs: UInt64?

    public init() {
        cues.reserveCapacity(Self.capacity)
    }

    public var count: Int { cues.count }

    public mutating func append(_ cue: HapticCue) {
        if let last = cues.last, cue.timeNs <= last.timeNs { return }
        if cues.count >= Self.capacity { cues.removeFirst(cues.count - Self.capacity + 1) }
        cues.append(cue)
    }

    /// The cue describing `audioNs` and the strongest kick that became due since the last call.
    public mutating func take(at audioNs: UInt64) -> (cue: HapticCue?, onset: Double?) {
        guard let index = cues.lastIndex(where: { $0.timeNs <= audioNs }) else { return (nil, nil) }
        var onset: Double?
        for cue in cues[...index] {
            guard let strength = cue.onset, kicksThroughNs.map({ cue.timeNs > $0 }) ?? true,
                  audioNs - cue.timeNs <= Self.maximumKickLatenessNs else { continue }
            onset = max(onset ?? 0, strength)
        }
        let current = cues[index]
        kicksThroughNs = current.timeNs
        cues.removeFirst(index)
        return (audioNs - current.timeNs <= Self.maximumCueAgeNs ? current : nil, onset)
    }
}
