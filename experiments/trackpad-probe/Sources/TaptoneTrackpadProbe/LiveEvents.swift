import os
import TaptoneAudio

/// Pass scalar reports from the capture queue to the probe, never PCM. A failure takes priority over queued cues.
final class LiveEvents: Sendable {
    struct Signal: Sendable {
        let levelDBFS: Float
        let beatTimeNs: UInt64?
        let reportedAtNs: UInt64
    }

    private struct State {
        var pending: [Signal] = []
        var firstReportAtNs: UInt64?
        var dropped = 0
        var failure: String?
    }

    static let capacity = 16
    private let state = OSAllocatedUnfairLock(initialState: State())

    func receive(_ event: CaptureEngine.Event, at time: UInt64) {
        state.withLock { state in
            switch event {
            case .signal(let level, let beat):
                if state.firstReportAtNs == nil { state.firstReportAtNs = time }
                if state.pending.count == Self.capacity {
                    state.pending.removeFirst()
                    state.dropped += 1
                }
                state.pending.append(Signal(levelDBFS: level, beatTimeNs: beat, reportedAtNs: time))
            case .failed(let error):
                state.failure = error
            }
        }
    }

    func check() throws {
        if let failure = state.withLock({ $0.failure }) { throw ProbeError(message: failure) }
    }

    func drain() -> [Signal] {
        state.withLock { state in
            let pending = state.pending
            state.pending.removeAll()
            return pending
        }
    }

    var dropped: Int { state.withLock { $0.dropped } }
    var firstReportAtNs: UInt64? { state.withLock { $0.firstReportAtNs } }
}
