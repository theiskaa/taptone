import AudioMailbox
import Foundation
import os
import OSLog
import TaptoneCore

/// Use a fresh ID for each start and keep callbacks short. All HAL and detector work lives on one serial queue.
/// Call `shutdown` before discarding an engine that has started capture; releasing the engine is not shutdown.
public final class CaptureEngine: @unchecked Sendable {
    public enum Source: Sendable { case system, demo }

    public enum Event: Sendable {
        /// A beat timestamp is in the Core Audio host clock, not an estimate of when it was heard.
        case signal(levelDBFS: Float, beatTimeNs: UInt64?)
        case failed(String)
    }

    public typealias Report = @Sendable (Event) -> Void

    struct Timeouts {
        var firstBufferNs: UInt64 = 12_000_000_000
        var stalledStreamNs: UInt64 = 5_000_000_000
    }

    private let queue = DispatchQueue(label: "com.theiskaa.taptone.capture", qos: .userInitiated)
    private let requested = OSAllocatedUnfairLock<UUID?>(initialState: nil)
    private let diagnostics: Bool
    private let timeouts: Timeouts
    private let makeTap: @Sendable () throws -> any CaptureTap
    private let log = Logger(subsystem: "com.theiskaa.taptone", category: "Capture")
    private var session: Session?
    private var cleanupIssues: [CaptureCleanupIssue] = []

    public convenience init(diagnostics: Bool = false) {
        self.init(diagnostics: diagnostics, makeTap: { try SystemAudioTap() })
    }

    init(diagnostics: Bool = false, timeouts: Timeouts = Timeouts(),
         makeTap: @escaping @Sendable () throws -> any CaptureTap) {
        self.diagnostics = diagnostics
        self.timeouts = timeouts
        self.makeTap = makeTap
    }

    public func start(id: UUID, source: Source, sensitivity: BeatDetector.Sensitivity, report: @escaping Report) {
        enqueue(updating: { $0 = id }) { [self] in
            guard isRequested(id) else { return }
            end()
            guard isRequested(id) else { return }
            let next = Session(id: id, sensitivity: sensitivity, report: report)
            session = next
            do {
                if source == .system {
                    guard cleanupIssues.isEmpty else {
                        throw CaptureFailure("The previous audio session didn’t close cleanly. Quit and reopen Taptone before listening again.")
                    }
                    let tap = try makeTap()
                    next.tap = tap
                    guard isRequested(id) else { end(); return }
                    try tap.prepare(queue: queue) { [weak self] in
                        self?.fail(id, "Audio output changed. Start listening again to use the new output.")
                    }
                    guard isRequested(id) else { end(); return }
                    next.configure(sampleRate: tap.sampleRate)
                    try tap.start()
                    if diagnostics { log.info("Tap started at \(tap.sampleRate, privacy: .public) Hz; waiting for PCM") }
                } else {
                    next.demo = DemoBeat()
                    next.configure(sampleRate: DemoBeat.sampleRate)
                }
                guard isRequested(id) else { end(); return }
                next.startedAt = Self.now()
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.tick(id) }
                next.timer = timer
                timer.resume()
            } catch {
                fail(id, error.localizedDescription)
            }
        }
    }

    public func setSensitivity(_ sensitivity: BeatDetector.Sensitivity, id: UUID) {
        queue.async { [self] in
            guard let session, session.id == id else { return }
            session.sensitivity = sensitivity
            session.detector?.sensitivity = sensitivity
        }
    }

    public func stop(id: UUID) {
        enqueue(updating: { if $0 == id { $0 = nil } }) { [self] in
            if session?.id == id { end() }
        }
    }

    /// Reports HAL cleanup errors retained for this engine’s lifetime; this engine will refuse further system capture.
    public func shutdown(then completion: @escaping @Sendable ([CaptureCleanupIssue]) -> Void) {
        enqueue(updating: { $0 = nil }) { [self] in
            end()
            completion(cleanupIssues)
        }
    }

    private func enqueue(updating: @Sendable (inout UUID?) -> Void, _ work: @escaping @Sendable () -> Void) {
        // Keep request invalidation and queue insertion in the same order, even across callers.
        requested.withLock { id in
            updating(&id)
            queue.async(execute: work)
        }
    }

    public static func now() -> UInt64 { SystemAudioTap.hostTimeNs() }

    private func isRequested(_ id: UUID) -> Bool { requested.withLock { $0 == id } }

    private func tick(_ id: UUID) {
        guard let session, session.id == id, isRequested(id) else { return }
        let now = Self.now()
        if let tap = session.tap {
            let awaitingFirst = session.lastBufferAt == nil
            session.drain(tap.mailbox, now: now)
            if diagnostics, awaitingFirst, session.lastBufferAt != nil {
                let startupMs = Double(now - session.startedAt) / 1_000_000
                log.info("First PCM buffer arrived \(startupMs, format: .fixed(precision: 1), privacy: .public) ms after tap startup")
            }
            let last = session.lastBufferAt ?? session.startedAt
            let timeout = session.lastBufferAt == nil ? timeouts.firstBufferNs : timeouts.stalledStreamNs
            if now - last >= timeout {
                fail(id, session.lastBufferAt == nil
                    ? "No audio data arrived. Play audio and check system audio access in Privacy & Security, then try again."
                    : "The audio stream stopped. Start listening again when your audio output is ready.")
                return
            }
        } else {
            session.generateDemo(now: now)
        }
        if isRequested(id) { session.sendUpdate(now: now) }
    }

    private func fail(_ id: UUID, _ message: String) {
        guard let session, session.id == id else { return }
        // Invalidate consumers' pending cues before HAL teardown, which can block.
        defer { end() }
        let shouldReport = requested.withLock { requested in
            guard requested == id else { return false }
            requested = nil
            return true
        }
        if diagnostics { log.info("Capture stopped: \(message, privacy: .public)") }
        if shouldReport { session.report(.failed(message)) }
    }

    private func end() {
        guard let old = session else { return }
        session = nil
        old.timer?.cancel()
        if let issues = old.tap?.stop(), !issues.isEmpty { cleanupIssues = issues }
    }
}

