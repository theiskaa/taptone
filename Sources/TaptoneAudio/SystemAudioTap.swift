import AudioListener
import CoreAudio
import Foundation
import OSLog

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
            throw Self("Allow Taptone to record system audio in System Settings, then try again.", needsAccess: true)
        }
        let bytes = (0..<4).reversed().map { UInt8(truncatingIfNeeded: UInt32(bitPattern: status) >> ($0 * 8)) }
        let code = bytes.allSatisfy { (33...126).contains($0) } ? String(decoding: bytes, as: UTF8.self) : String(status)
        throw Self("Couldn’t \(operation) (\(code)).")
    }
}

/// Owns a private tap and aggregate. Setup and teardown both run on the capture queue.
final class SystemAudioTap {
    let mailbox: TapMailbox
    private let hal: CaptureHAL
    private(set) var sampleRate = 0.0
    private var prepared: (device: AudioObjectID, callback: AudioDeviceIOProcID)?
    private var teardown = CaptureTeardown()
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let logger = Logger(subsystem: "com.theiskaa.taptone", category: "CoreAudio")

    init(hal: CaptureHAL = CaptureHAL()) throws {
        guard let mailbox = TapMailbox() else { throw CaptureFailure("Couldn’t allocate the audio buffer.") }
        self.mailbox = mailbox
        self.hal = hal
    }

    func prepare(queue: DispatchQueue, onRouteChange: @escaping @Sendable () -> Void) throws {
        let excluded = currentProcess().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "Taptone System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        try CaptureFailure.check(hal.createTap(description, &tapID), "create the system audio tap")
        let tap = tapID
        teardown.acquired("destroy audio tap") { [release = hal.destroyTap] in release(tap) }

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout.size(ofValue: format))
        var formatAddress = Self.address(kAudioTapPropertyFormat)
        try CaptureFailure.check(hal.readProperty(tap, &formatAddress, 0, nil, &formatSize, &format), "read the tap format")
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
        _ = Self.hostTimeNs() // Warm up the clock conversion before using it in the callback.
        try CaptureFailure.check(hal.createIO(&io, aggregate, nil) { [mailbox] now, input, inputTime, _, _ in
            let stamp = inputTime.pointee
            let host = stamp.mFlags.contains(.hostTimeValid) && stamp.mHostTime != 0 ? stamp.mHostTime : now.pointee.mHostTime
            mailbox.write(input, hostTimeNs: host == 0 ? Self.hostTimeNs() : AudioConvertHostTimeToNanos(host))
        }, "attach the audio callback")

        guard let io else { throw CaptureFailure("The audio callback wasn’t created.") }
        teardown.acquired("remove audio callback") { [release = hal.destroyIO] in release(aggregate, io) }

        try listen(Self.system, kAudioHardwarePropertyDefaultOutputDevice, queue: queue, callback: onRouteChange)
        try listen(tap, kAudioTapPropertyFormat, queue: queue, callback: onRouteChange)
        prepared = (aggregate, io)
    }

    func start() throws {
        guard let (device, callback) = prepared else { throw CaptureFailure("The audio callback wasn’t created.") }
        try CaptureFailure.check(hal.startIO(device, callback), "start listening to system audio")
        teardown.acquired("stop audio") { [release = hal.stopIO] in release(device, callback) }
    }

    /// Whether another app is playing audio right now. Per-process, so an app using only a headset's
    /// microphone doesn't count, and Taptone itself never does.
    var isOutputPlaying: Bool {
        var size: UInt32 = 0
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        guard hal.propertySize(Self.system, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var processes = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard hal.readProperty(Self.system, &address, 0, nil, &size, &processes) == noErr else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return processes.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).contains { process in
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout.size(ofValue: running))
            var runningAddress = Self.address(kAudioProcessPropertyIsRunningOutput)
            guard hal.readProperty(process, &runningAddress, 0, nil, &runningSize, &running) == noErr, running != 0 else {
                return false
            }
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout.size(ofValue: pid))
            var pidAddress = Self.address(kAudioProcessPropertyPID)
            return hal.readProperty(process, &pidAddress, 0, nil, &pidSize, &pid) != noErr || pid != ownPID
        }
    }

    func stop() -> [CaptureCleanupIssue] {
        prepared = nil
        sampleRate = 0
        let issues = teardown.run()
        for issue in issues {
            Self.logger.error("Couldn’t \(issue.operation, privacy: .public): \(issue.status)")
        }
        return issues
    }

    private func tapUID(_ tap: AudioObjectID) throws -> String {
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: uid))
        var address = Self.address(kAudioTapPropertyUID)
        try CaptureFailure.check(hal.readProperty(tap, &address, 0, nil, &size, &uid), "read the tap identifier")
        guard let uid else { throw CaptureFailure("The system audio tap returned no identifier.") }
        return uid.takeRetainedValue() as String
    }

    private func currentProcess() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var object: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout.size(ofValue: object))
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let status = hal.readProperty(Self.system, &address, UInt32(MemoryLayout.size(ofValue: pid)), &pid, &size, &object)
        // A process with no audio I/O may have no HAL object yet. Taptone produces no audio.
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        queue: DispatchQueue, callback: @escaping @Sendable () -> Void) throws {
        let address = Self.address(selector)
        let listener = TTAudioListener(handler: callback)
        try CaptureFailure.check(hal.addListener(object, address, queue, listener), "watch for audio output changes")
        teardown.acquired("remove route listener") { [release = hal.removeListener] in
            release(object, address, queue, listener)
        }
    }

    static func hostTimeNs() -> UInt64 { AudioConvertHostTimeToNanos(AudioGetCurrentHostTime()) }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
