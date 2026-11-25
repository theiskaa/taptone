import CoreAudio
import Foundation
import os
@testable import TaptoneAudio
import Testing

@Suite struct SystemAudioTapTests {
    @Test(arguments: SetupFault.allCases)
    fileprivate func rollsBackTheHALCallsThatSucceededAndCanStartAgain(fault: SetupFault) throws {
        let fake = FakeHAL(fault: fault)
        let tap = try SystemAudioTap(hal: fake.functions)
        var failure: String?
        do {
            try tap.prepare(queue: fake.queue, ignoring: [], onRouteChange: {})
            try tap.start()
        } catch {
            failure = error.localizedDescription
        }
        #expect(failure?.contains(fault.message) == true)
        #expect(tap.stop().isEmpty)
        #expect(fake.releases == fault.rollbackOrder)
        #expect(tap.stop().isEmpty)
        #expect(fake.releases == fault.rollbackOrder)
        #expect(fake.activeListeners == 0)

        fake.reset()
        try tap.prepare(queue: fake.queue, ignoring: [], onRouteChange: {})
        #expect(tap.sampleRate == 48_000)
        try tap.start()
        #expect(tap.stop().isEmpty)
        #expect(fake.releases == [.io, .processListener, .formatListener, .restartListener, .outputListener, .callback, .aggregate, .tap])
        #expect(fake.activeListeners == 0)
    }

    @Test func leavesOutItselfAlertSoundsAndIgnoredAppsWithTheirHelpers() throws {
        let own = ProcessInfo.processInfo.processIdentifier
        let fake = FakeHAL(processes: [
            10: .init(pid: own, bundleID: "com.theiskaa.taptone", playing: false),
            11: .init(pid: 501, bundleID: "systemsoundserverd", playing: true),
            12: .init(pid: 502, bundleID: "com.google.Chrome.helper", playing: true),
            13: .init(pid: 503, bundleID: "com.apple.Music", playing: false),
            14: .init(pid: 504, bundleID: "com.google.ChromeCast", playing: false),
        ])
        let tap = try SystemAudioTap(hal: fake.functions)
        try tap.prepare(queue: fake.queue, ignoring: ["com.google.Chrome"], onRouteChange: {})
        #expect(fake.tapProcesses == [10, 11, 12])
        // Only ignored apps and alert sounds are playing: nothing Taptone listens to.
        #expect(!tap.isOutputPlaying)

        tap.ignore([])
        #expect(fake.writtenProcesses == [10, 11])
        #expect(tap.isOutputPlaying)
        tap.ignore([])
        #expect(fake.writes == 1) // Unchanged, so not written again.
        #expect(tap.stop().isEmpty)
    }

    @Test func anErrorRemovingTheMatchingListenerDoesNotSkipOtherReleases() throws {
        let fake = FakeHAL(failFormatListenerRemoval: true)
        let tap = try SystemAudioTap(hal: fake.functions)
        try tap.prepare(queue: fake.queue, ignoring: [], onRouteChange: {})
        try tap.start()
        #expect(tap.stop() == [CaptureCleanupIssue(operation: "remove route listener", status: kAudioHardwareIllegalOperationError)])
        #expect(fake.releases == [.io, .processListener, .formatListener, .restartListener, .outputListener, .callback, .aggregate, .tap])
    }
}

private enum Released: Equatable, Sendable {
    case tap, aggregate, callback, outputListener, restartListener, formatListener, processListener, io
}

private enum SetupFault: CaseIterable, Sendable {
    case tap, format, unsupportedFormat, uid, aggregate, callback, missingCallback, outputListener, restartListener,
         formatListener, processListener, startIO

    var rollbackOrder: [Released] {
        switch self {
        case .tap: []
        case .format, .unsupportedFormat, .uid, .aggregate: [.tap]
        case .callback, .missingCallback: [.aggregate, .tap]
        case .outputListener: [.callback, .aggregate, .tap]
        case .restartListener: [.outputListener, .callback, .aggregate, .tap]
        case .formatListener: [.restartListener, .outputListener, .callback, .aggregate, .tap]
        case .processListener: [.formatListener, .restartListener, .outputListener, .callback, .aggregate, .tap]
        case .startIO: [.processListener, .formatListener, .restartListener, .outputListener, .callback, .aggregate, .tap]
        }
    }