protocol CaptureTap: AnyObject {
    var mailbox: TapMailbox { get }
    var sampleRate: Double { get }
    func prepare(queue: DispatchQueue, onRouteChange: @escaping @Sendable () -> Void) throws
    func start() throws
    func stop() -> [CaptureCleanupIssue]
}

extension SystemAudioTap: CaptureTap {}

private final class Session {
    let id: UUID
    let report: CaptureEngine.Report
    var sensitivity: BeatDetector.Sensitivity
    var tap: (any CaptureTap)?
    var demo: DemoBeat?
    var detector: BeatDetector?
    var timer: DispatchSourceTimer?
    var startedAt: UInt64 = 0
    var lastBufferAt: UInt64?

    private var sampleRate = 0.0
    private var nsPerFrame = 0.0
    private var level: Float = -90
    private var beat: UInt64?
    private var lastUpdate: UInt64?
    private var generatedFrames = 0

    init(id: UUID, sensitivity: BeatDetector.Sensitivity, report: @escaping CaptureEngine.Report) {
        self.id = id
        self.sensitivity = sensitivity
        self.report = report
    }

    func configure(sampleRate: Double) {
        self.sampleRate = sampleRate
        nsPerFrame = 1_000_000_000 / sampleRate
        resetDetector()
    }

    private func resetDetector() {
        detector = BeatDetector(sampleRate: sampleRate)
        detector?.sensitivity = sensitivity
        beat = nil
        level = -90
    }

    func drain(_ mailbox: TapMailbox, now: UInt64) {
        var packet = TTAudioPacket()
        for _ in 0..<TTMailboxSlots {
            guard tt_mailbox_peek(mailbox.storage, &packet) else { break }
            defer { tt_mailbox_consume(mailbox.storage) }
            guard let stereo = packet.stereo else { continue }
            lastBufferAt = now
            let end = packet.hostTimeNs + UInt64(Double(packet.frames) * nsPerFrame)
            guard end >= now || now - end < PulseTiming.maximumAge else {
                resetDetector()
                continue
            }
            if packet.discontinuity { resetDetector() }
            for frame in 0..<Int(packet.frames) {
                if let reading = detector?.push(left: stereo[2 * frame], right: stereo[2 * frame + 1]) {
                    record(reading, at: packet.hostTimeNs + UInt64(Double(frame) * nsPerFrame))
                }
            }
        }
    }

    func generateDemo(now: UInt64) {
        let target = Int(Double(now - startedAt) / nsPerFrame)
        // Don’t run an unbounded catch-up loop after a long scheduler pause.
        if target - generatedFrames > Int(sampleRate / 4) {
            startedAt = now
            generatedFrames = 0
            demo = DemoBeat()
            resetDetector()
            return
        }
        while generatedFrames < target, let sample = demo?.nextSample() {
            if let reading = detector?.push(left: sample, right: sample) {
                record(reading, at: startedAt + UInt64(Double(generatedFrames) * nsPerFrame))
            }
            generatedFrames += 1
            lastBufferAt = now
        }
    }

    private func record(_ reading: BeatDetector.Reading, at time: UInt64) {
        level = max(level, reading.levelDBFS)
        if reading.isBeat { beat = time }
    }

    func sendUpdate(now: UInt64) {
        guard lastBufferAt != nil else { return }
        if let beat, !PulseTiming.isFresh(beat, at: now) { self.beat = nil }
        guard beat != nil || lastUpdate.map({ now - $0 >= 150_000_000 }) ?? true else { return }
        report(.signal(levelDBFS: level, beatTimeNs: beat))
        level = -90
        beat = nil
        lastUpdate = now
    }
}
