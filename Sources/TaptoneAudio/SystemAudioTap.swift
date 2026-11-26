import AudioListener
import CoreAudio
import Foundation
import OSLog
import TaptoneCore

private let log = Logger(category: "CoreAudio")

struct CaptureFailure: LocalizedError {
    let errorDescription: String?
    /// Allowing system audio recording in Privacy & Security would fix it.
    var needsAccess = false

    init(_ message: String, needsAccess: Bool = false) {
        errorDescription = message
        self.needsAccess = needsAccess
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status != noErr else { return }
        if status == kAudioDevicePermissionsError {
            throw Self("Allow Taptone to record system audio in Privacy & Security, then try again.", needsAccess: true)
        }
        let bytes = (0..<4).reversed().map { UInt8(truncatingIfNeeded: UInt32(bitPattern: status) >> ($0 * 8)) }
        let code = bytes.allSatisfy { (33...126).contains($0) } ? String(decoding: bytes, as: UTF8.self) : String(status)
        log.error("Couldn’t \(operation, privacy: .public): \(code, privacy: .public)")
        throw Self("Taptone couldn’t start listening. Try again, or restart your Mac if it keeps happening.")
    }
}

/// Owns a private tap and aggregate. Setup, changes, and teardown all run on the capture queue, which is
/// also where its listeners call back; that queue is what makes it safe to share.
final class SystemAudioTap: @unchecked Sendable {
    let mailbox: TapMailbox
    private let hal: CaptureHAL
    private(set) var sampleRate = 0.0
    private var prepared: (device: AudioObjectID, callback: AudioDeviceIOProcID)?
    private var tap: (id: AudioObjectID, description: CATapDescription)?
    /// Apps left out of the tap, by bundle ID; a helper such as `com.google.Chrome.helper` goes with its app.
    private var ignoredApps: Set<String> = []
    private var ignoredProcesses: [AudioObjectID] = []
    /// macOS alert sounds: they'd otherwise land as kicks.
    private static let alertSounds = "systemsoundserverd"
    private var teardown = CaptureTeardown()

    init(hal: CaptureHAL = CaptureHAL()) throws {
        guard let mailbox = TapMailbox() else { throw CaptureFailure("Couldn’t allocate the audio buffer.") }
        self.mailbox = mailbox
        self.hal = hal
    }

    func prepare(queue: DispatchQueue, ignoring apps: Set<String>,
                 onRouteChange: @escaping @Sendable () -> Void) throws {
        ignoredApps = apps
        ignoredProcesses = processesToIgnore()
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: ignoredProcesses)
        description.name = "Taptone System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        try CaptureFailure.check(hal.createTap(description, &tapID), "create the system audio tap")
        let tap = tapID
        teardown.acquired("destroy audio tap") { [release = hal.destroyTap] in release(tap) }
        self.tap = (tap, description)

        let format = try readFormat(tap)
        let floatPacked = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & floatPacked == floatPacked,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mBitsPerChannel == 32,
              (1...2).contains(format.mChannelsPerFrame),
              (8_000...384_000).contains(format.mSampleRate) else {
            throw CaptureFailure("This audio output uses a format Taptone doesn’t support yet.")
        }
        sampleRate = format.mSampleRate

        let uid = try tapUID(tap)
        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Taptone Capture",
            kAudioAggregateDeviceUIDKey: "com.theiskaa.taptone.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uid, kAudioSubTapDriftCompensationKey: true]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        try CaptureFailure.check(hal.createAggregate(configuration as CFDictionary, &aggregateID), "create the capture device")
        let aggregate = aggregateID
        teardown.acquired("destroy aggregate device") { [release = hal.destroyAggregate] in release(aggregate) }

        var io: AudioDeviceIOProcID?
        _ = HostClock.nowNs() // Warm up the clock conversion before using it in the callback.
        try CaptureFailure.check(hal.createIO(&io, aggregate, nil) { [mailbox] now, input, inputTime, _, _ in
            let stamp = inputTime.pointee
            let host = stamp.mFlags.contains(.hostTimeValid) && stamp.mHostTime != 0 ? stamp.mHostTime : now.pointee.mHostTime
            mailbox.write(input, hostTimeNs: host == 0 ? HostClock.nowNs() : AudioConvertHostTimeToNanos(host))
        }, "attach the audio callback")

        guard let io else { throw CaptureFailure("The audio callback wasn’t created.") }
        teardown.acquired("remove audio callback") { [release = hal.destroyIO] in release(aggregate, io) }

