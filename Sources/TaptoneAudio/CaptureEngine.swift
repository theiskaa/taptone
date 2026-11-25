import AudioMailbox
import Foundation
import os
import OSLog
import TaptoneCore

/// An owned copy made on the capture worker, never on the HAL callback.
public struct CapturePCM: Sendable {
    public let stereo: [Float]
    public let sampleRate: Double
    /// Timestamp of the packet start in the Core Audio host clock, not speaker output time.
    public let hostTimeNs: UInt64
    /// First delivered packet after a gap, stale-buffer discard, or mailbox overrun.
    public let discontinuity: Bool

    public init(stereo: [Float], sampleRate: Double, hostTimeNs: UInt64, discontinuity: Bool) {
        self.stereo = stereo
        self.sampleRate = sampleRate
        self.hostTimeNs = hostTimeNs
        self.discontinuity = discontinuity
    }
}

/// Use a fresh ID for each start and keep callbacks short. All HAL and detector work lives on one serial queue.
/// Call `shutdown` before discarding an engine that has started capture; releasing the engine is not shutdown.
public final class CaptureEngine: @unchecked Sendable {
    public enum Source: Sendable { case system, demo }

    public enum Event: Sendable {
        /// A beat timestamp is in the Core Audio host clock, not an estimate of when it was heard.
        case signal(levelDBFS: Float, beatTimeNs: UInt64?)
        /// Capture ended for a reason a fresh start usually fixes, like a new audio output.
        case interrupted(String)
        /// `needsAccess`: allowing system audio recording would likely fix it.
        case failed(String, needsAccess: Bool)
        /// Audio has arrived for a while, but every sample was exactly zero, as when macOS withholds
        /// system audio. Also true of an app that keeps its output open while paused, so it's a hint, not
        /// a failure; false once real sound arrives.
        case onlySilence(Bool)
    }

    public typealias Report = @Sendable (Event) -> Void
    /// Optional system-capture sink called on the capture worker. Keep it bounded and never block on output I/O.
    /// An in-flight callback may finish after Stop; use `shutdown(then:)` to wait for teardown.
    public typealias ConsumePCM = @Sendable (CapturePCM) -> Void

    /// The tap only delivers audio while the output is playing, so a quiet stream is only a problem
    /// when the output is playing. These limits count from when that was first seen.
    struct Timeouts {
        var firstBufferNs: UInt64 = 12_000_000_000
        var stalledStreamNs: UInt64 = 5_000_000_000
        /// Each check reads every audio process, so not too often; the limits above are seconds long.
        var outputCheckNs: UInt64 = 1_000_000_000
        /// Buffers arrive every ~10 ms while audio flows; a longer gap means none is arriving.
        var receivingNs: UInt64 = 100_000_000
    }

    /// How often to drain the mailbox: briskly while audio arrives, gently while none does. The slots
    /// hold at least 80 ms even with small buffers at 192 kHz, so the slow pace can't overflow them.
    private static let fastPace = DispatchTimeInterval.milliseconds(8)
    private static let restingPace = DispatchTimeInterval.milliseconds(20)

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

