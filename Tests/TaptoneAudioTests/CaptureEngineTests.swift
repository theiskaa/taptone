import CoreAudio
import Foundation
import os
@testable import TaptoneAudio
import Testing

@Suite struct CaptureEngineTests {
    @Test func outputChangeReportsFailureBeforeBlockedTapTeardown() {
        let reachedStop = DispatchSemaphore(value: 0)
        let allowStop = DispatchSemaphore(value: 0)
        let receivedFailure = DispatchSemaphore(value: 0)
        let engine = CaptureEngine {
            try TestTap(prepare: { queue, routeChange in queue.async(execute: routeChange) }, stop: {
                reachedStop.signal()
                _ = allowStop.wait(timeout: .now() + .seconds(2))
                return []
            })
        }
        engine.start(id: UUID(), source: .system, sensitivity: .normal) { event in
            if case .failed(let message) = event, message.contains("output changed") {
                receivedFailure.signal()
            }
        }
        #expect(reachedStop.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(receivedFailure.wait(timeout: .now()) == .success)
        allowStop.signal()
        let shutdown = DispatchSemaphore(value: 0)
        engine.shutdown { _ in shutdown.signal() }
        #expect(shutdown.wait(timeout: .now() + .seconds(1)) == .success)
    }

    @Test func cancellingPreparationSkipsIOStartAndAnOldRouteChangeCannotStopTheReplacement() {
        let prepared = DispatchSemaphore(value: 0)
        let allowPrepare = DispatchSemaphore(value: 0)
        let oldRouteRan = DispatchSemaphore(value: 0)
        let oldRoute = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        let actions = OSAllocatedUnfairLock<[String]>(initialState: [])
        let engine = CaptureEngine {
            try TestTap(prepare: { queue, routeChange in
                oldRoute.withLock { value in
                    value = { queue.async { routeChange(); oldRouteRan.signal() } }
                }
                prepared.signal()
                _ = allowPrepare.wait(timeout: .now() + .seconds(2))
            }, start: { _ in
                actions.withLock { $0.append("old I/O started") }
            }, stop: {
                actions.withLock { $0.append("old I/O cleaned up") }
                return []
            })
        }
        let oldID = UUID()
        engine.start(id: oldID, source: .system, sensitivity: .normal) { _ in
            actions.withLock { $0.append("old session reported an event") }
        }
        #expect(prepared.wait(timeout: .now() + .seconds(1)) == .success)
        engine.stop(id: oldID)
        let newBeat = DispatchSemaphore(value: 0)
        engine.start(id: UUID(), source: .demo, sensitivity: .normal) { event in
            if case .signal(_, .some) = event { newBeat.signal() }
            if case .failed = event { actions.withLock { $0.append("new session failed") } }
        }
        oldRoute.withLock { $0 }?()
        allowPrepare.signal()
        #expect(oldRouteRan.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(newBeat.wait(timeout: .now() + .seconds(2)) == .success)
        let stopped = DispatchSemaphore(value: 0)
        engine.shutdown { _ in stopped.signal() }
        #expect(stopped.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(actions.withLock { $0 } == ["old I/O cleaned up"])
    }

    @Test func aConcurrentCallerCanRestartOnlyAfterThePreviousTapFinishesShutdown() {
        let firstStarted = DispatchSemaphore(value: 0)
        let firstStopping = DispatchSemaphore(value: 0)
        let allowFirstStop = DispatchSemaphore(value: 0)
        let replacementSubmitted = DispatchSemaphore(value: 0)
        let replacementStarted = DispatchSemaphore(value: 0)
        let actions = OSAllocatedUnfairLock<[String]>(initialState: [])
        let count = OSAllocatedUnfairLock(initialState: 0)
        let engine = CaptureEngine {
            let first = count.withLock { count in count += 1; return count == 1 }
            return try TestTap(start: { _ in
                actions.withLock { $0.append(first ? "first started" : "second started") }
                (first ? firstStarted : replacementStarted).signal()
            }, stop: {
                if first {
                    firstStopping.signal()
                    _ = allowFirstStop.wait(timeout: .now() + .seconds(2))
                    actions.withLock { $0.append("first stopped") }
                }
                return []
            })
        }
        engine.start(id: UUID(), source: .system, sensitivity: .normal) { _ in }
        #expect(firstStarted.wait(timeout: .now() + .seconds(1)) == .success)
        DispatchQueue.global().async {
            engine.shutdown { _ in actions.withLock { $0.append("shutdown callback") } }
        }
        #expect(firstStopping.wait(timeout: .now() + .seconds(1)) == .success)
        DispatchQueue.global().async {
            engine.start(id: UUID(), source: .system, sensitivity: .normal) { _ in }
            replacementSubmitted.signal()
        }
        #expect(replacementSubmitted.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(count.withLock { $0 } == 1)
        allowFirstStop.signal()
        #expect(replacementStarted.wait(timeout: .now() + .seconds(1)) == .success)
        let stopped = DispatchSemaphore(value: 0)
        engine.shutdown { _ in stopped.signal() }
        #expect(stopped.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(actions.withLock { $0 } == ["first started", "first stopped", "shutdown callback", "second started"])
    }

