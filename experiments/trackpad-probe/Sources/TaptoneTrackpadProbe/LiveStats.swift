import Foundation

/// Accumulates scalar timing data only. No formatting or terminal writes happen while requesting pulses.
struct LiveStats {
    private struct Beat {
        let time: UInt64
        let reportOffsetMs: Double
        var requestOffsetMs: Double?
    }

    static let traceCapacity = 128
    private var trace: [Beat] = []
    private var beats = 0
    private var stale = 0
    private var spacedOut = 0
    private var capped = 0
    private var budget = LivePulseBudget()

    mutating func observe(beat: UInt64, reportedAt: UInt64) {
        beats += 1
        if trace.count < Self.traceCapacity {
            trace.append(Beat(time: beat, reportOffsetMs: Self.delta(reportedAt, beat)))
        }
    }

    mutating func permit(beat: UInt64, at now: UInt64) -> Bool {
        switch budget.decision(beat: beat, now: now) {
        case .send: return true
        case .stale: stale += 1
        case .tooSoon: spacedOut += 1
        case .exhausted: capped += 1
        }
        return false
    }

    /// Called synchronously for the most recently observed cue, after the driver accepts it.
    mutating func accept(submittedAt: UInt64, completedAt: UInt64) {
        budget.recordCompleted(at: completedAt)
        guard beats > 0, trace.count == beats else { return }
        let index = trace.count - 1
        trace[index].requestOffsetMs = Self.delta(submittedAt, trace[index].time)
    }

    func printSummary(startedAt: UInt64, firstReportMs: Double?, dropped: Int, write: (String) -> Void) {
        if let firstReportMs { write("First PCM report: \(Self.ms(firstReportMs)) ms from Start") }
        else { write("No PCM report observed.") }
        write("Beat reports processed: \(beats) · Driver-accepted requests: \(budget.count)")
        write("Skipped: \(stale) stale, \(spacedOut) rate-limited, \(capped) over cap · \(dropped) reports dropped by probe")
        if beats > trace.count { write("Timings below cover the first \(trace.count) beat reports.") }
        if let p95 = Self.percentile95(trace.map(\.reportOffsetMs)) {
            write("Detector hop → capture report p95: \(Self.ms(p95)) ms")
        }
        if let p95 = Self.percentile95(trace.compactMap(\.requestOffsetMs)) {
            write("Detector hop → pulse request p95: \(Self.ms(p95)) ms")
        }
        if !trace.isEmpty {
            write("Beat trace (hop time relative to probe Start; 120 BPM kicks are 500 ms apart):")
            write("beat,hop_since_start_ms,gap_ms,hop_to_report_ms,hop_to_accepted_request_ms")
            for (index, beat) in trace.enumerated() {
                let hop = Self.ms(Self.delta(beat.time, startedAt))
                let gap = index > 0 ? Self.ms(Self.delta(beat.time, trace[index - 1].time)) : ""
                write("\(index + 1),\(hop),\(gap),\(Self.ms(beat.reportOffsetMs)),\(beat.requestOffsetMs.map(Self.ms) ?? "")")
            }
        }
        write("Software measurements only: a request is not confirmation of a felt tap or playback-to-touch timing.")
    }

    static func delta(_ later: UInt64, _ earlier: UInt64) -> Double { (Double(later) - Double(earlier)) / 1_000_000 }
    static func ms(_ value: Double) -> String { String(format: "%.1f", value) }

    private static func percentile95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[Int((Double(values.count) * 0.95).rounded(.up)) - 1]
    }
}