    /// `ignoring`: bundle IDs of apps whose audio Taptone leaves out.
    public func start(id: UUID, source: Source, sensitivity: BeatDetector.Sensitivity, ignoring apps: Set<String> = [],
                      consumePCM: ConsumePCM? = nil, report: @escaping Report) {
        enqueue(updating: { $0 = id }) { [self] in
            guard isRequested(id) else { return }
            end()
            guard isRequested(id) else { return }
            let next = Session(id: id, sensitivity: sensitivity, consumePCM: consumePCM, report: report)
            session = next
            do {
                if source == .system {
                    guard cleanupIssues.isEmpty else {
                        throw CaptureFailure("The previous audio session didn’t close cleanly. Quit and reopen Taptone before listening again.")
                    }
                    let tap = try makeTap()
                    next.tap = tap
                    guard isRequested(id) else { end(); return }
                    try tap.prepare(queue: queue, ignoring: apps) { [weak self] in
                        self?.fail(id, "Audio output changed.", interrupted: true)
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
                timer.schedule(deadline: .now(), repeating: Self.fastPace, leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.tick(id) }
                next.timer = timer
                timer.resume()
            } catch {
                fail(id, error.localizedDescription, needsAccess: (error as? CaptureFailure)?.needsAccess ?? false)
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

    public func ignore(_ apps: Set<String>, id: UUID) {
        queue.async { [self] in
            guard let session, session.id == id else { return }
            session.tap?.ignore(apps)
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
            session.drain(tap.mailbox, now: now, isCurrent: { isRequested(id) })
            if diagnostics, awaitingFirst, session.lastBufferAt != nil {
                let startupMs = Double(now - session.startedAt) / 1_000_000
                log.info("First PCM buffer arrived \(startupMs, format: .fixed(precision: 1), privacy: .public) ms after tap startup")
            }
            let receiving = session.lastBufferAt.map { now - $0 < timeouts.receivingNs } ?? false
            if receiving { session.noteSilence(now: now, after: timeouts.firstBufferNs) }
            if receiving != session.pacedFast {
                session.pacedFast = receiving
                session.timer?.schedule(deadline: .now(), repeating: receiving ? Self.fastPace : Self.restingPace,
                                        leeway: .milliseconds(receiving ? 1 : 5))
            }
            if receiving {
                session.playingSince = nil
            } else if now >= session.nextOutputCheck {
                session.nextOutputCheck = now + timeouts.outputCheckNs
                if tap.isOutputPlaying {
                    let since = session.playingSince ?? now
                    session.playingSince = since
                    let first = session.lastBufferAt == nil
                    if now - since >= (first ? timeouts.firstBufferNs : timeouts.stalledStreamNs) {
                        if first {
                            fail(id, "Taptone can’t hear system audio. Allow it in Privacy & Security, then try again.",
                                 needsAccess: true)
                        } else {
                            fail(id, "The audio stream stopped.", interrupted: true)
                        }
                        return
                    }
                } else {
                    session.playingSince = nil // Nothing is playing, so no audio is expected.
                }
            }
        } else {
            session.generateDemo(now: now)
        }
        if isRequested(id) { session.sendUpdate(now: now) }
    }

    private func fail(_ id: UUID, _ message: String, interrupted: Bool = false, needsAccess: Bool = false) {
        guard let session, session.id == id else { return }
        // Invalidate consumers' pending cues before HAL teardown, which can block.
        defer { end() }
        let shouldReport = requested.withLock { requested in
            guard requested == id else { return false }
            requested = nil
            return true
        }
        if diagnostics { log.info("Capture stopped: \(message, privacy: .public)") }
        if shouldReport { session.report(interrupted ? .interrupted(message) : .failed(message, needsAccess: needsAccess)) }
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
    /// Whether another app is playing audio right now, on any device.
    var isOutputPlaying: Bool { get }
    func prepare(queue: DispatchQueue, ignoring apps: Set<String>, onRouteChange: @escaping @Sendable () -> Void) throws
    /// Changes the apps left out while capturing. Called on the capture queue.
    func ignore(_ apps: Set<String>)
    func start() throws
    func stop() -> [CaptureCleanupIssue]
}

extension SystemAudioTap: CaptureTap {}

private final class Session {
    let id: UUID
    let report: CaptureEngine.Report
    private let consumePCM: CaptureEngine.ConsumePCM?
    private var missingPCM = false
    private var firstBufferAt: UInt64?
    /// Any sample that wasn't exactly zero, this session.
    private var heardSound = false
    private var reportedSilence = false
    var sensitivity: BeatDetector.Sensitivity
    var tap: (any CaptureTap)?
    var demo: DemoBeat?
    var detector: BeatDetector?
    var timer: DispatchSourceTimer?
    var startedAt: UInt64 = 0
    var lastBufferAt: UInt64?
    /// When the output was first seen playing while no audio arrived.
    var playingSince: UInt64?
    var nextOutputCheck: UInt64 = 0
    var pacedFast = true

    private var sampleRate = 0.0
    private var nsPerFrame = 0.0
    private var level: Float = -90
    private var beat: UInt64?
    /// Frames to ignore beats for after a reset: a fresh detector reads bass already playing as a hit.
    private var warmupFrames = 0
    private var lastUpdate: UInt64?
    private var generatedFrames = 0

    init(id: UUID, sensitivity: BeatDetector.Sensitivity, consumePCM: CaptureEngine.ConsumePCM?,
         report: @escaping CaptureEngine.Report) {
        self.id = id
        self.sensitivity = sensitivity
        self.consumePCM = consumePCM
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
        warmupFrames = Int(0.030 * sampleRate)
    }

    func drain(_ mailbox: TapMailbox, now: UInt64, isCurrent: () -> Bool) {
        var packet = TTAudioPacket()
        for _ in 0..<TTMailboxSlots {
            guard isCurrent(), tt_mailbox_peek(mailbox.storage, &packet) else { break }
            let owned = process(packet, now: now)
            tt_mailbox_consume(mailbox.storage)
            // Release the slot before calling downstream code; the owned buffer can outlive its slot.
            if let owned, isCurrent() { consumePCM?(owned) }
        }
    }

    private func process(_ packet: TTAudioPacket, now: UInt64) -> CapturePCM? {
        guard let stereo = packet.stereo else { return nil }
        lastBufferAt = now
        if firstBufferAt == nil { firstBufferAt = now }
        if !heardSound {
            heardSound = UnsafeBufferPointer(start: stereo, count: 2 * Int(packet.frames)).contains { $0 != 0 }
        }
        let end = packet.hostTimeNs + UInt64(Double(packet.frames) * nsPerFrame)
        guard end >= now || now - end < PulseTiming.maximumAge else {
            resetDetector()
            missingPCM = true
            return nil
        }
        if packet.discontinuity { resetDetector() }
        for frame in 0..<Int(packet.frames) {
            let warming = warmupFrames > 0
            if warming { warmupFrames -= 1 }
            guard let reading = detector?.push(left: stereo[2 * frame], right: stereo[2 * frame + 1]) else { continue }
            if warming {
                level = max(level, reading.levelDBFS)
            } else {
                record(reading, at: packet.hostTimeNs + UInt64(Double(frame) * nsPerFrame))
            }
        }
        let gap = packet.discontinuity || missingPCM
        missingPCM = false
        guard consumePCM != nil else { return nil }
        let samples = Array(UnsafeBufferPointer(start: stereo, count: 2 * Int(packet.frames)))
        return CapturePCM(stereo: samples, sampleRate: sampleRate, hostTimeNs: packet.hostTimeNs, discontinuity: gap)
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

    /// Reports a change in whether audio has been nothing but zeros for `limit` since the first buffer.
    func noteSilence(now: UInt64, after limit: UInt64) {
        guard let firstBufferAt else { return }
        let silent = !heardSound && now - firstBufferAt >= limit
        guard silent != reportedSilence else { return }
        reportedSilence = silent
        report(.onlySilence(silent))
    }

    private func record(_ reading: BeatDetector.Reading, at time: UInt64) {
        level = max(level, reading.levelDBFS)
        if reading.isBeat { beat = time }
    }

    /// Reports silence too, while waiting for audio, so the app can show that it's listening.
    func sendUpdate(now: UInt64) {
        if let beat, !PulseTiming.isFresh(beat, at: now) { self.beat = nil }
        guard beat != nil || lastUpdate.map({ now - $0 >= 150_000_000 }) ?? true else { return }
        report(.signal(levelDBFS: level, beatTimeNs: beat))
        level = -90
        beat = nil
        lastUpdate = now
    }
}