    @Test func cancellingBlockedIOStartDisposesWithoutPublishingItsFirstPCM() {
        let starting = DispatchSemaphore(value: 0)
        let allowStart = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
        let engine = CaptureEngine {
            try TestTap(start: { mailbox in
                starting.signal()
                _ = allowStart.wait(timeout: .now() + .seconds(2))
                writeSilence(to: mailbox)
            }, stop: {
                calls.withLock { $0.append("tap released") }
                return []
            })
        }
        let id = UUID()
        engine.start(id: id, source: .system, sensitivity: .normal) { _ in
            calls.withLock { $0.append("unexpected event") }
        }
        #expect(starting.wait(timeout: .now() + .seconds(1)) == .success)
        engine.stop(id: id)
        let stopped = DispatchSemaphore(value: 0)
        engine.shutdown { _ in stopped.signal() }
        allowStart.signal()
        #expect(stopped.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(calls.withLock { $0 } == ["tap released"])
    }

    @Test func aSetupFailureReturnsCleanupIssuesAndDisablesAnotherSystemStart() {
        let actions = OSAllocatedUnfairLock<[String]>(initialState: [])
        let issue = CaptureCleanupIssue(operation: "remove audio callback", status: -1)
        let engine = CaptureEngine {
            actions.withLock { $0.append("created") }
            return try TestTap(start: { _ in throw CaptureFailure("Start failed") }, stop: {
                actions.withLock { $0.append("cleaned up") }
                return [issue]
            })
        }
        let errors = OSAllocatedUnfairLock<[String]>(initialState: [])
        let report = DispatchSemaphore(value: 0)
        let onEvent: CaptureEngine.Report = { event in
            if case .failed(let message) = event {
                errors.withLock { $0.append(message) }
                report.signal()
            }
        }
        engine.start(id: UUID(), source: .system, sensitivity: .normal, report: onEvent)
        #expect(report.wait(timeout: .now() + .seconds(1)) == .success)
        engine.start(id: UUID(), source: .system, sensitivity: .normal, report: onEvent)
        #expect(report.wait(timeout: .now() + .seconds(1)) == .success)
        let shutdown = DispatchSemaphore(value: 0)
        let issues = OSAllocatedUnfairLock<[CaptureCleanupIssue]>(initialState: [])
        engine.shutdown { result in
            issues.withLock { $0 = result }
            shutdown.signal()
        }
        #expect(shutdown.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(errors.withLock { $0.first } == "Start failed")
        #expect(errors.withLock { $0.last?.contains("Quit and reopen Taptone") } == true)
        #expect(actions.withLock { $0 } == ["created", "cleaned up"])
        #expect(issues.withLock { $0 } == [issue])
    }

    @Test(arguments: [false, true])
    func distinguishesNoPCMFromSilenceThenAStalledStream(sendsSilentPCM: Bool) {
        let engine = CaptureEngine(timeouts: .init(firstBufferNs: 20_000_000, stalledStreamNs: 40_000_000)) {
            try TestTap(start: { mailbox in
                if sendsSilentPCM { writeSilence(to: mailbox) }
            })
        }
        let reports = OSAllocatedUnfairLock<[String]>(initialState: [])
        let failed = DispatchSemaphore(value: 0)
        engine.start(id: UUID(), source: .system, sensitivity: .normal) { event in
            switch event {
            case .signal(let level, let beat):
                reports.withLock { $0.append(level <= -55 && beat == nil ? "quiet" : "unexpected cue") }
            case .failed(let message):
                reports.withLock { $0.append(message) }
                failed.signal()
            }
        }
        #expect(failed.wait(timeout: .now() + .seconds(1)) == .success)
        let stopped = DispatchSemaphore(value: 0)
        engine.shutdown { _ in stopped.signal() }
        #expect(stopped.wait(timeout: .now() + .seconds(1)) == .success)
        let observed = reports.withLock { $0 }
        if sendsSilentPCM {
            #expect(observed.count == 2)
            #expect(observed.first == "quiet")
            #expect(observed.last?.hasPrefix("The audio stream stopped.") == true)
        } else {
            #expect(observed.count == 1)
            #expect(observed.first?.hasPrefix("No audio data arrived.") == true)
        }
    }