    var message: String {
        switch self {
        case .tap: "Allow Taptone to record system audio"
        case .unsupportedFormat: "format Taptone doesn’t support"
        case .missingCallback: "audio callback wasn’t created"
        // Other HAL errors read the same to the user; the log says which call failed.
        case .format, .uid, .aggregate, .callback, .outputListener, .restartListener, .formatListener, .processListener, .startIO:
            "Taptone couldn’t start listening"
        }
    }
}

/// Replaces every effectful HAL call. The actual SystemAudioTap still controls acquisition and rollback.
private final class FakeHAL: Sendable {
    struct Process: Sendable {
        let pid: pid_t
        let bundleID: String
        let playing: Bool
    }

    private struct State {
        var fault: SetupFault?
        var releases: [Released] = []
        var listeners: [AudioObjectPropertySelector: ObjectIdentifier] = [:]
        var tapProcesses: [AudioObjectID]?
        var writtenProcesses: [AudioObjectID]?
        var writes = 0
    }

    let queue = DispatchQueue(label: "taptone.test.hal")
    private let tapID = AudioObjectID.max - 1
    private let aggregateID = AudioObjectID.max - 2
    private let state: OSAllocatedUnfairLock<State>
    private let failFormatListenerRemoval: Bool
    private let processes: [AudioObjectID: Process]
    private var fault: SetupFault? { state.withLock { $0.fault } }
    var releases: [Released] { state.withLock { $0.releases } }
    var activeListeners: Int { state.withLock { $0.listeners.count } }
    /// The processes the tap was created without, and the ones a later change wrote.
    var tapProcesses: [AudioObjectID]? { state.withLock { $0.tapProcesses } }
    var writtenProcesses: [AudioObjectID]? { state.withLock { $0.writtenProcesses } }
    var writes: Int { state.withLock { $0.writes } }

    init(fault: SetupFault? = nil, failFormatListenerRemoval: Bool = false, processes: [AudioObjectID: Process] = [:]) {
        state = OSAllocatedUnfairLock(initialState: State(fault: fault))
        self.failFormatListenerRemoval = failFormatListenerRemoval
        self.processes = processes
    }
    func reset() { state.withLock { $0 = State(fault: nil) } }
    private func released(_ resource: Released) { state.withLock { $0.releases.append(resource) } }

