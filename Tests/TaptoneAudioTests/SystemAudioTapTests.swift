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
            try tap.prepare(queue: fake.queue, onRouteChange: {})
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
        try tap.prepare(queue: fake.queue, onRouteChange: {})
        #expect(tap.sampleRate == 48_000)
        try tap.start()
        #expect(tap.stop().isEmpty)
        #expect(fake.releases == [.io, .formatListener, .outputListener, .callback, .aggregate, .tap])
        #expect(fake.activeListeners == 0)
    }

    @Test func anErrorRemovingTheMatchingListenerDoesNotSkipOtherReleases() throws {
        let fake = FakeHAL(failFormatListenerRemoval: true)
        let tap = try SystemAudioTap(hal: fake.functions)
        try tap.prepare(queue: fake.queue, onRouteChange: {})
        try tap.start()
        #expect(tap.stop() == [CaptureCleanupIssue(operation: "remove route listener", status: kAudioHardwareIllegalOperationError)])
        #expect(fake.releases == [.io, .formatListener, .outputListener, .callback, .aggregate, .tap])
    }
}

private enum Released: Equatable, Sendable {
    case tap, aggregate, callback, outputListener, formatListener, io
}

private enum SetupFault: CaseIterable, Sendable {
    case tap, format, unsupportedFormat, uid, aggregate, callback, missingCallback, outputListener, formatListener, startIO

    var rollbackOrder: [Released] {
        switch self {
        case .tap: []
        case .format, .unsupportedFormat, .uid, .aggregate: [.tap]
        case .callback, .missingCallback: [.aggregate, .tap]
        case .outputListener: [.callback, .aggregate, .tap]
        case .formatListener: [.outputListener, .callback, .aggregate, .tap]
        case .startIO: [.formatListener, .outputListener, .callback, .aggregate, .tap]
        }
    }

    var message: String {
        switch self {
        case .tap: "Allow Taptone to record system audio"
        case .format: "read the tap format"
        case .unsupportedFormat: "format Taptone doesn’t support"
        case .uid: "read the tap identifier"
        case .aggregate: "create the capture device"
        case .callback: "attach the audio callback"
        case .missingCallback: "audio callback wasn’t created"
        case .outputListener, .formatListener: "watch for audio output changes"
        case .startIO: "start listening to system audio"
        }
    }
}

/// Replaces every effectful HAL call. The actual SystemAudioTap still controls acquisition and rollback.
private final class FakeHAL: Sendable {
    private struct State {
        var fault: SetupFault?
        var releases: [Released] = []
        var listeners: [AudioObjectPropertySelector: ObjectIdentifier] = [:]
    }

    let queue = DispatchQueue(label: "taptone.test.hal")
    private let tapID = AudioObjectID.max - 1
    private let aggregateID = AudioObjectID.max - 2
    private let state: OSAllocatedUnfairLock<State>
    private let failFormatListenerRemoval: Bool
    private var fault: SetupFault? { state.withLock { $0.fault } }
    var releases: [Released] { state.withLock { $0.releases } }
    var activeListeners: Int { state.withLock { $0.listeners.count } }

    init(fault: SetupFault? = nil, failFormatListenerRemoval: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(fault: fault))
        self.failFormatListenerRemoval = failFormatListenerRemoval
    }
    func reset() { state.withLock { $0 = State(fault: nil) } }
    private func released(_ resource: Released) { state.withLock { $0.releases.append(resource) } }

    var functions: CaptureHAL {
        var hal = CaptureHAL()
        hal.createTap = { [self] description, out in
            #expect(description?.isPrivate == true && description?.muteBehavior == .unmuted)
            if fault == .tap { return kAudioDevicePermissionsError }
            guard let out else { return kAudioHardwareUnspecifiedError }
            out.pointee = tapID
            return noErr
        }
        hal.readProperty = { [self] object, address, _, _, _, out in
            switch address.pointee.mSelector {
            case kAudioHardwarePropertyTranslatePIDToProcessObject:
                out.assumingMemoryBound(to: AudioObjectID.self).pointee = kAudioObjectUnknown
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
