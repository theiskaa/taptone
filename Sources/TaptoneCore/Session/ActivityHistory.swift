/// Recent scalar readings for the chart, not PCM. Times are in the Core Audio host clock.
public struct ActivityHistory: Sendable {
    public struct Sample: Sendable {
        public let timeNs: UInt64
        public let levelDBFS: Float
        /// Peak trackpad motor command level (0...1) since the previous sample.
        public let motorLevel: Float
        /// Kicks played on the trackpad since the previous sample.
        public let kicks: Int
    }

    public static let durationNs: UInt64 = 12_000_000_000
    private static let capacity = 256
    public private(set) var samples: [Sample] = []
    /// Kicks played this session, including ones that have scrolled off the chart.
    public private(set) var kickCount = 0

    public init() {}

    /// When the newest kick still on the chart played.
    public var lastKickNs: UInt64? { samples.last { $0.kicks > 0 }?.timeNs }

    public mutating func record(at timeNs: UInt64, levelDBFS: Float, motorLevel: Float = 0, kicks: Int = 0) {
        if let last = samples.last, timeNs < last.timeNs { return }
        let cutoff = timeNs > Self.durationNs ? timeNs - Self.durationNs : 0
        let expired = samples.prefix { $0.timeNs < cutoff }.count
        samples.removeFirst(max(expired, samples.count - Self.capacity + 1))
        kickCount += max(0, kicks)
        let motor = motorLevel.isFinite ? min(1, max(0, motorLevel)) : 0
        samples.append(Sample(timeNs: timeNs, levelDBFS: levelDBFS, motorLevel: motor, kicks: max(0, kicks)))
    }
}