    var functions: CaptureHAL {
        var hal = CaptureHAL()
        hal.createTap = { [self] description, out in
            #expect(description?.isPrivate == true && description?.muteBehavior == .unmuted)
            let excluded = description?.processes
            state.withLock { $0.tapProcesses = excluded }
            if fault == .tap { return kAudioDevicePermissionsError }
            guard let out else { return kAudioHardwareUnspecifiedError }
            out.pointee = tapID
            return noErr
        }
        hal.propertySize = { [self] object, address, _, _, size in
            #expect(object == kAudioObjectSystemObject && address.pointee.mSelector == kAudioHardwarePropertyProcessObjectList)
            size.pointee = UInt32(processes.count * MemoryLayout<AudioObjectID>.size)
            return noErr
        }
        hal.writeProperty = { [self] object, address, _, _, _, value in
            #expect(object == tapID && address.pointee.mSelector == kAudioTapPropertyDescription)
            let processes = Unmanaged<CATapDescription>.fromOpaque(value.load(as: UnsafeRawPointer.self)).takeUnretainedValue().processes
            state.withLock {
                $0.writtenProcesses = processes
                $0.writes += 1
            }
            return noErr
        }
        hal.readProperty = { [self] object, address, _, _, _, out in
            switch address.pointee.mSelector {
            case kAudioHardwarePropertyProcessObjectList:
                for (index, id) in processes.keys.sorted().enumerated() {
                    out.assumingMemoryBound(to: AudioObjectID.self)[index] = id
                }
            case kAudioProcessPropertyPID:
                guard let process = processes[object] else { return kAudioHardwareBadObjectError }
                out.assumingMemoryBound(to: pid_t.self).pointee = process.pid
            case kAudioProcessPropertyBundleID:
                guard let process = processes[object] else { return kAudioHardwareBadObjectError }
                out.assumingMemoryBound(to: Optional<Unmanaged<CFString>>.self).pointee = .passRetained(process.bundleID as CFString)
            case kAudioProcessPropertyIsRunningOutput:
                guard let process = processes[object] else { return kAudioHardwareBadObjectError }
                out.assumingMemoryBound(to: UInt32.self).pointee = process.playing ? 1 : 0
            case kAudioTapPropertyFormat:
                #expect(object == tapID)
                if fault == .format { return kAudioHardwareUnspecifiedError }
                var format = AudioStreamBasicDescription()
                format.mSampleRate = 48_000
                format.mFormatID = kAudioFormatLinearPCM
                format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                format.mBitsPerChannel = 32
                format.mChannelsPerFrame = fault == .unsupportedFormat ? 6 : 2
                out.assumingMemoryBound(to: AudioStreamBasicDescription.self).pointee = format
            case kAudioTapPropertyUID:
                #expect(object == tapID)
                if fault == .uid { return kAudioHardwareUnspecifiedError }
                out.assumingMemoryBound(to: Optional<Unmanaged<CFString>>.self).pointee =
                    .passRetained("taptone-test-tap" as CFString)
            default:
                Issue.record("Unexpected HAL selector: \(address.pointee.mSelector)")
                return kAudioHardwareUnspecifiedError
            }
            return noErr
        }
        hal.createAggregate = { [self] configuration, out in
            #expect((configuration as NSDictionary)[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
            if fault == .aggregate { return kAudioHardwareUnspecifiedError }
            out.pointee = aggregateID
            return noErr
        }
        hal.createIO = { [self] out, device, callbackQueue, _ in
            #expect(device == aggregateID)
            #expect(callbackQueue == nil)
            if fault == .callback { return kAudioHardwareUnspecifiedError }
            if fault != .missingCallback { out.pointee = { _, _, _, _, _, _, _ in noErr } }
            return noErr
        }
        hal.addListener = { [self] object, address, listenerQueue, listener in
            #expect(listenerQueue === queue)
            let selector = address.mSelector
            if selector == kAudioHardwarePropertyDefaultOutputDevice {
                #expect(object == kAudioObjectSystemObject)
                if fault == .outputListener { return kAudioHardwareUnspecifiedError }
            } else if selector == kAudioHardwarePropertyServiceRestarted {
                #expect(object == kAudioObjectSystemObject)
                if fault == .restartListener { return kAudioHardwareUnspecifiedError }
            } else if selector == kAudioHardwarePropertyProcessObjectList {
                #expect(object == kAudioObjectSystemObject)
                if fault == .processListener { return kAudioHardwareUnspecifiedError }
            } else {
                #expect(selector == kAudioTapPropertyFormat && object == tapID)
                if fault == .formatListener { return kAudioHardwareUnspecifiedError }
            }
            let identity = ObjectIdentifier(listener)
            let replaced = state.withLock { $0.listeners.updateValue(identity, forKey: selector) }
            #expect(replaced == nil)
            return noErr
        }
        hal.startIO = { [self] object, callback in
            #expect(object == aggregateID)
            #expect(callback != nil)
            return fault == .startIO ? kAudioHardwareUnspecifiedError : noErr
        }
        hal.stopIO = { [self] object, callback in
            #expect(object == aggregateID)
            #expect(callback != nil)
            released(.io)
            return noErr
        }
        hal.removeListener = { [self] object, address, listenerQueue, listener in
            #expect(listenerQueue === queue)
            let selector = address.mSelector
            let registered = state.withLock { $0.listeners.removeValue(forKey: selector) }
            let matches = registered == ObjectIdentifier(listener)
            #expect(matches)
            guard matches else { return kAudioHardwareIllegalOperationError }
            if selector == kAudioHardwarePropertyDefaultOutputDevice {
                #expect(object == kAudioObjectSystemObject)
                released(.outputListener)
            } else if selector == kAudioHardwarePropertyServiceRestarted {
                #expect(object == kAudioObjectSystemObject)
                released(.restartListener)
            } else if selector == kAudioHardwarePropertyProcessObjectList {
                #expect(object == kAudioObjectSystemObject)
                released(.processListener)
            } else {
                #expect(selector == kAudioTapPropertyFormat && object == tapID)
                released(.formatListener)
                if failFormatListenerRemoval { return kAudioHardwareIllegalOperationError }
            }
            return noErr
        }
        hal.destroyIO = { [self] object, _ in
            #expect(object == aggregateID)
            released(.callback)
            return noErr
        }
        hal.destroyAggregate = { [self] object in
            #expect(object == aggregateID)
            released(.aggregate)
            return noErr
        }
        hal.destroyTap = { [self] object in
            #expect(object == tapID)
            released(.tap)
            return noErr
        }
        return hal
    }
}