    @Test func ownedPCMRemainsReadableAfterStopAndQueuedPacketsAreDiscarded() {
        let first = DispatchSemaphore(value: 0)
        let shutdown = DispatchSemaphore(value: 0)
        let packets = OSAllocatedUnfairLock<[CapturePCM]>(initialState: [])
        let id = UUID()
        let engine = CaptureEngine {
            try TestTap(start: { mailbox in
                writeSilence(to: mailbox)
                writeSilence(to: mailbox)
            })
        }
        engine.start(id: id, source: .system, sensitivity: .normal, consumePCM: { packet in
            packets.withLock { $0.append(packet) }
            engine.stop(id: id)
            first.signal()
        }, report: { _ in })
        #expect(first.wait(timeout: .now() + .seconds(1)) == .success)
        engine.shutdown { _ in shutdown.signal() }
        #expect(shutdown.wait(timeout: .now() + .seconds(1)) == .success)
        let observed = packets.withLock { $0 }
        #expect(observed.count == 1)
        #expect(observed.first?.sampleRate == 48_000)
        #expect(observed.first?.stereo == [Float](repeating: 0, count: 1_024))
        #expect(observed.first?.discontinuity == false)
    }

    @Test func stalePCMIsDiscardedAndOnlyTheNextPacketStartsANewSegment() {
        let complete = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let packets = OSAllocatedUnfairLock<[CapturePCM]>(initialState: [])
        let engine = CaptureEngine {
            try TestTap(start: { mailbox in
                let now = CaptureEngine.now()
                writeSilence(to: mailbox, at: now > 1_000_000_000 ? now - 1_000_000_000 : 0)
                writeSilence(to: mailbox, at: now)
                writeSilence(to: mailbox, at: now + 11_000_000)
            })
        }
        engine.start(id: UUID(), source: .system, sensitivity: .normal, consumePCM: { packet in
            if packets.withLock({ $0.append(packet); return $0.count == 2 }) { complete.signal() }
        }, report: { _ in })
        #expect(complete.wait(timeout: .now() + .seconds(1)) == .success)
        engine.shutdown { _ in stopped.signal() }
        #expect(stopped.wait(timeout: .now() + .seconds(1)) == .success)
        let observed = packets.withLock { $0 }
        #expect(observed.map(\.discontinuity) == [true, false])
        if observed.count == 2 {
            #expect(observed[1].hostTimeNs == observed[0].hostTimeNs + 11_000_000)
        }
    }

    @Test func demoSessionReportsBeatsAndSurvivesAnUnrelatedStop() async throws {
        let engine = CaptureEngine()
        let id = UUID()
        let (events, output) = AsyncStream<CaptureEngine.Event>.makeStream(bufferingPolicy: .bufferingNewest(16))
        engine.start(id: id, source: .demo, sensitivity: .normal) { output.yield($0) }
        engine.stop(id: UUID())

        let received = await withTaskGroup(of: Bool.self) { tasks in
            tasks.addTask {
                for await event in events {
                    if case .signal(let level, let beat) = event, level > -55, beat != nil { return true }
                }
                return false
            }
            tasks.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await tasks.next() ?? false
            tasks.cancelAll()
            return first
        }
        await withCheckedContinuation { continuation in
            engine.stop(id: id)
            engine.shutdown { _ in
                output.finish()
                continuation.resume()
            }
        }
        #expect(received)
    }
}

private func writeSilence(to mailbox: TapMailbox, at hostTimeNs: UInt64 = CaptureEngine.now()) {
    var samples = [Float](repeating: 0, count: 512)
    samples.withUnsafeMutableBytes { samples in
        var buffer = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(samples.count), mData: samples.baseAddress
        ))
        mailbox.write(&buffer, hostTimeNs: hostTimeNs)
    }
}

private final class TestTap: CaptureTap {
    let mailbox: TapMailbox
    let sampleRate = 48_000.0
    private let onPrepare: (DispatchQueue, @escaping @Sendable () -> Void) throws -> Void
    private let onStart: (TapMailbox) throws -> Void
    private let onStop: () -> [CaptureCleanupIssue]

    init(prepare: @escaping (DispatchQueue, @escaping @Sendable () -> Void) throws -> Void = { _, _ in },
         start: @escaping (TapMailbox) throws -> Void = { _ in },
         stop: @escaping () -> [CaptureCleanupIssue] = { [] }) throws {
        guard let mailbox = TapMailbox() else { throw CaptureFailure("Couldn’t allocate test mailbox.") }
        self.mailbox = mailbox
        onPrepare = prepare
        onStart = start
        onStop = stop
    }

    func prepare(queue: DispatchQueue, onRouteChange: @escaping @Sendable () -> Void) throws {
        try onPrepare(queue, onRouteChange)
    }

    func start() throws { try onStart(mailbox) }
    func stop() -> [CaptureCleanupIssue] { onStop() }
}
