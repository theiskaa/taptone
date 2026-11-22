import Foundation
@testable import TaptoneAudio
@testable import TaptoneTrackpadProbe
import Testing

@Suite struct LiveProbeTests {
    @Test func shutdownReportsAHALProblemEvenWhenTheCallbackWasTimely() {
        let issue = CaptureCleanupIssue(operation: "destroy aggregate device", status: -123)
        let clean = LiveProbe.ShutdownReport(elapsedMs: 10, issues: [])
        let dirty = LiveProbe.ShutdownReport(elapsedMs: 10, issues: [issue])
        var lines: [String] = []
        let success = LiveProbe.reportShutdown(clean, preserving: nil) { lines.append($0) }
        #expect(success == nil)
        #expect(lines.last == "HAL cleanup: no reported errors.")
        let error = LiveProbe.reportShutdown(dirty, preserving: nil) { lines.append($0) }
        #expect(error?.localizedDescription.contains("did not finish cleanly") == true)
        #expect(lines.last == "HAL cleanup errors: destroy aggregate device (-123)")
    }

    @Test func lateShutdownDoesNotMaskTheOriginalFailure() {
        let late = LiveProbe.ShutdownReport(elapsedMs: 751, issues: [])
        let timeout = LiveProbe.reportShutdown(nil, preserving: nil) { _ in }
        #expect(timeout?.localizedDescription.contains("within 750 ms") == true)
        var lines: [String] = []
        let original = ProbeError(message: "Input changed")
        let error = LiveProbe.reportShutdown(late, preserving: original) { lines.append($0) }
        #expect(error?.localizedDescription == "Input changed")
        #expect(lines.last?.contains("within 750 ms") == true)
    }

    @Test func tracePreservesGapsAndDistinguishesReportsFromAcceptedRequests() {
        let start: UInt64 = 30_000_000_000
        let first = start + 1_000_000_000
        let second = first + 1_000_000_000
        var stats = LiveStats()
        stats.observe(beat: first, reportedAt: first + 10_000_000)
        stats.accept(submittedAt: first + 21_000_000, completedAt: first + 22_000_000)
        stats.observe(beat: second, reportedAt: second + 15_000_000)
        let permitted = stats.permit(beat: second, at: second + 120_000_000)
        #expect(!permitted)

        var lines: [String] = []
        stats.printSummary(startedAt: start, firstReportMs: 90, dropped: 0) { lines.append($0) }
        #expect(lines.contains("Beat reports processed: 2 · Driver-accepted requests: 1"))
        #expect(lines.contains("Detector hop → pulse request p95: 21.0 ms"))
        #expect(lines.contains("1,1000.0,,10.0,21.0"))
        #expect(lines.contains("2,2000.0,1000.0,15.0,"))
    }

    @Test func traceCapPreservesTotalCountAndDoesNotOverwriteLastTracedBeat() {
        var stats = LiveStats()
        for i in 0...LiveStats.traceCapacity {
            let beat = UInt64(i) * 500_000_000
            stats.observe(beat: beat, reportedAt: beat)
        }
        let last = UInt64(LiveStats.traceCapacity) * 500_000_000
        stats.accept(submittedAt: last + 20_000_000, completedAt: last + 21_000_000)

        var lines: [String] = []
        stats.printSummary(startedAt: 0, firstReportMs: 0, dropped: 0) { lines.append($0) }
        #expect(lines.contains("Beat reports processed: 129 · Driver-accepted requests: 1"))
        #expect(lines.contains("Timings below cover the first 128 beat reports."))
        #expect(lines.contains("128,63500.0,500.0,0.0,"))
        #expect(!lines.contains { $0.hasPrefix("129,") || $0.hasPrefix("Detector hop → pulse request p95:") })
    }

    @Test func budgetRejectsOldCuesAndSpacesRequestsFromLastCompletion() {
        let start: UInt64 = 1_000_000_000
        var budget = LivePulseBudget()
        #expect(budget.decision(beat: start - 120_000_000, now: start) == .stale)
        #expect(budget.decision(beat: start + 25_000_000, now: start) == .stale)
        #expect(budget.decision(beat: start, now: start) == .send)
        budget.recordCompleted(at: start + 10_000_000)
        let eligible = start + 10_000_000 + LivePulseBudget.minimumSpacingNs
        #expect(budget.decision(beat: eligible - 1, now: eligible - 1) == .tooSoon)
        #expect(budget.decision(beat: eligible, now: eligible) == .send)
    }

    @Test func budgetCapsRequestsEvenWhenMoreFreshBeatsArrive() {
        var budget = LivePulseBudget()
        for i in 0..<20 {
            let time = UInt64(i) * LivePulseBudget.minimumSpacingNs
            #expect(budget.decision(beat: time, now: time) == .send)
            budget.recordCompleted(at: time)
        }
        let next = 20 * LivePulseBudget.minimumSpacingNs
        #expect(budget.count == 20)
        #expect(budget.decision(beat: next, now: next) == .exhausted)
    }

    @Test func scalarInboxStaysBoundedAndAFailureSurvivesDraining() throws {
        let inbox = LiveEvents()
        let count = UInt64(LiveEvents.capacity + 2)
        for timestamp in 0..<count {
            inbox.receive(.signal(levelDBFS: -12, beatTimeNs: timestamp), at: timestamp + 1)
        }
        inbox.receive(.failed("Output changed"), at: count)
        #expect(throws: ProbeError.self) { try inbox.check() }
        let batch = inbox.drain()
        #expect(batch.map(\.reportedAtNs) == Array(3...count))
        #expect(batch.map(\.beatTimeNs) == (2..<count).map { Optional($0) })
        #expect(inbox.dropped == 2)
        #expect(inbox.firstReportAtNs == 1)
        #expect(inbox.drain().isEmpty)
        #expect(throws: ProbeError.self) { try inbox.check() }
    }
}