        try listen(AudioProperty.system, kAudioHardwarePropertyDefaultOutputDevice, queue: queue, callback: onRouteChange)
        // coreaudiod restarted: the tap and capture device are gone, so start over at once.
        try listen(AudioProperty.system, kAudioHardwarePropertyServiceRestarted, queue: queue, callback: onRouteChange)
        // Changing the ignored apps also notifies the format; only a real change means a new output.
        try listen(tap, kAudioTapPropertyFormat, queue: queue) { [weak self] in
            guard let self, let current = try? self.readFormat(tap),
                  current.mSampleRate != format.mSampleRate || current.mChannelsPerFrame != format.mChannelsPerFrame else { return }
            onRouteChange()
        }
        // An ignored app that starts playing later has no audio process yet, so add it when it appears.
        try listen(AudioProperty.system, kAudioHardwarePropertyProcessObjectList, queue: queue) { [weak self] in
            self?.applyIgnored()
        }
        prepared = (aggregate, io)
    }

    /// Changes the apps left out, without restarting. Call on the capture queue.
    func ignore(_ apps: Set<String>) {
        ignoredApps = apps
        applyIgnored()
    }

    private func applyIgnored() {
        let processes = processesToIgnore()
        guard processes != ignoredProcesses, let tap else { return }
        tap.description.processes = processes
        // The property holds a reference to the description object.
        var description = Unmanaged.passUnretained(tap.description).toOpaque()
        var address = AudioProperty.address(kAudioTapPropertyDescription)
        let status = withExtendedLifetime(tap.description) {
            hal.writeProperty(tap.id, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: description)), &description)
        }
        // Remember only what took, so the next change tries again.
        if status == noErr { ignoredProcesses = processes } else { log.error("Couldn’t update the ignored apps: \(status)") }
    }

    /// Taptone itself, alert sounds, and the ignored apps' audio processes.
    private func processesToIgnore() -> [AudioObjectID] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return processes().filter { process in
            if pid(of: process) == ownPID { return true }
            guard let bundleID = bundleID(of: process) else { return false }
            return bundleID == Self.alertSounds
                || ignoredApps.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
        }.sorted()
    }

    func start() throws {
        guard let (device, callback) = prepared else { throw CaptureFailure("The audio callback wasn’t created.") }
        try CaptureFailure.check(hal.startIO(device, callback), "start listening to system audio")
        teardown.acquired("stop audio") { [release = hal.stopIO] in release(device, callback) }
    }

    /// Whether an app Taptone listens to is playing audio right now. Per-process, so an app using only
    /// a headset's microphone doesn't count, and neither do Taptone, alert sounds, or ignored apps.
    var isOutputPlaying: Bool {
        let ignored = Set(ignoredProcesses)
        return processes().contains { process in
            !ignored.contains(process) && read(process, kAudioProcessPropertyIsRunningOutput, as: UInt32.self).map { $0 != 0 } == true
                && pid(of: process) != ProcessInfo.processInfo.processIdentifier
        }
    }

    func stop() -> [CaptureCleanupIssue] {
        prepared = nil
        tap = nil
        sampleRate = 0
        let issues = teardown.run()
        for issue in issues {
            log.error("Couldn’t \(issue.operation, privacy: .public): \(issue.status)")
        }
        return issues
    }

    private func readFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        var address = AudioProperty.address(kAudioTapPropertyFormat)
        try CaptureFailure.check(hal.readProperty(tap, &address, 0, nil, &size, &format), "read the tap format")
        return format
    }

    private func tapUID(_ tap: AudioObjectID) throws -> String {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: uid))
        var address = AudioProperty.address(kAudioTapPropertyUID)
        try CaptureFailure.check(hal.readProperty(tap, &address, 0, nil, &size, &uid), "read the tap identifier")
        guard let uid else { throw CaptureFailure("The system audio tap returned no identifier.") }
        return uid.takeRetainedValue() as String
    }

    private func processes() -> [AudioObjectID] {
        var size: UInt32 = 0
        var address = AudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        guard hal.propertySize(AudioProperty.system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard hal.readProperty(AudioProperty.system, &address, 0, nil, &size, &processes) == noErr else { return [] }
        return Array(processes.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func pid(of process: AudioObjectID) -> pid_t? {
        read(process, kAudioProcessPropertyPID, as: pid_t.self)
    }

    private func bundleID(of process: AudioObjectID) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        var address = AudioProperty.address(kAudioProcessPropertyBundleID)
        guard hal.readProperty(process, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        let id = value.takeRetainedValue() as String
        return id.isEmpty ? nil : id
    }

    private func read<Value>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as _: Value.Type) -> Value? {
        var address = AudioProperty.address(selector)
        var size = UInt32(MemoryLayout<Value>.size)
        let value = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<Value>.size, alignment: MemoryLayout<Value>.alignment)
        defer { value.deallocate() }
        guard hal.readProperty(object, &address, 0, nil, &size, value) == noErr,
              size == UInt32(MemoryLayout<Value>.size) else { return nil }
        return value.load(as: Value.self)
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        queue: DispatchQueue, callback: @escaping @Sendable () -> Void) throws {
        let address = AudioProperty.address(selector)
        let listener = TTAudioListener(handler: callback)
        try CaptureFailure.check(hal.addListener(object, address, queue, listener), "watch for audio output changes")
        teardown.acquired("remove route listener") { [release = hal.removeListener] in
            release(object, address, queue, listener)
        }
    }
}
