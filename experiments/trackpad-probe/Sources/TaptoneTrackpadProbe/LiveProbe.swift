import Foundation
import os
import TaptoneAudio

/// One foreground-terminal run. The actuator is only opened after the engine reports audible PCM.
enum LiveProbe {
    private enum End: Error { case windowElapsed }
    struct ShutdownReport: Sendable {
        let elapsedMs: Double
        let issues: [CaptureCleanupIssue]
    }
    static let startupSeconds = 15
    static let liveSeconds = 12
    static let shutdownTimeoutMs = 750

    static func run(checkStop: @escaping () throws -> Void, write: (String) -> Void) throws {
        let engine = CaptureEngine()
        let events = LiveEvents()
        let clock = ContinuousClock()
        let startupDeadline = clock.now + .seconds(startupSeconds)
        let startedAt = CaptureEngine.now()
        var liveDeadline: ContinuousClock.Instant?
        var stats = LiveStats()

        func check() throws {
            try checkStop()
            try events.check()
            if let liveDeadline {
                guard clock.now < liveDeadline else { throw End.windowElapsed }
            } else if clock.now >= startupDeadline {
                throw ProbeError(message: events.firstReportAtNs == nil
                    ? "No system audio arrived. If macOS asked for system audio access, allow it in System Settings and rerun."
                    : "System audio arrived, but it was quiet. Play the test clip when prompted and rerun.")
            }
        }

        let stopped = DispatchSemaphore(value: 0)
        let shutdown = OSAllocatedUnfairLock<ShutdownReport?>(initialState: nil)
        var shutdownDeadline: DispatchTime?
        func stopCapture() -> DispatchTime {
            if let shutdownDeadline { return shutdownDeadline }
            let requestedAt = CaptureEngine.now()
            let deadline = DispatchTime.now() + .milliseconds(shutdownTimeoutMs)
            shutdownDeadline = deadline
            engine.shutdown { issues in
                let elapsed = LiveStats.delta(CaptureEngine.now(), requestedAt)
                shutdown.withLock { $0 = ShutdownReport(elapsedMs: elapsed, issues: issues) }
                stopped.signal()
            }
            return deadline
        }

        try check()
        engine.start(id: UUID(), source: .system, sensitivity: .normal) {
            events.receive($0, at: CaptureEngine.now())
        }
        write("Play the test clip now. Rest a fingertip on the built-in trackpad. Ctrl-C stops the probe.")

        var failure: (any Error)?
        var windowElapsed = false
        do {
            var batch: [LiveEvents.Signal] = []
            while liveDeadline == nil {
                try check()
                batch = events.drain()
                if batch.contains(where: { $0.levelDBFS > -55 || $0.beatTimeNs != nil }) {
                    liveDeadline = clock.now + .seconds(liveSeconds)
                } else {
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }

            let actuator = try MultitouchActuator()
            // Stop HAL before closing the private actuator, which may block independently.
            try actuator.withBuiltInActuator(check: check, beforeClose: { _ = stopCapture() }) { request in
                while true {
                    for signal in batch {
                        try check()
                        guard let beat = signal.beatTimeNs else { continue }
                        stats.observe(beat: beat, reportedAt: signal.reportedAtNs)
                        var submittedAt: UInt64 = 0
                        guard stats.permit(beat: beat, at: CaptureEngine.now()) else { continue }
                        let sent = try request(.firmer) {
                            submittedAt = CaptureEngine.now()
                            return stats.permit(beat: beat, at: submittedAt)
                        }
                        if sent { stats.accept(submittedAt: submittedAt, completedAt: CaptureEngine.now()) }
                    }
                    try check()
                    Thread.sleep(forTimeInterval: 0.005)
                    batch = events.drain()
                }
            }
        } catch End.windowElapsed {
            windowElapsed = true
        } catch {
            failure = error
        }

        _ = stopped.wait(timeout: stopCapture())
        if windowElapsed { write("Live test window ended. No more pulses will be requested.") }
        let firstReportMs = events.firstReportAtNs.map { LiveStats.delta($0, startedAt) }
        stats.printSummary(startedAt: startedAt, firstReportMs: firstReportMs, dropped: events.dropped, write: write)
        if let failure = reportShutdown(shutdown.withLock({ $0 }), preserving: failure, write: write) {
            throw failure
        }
    }

    static func reportShutdown(_ result: ShutdownReport?, preserving primaryError: (any Error)?,
                               write: (String) -> Void) -> (any Error)? {
        var cleanupFailure: String?
        if let result, result.elapsedMs <= Double(shutdownTimeoutMs) {
            write("Capture shutdown callback: \(LiveStats.ms(result.elapsedMs)) ms from shutdown request")
        } else {
            cleanupFailure = "Capture shutdown callback did not arrive within \(shutdownTimeoutMs) ms."
        }
        if let result {
            if result.issues.isEmpty {
                write("HAL cleanup: no reported errors.")
            } else {
                let operations = result.issues.map { "\($0.operation) (\($0.status))" }.joined(separator: ", ")
                write("HAL cleanup errors: \(operations)")
                if cleanupFailure == nil { cleanupFailure = "HAL cleanup did not finish cleanly. Quit the probe before trying again." }
            }
        }
        if let cleanupFailure {
            guard let primaryError else { return ProbeError(message: cleanupFailure) }
            write(cleanupFailure)
            return primaryError
        }
        return primaryError
    }
}
