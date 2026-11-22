/// Recent scalar readings, not PCM. Times are in the Core Audio host clock.
public struct ActivityHistory: Sendable {
    public struct Sample: Sendable {
        public let timeNs: UInt64
        public let levelDBFS: Float
        public let beatTimeNs: UInt64?
        public let tapRequested: Bool
    }

    public static let durationNs: UInt64 = 12_000_000_000
    private static let capacity = 256
    public private(set) var samples: [Sample] = []
    public private(set) var beatCount = 0
    public private(set) var tapCount = 0

    public init() {}

    public mutating func record(at timeNs: UInt64, levelDBFS: Float, beatTimeNs: UInt64?, tapRequested: Bool) {
        if let last = samples.last, timeNs < last.timeNs { return }
        let cutoff = timeNs > Self.durationNs ? timeNs - Self.durationNs : 0
        let expired = samples.prefix { $0.timeNs < cutoff }.count
        samples.removeFirst(max(expired, samples.count - Self.capacity + 1))

        let requested = beatTimeNs != nil && tapRequested
        if beatTimeNs != nil { beatCount += 1 }
        if requested { tapCount += 1 }
        samples.append(Sample(timeNs: timeNs, levelDBFS: levelDBFS, beatTimeNs: beatTimeNs, tapRequested: requested))
    }
}
