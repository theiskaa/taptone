import AudioToolbox
import CoreAudio
import Foundation

/// What the rest of the Mac is doing with sound: the output's volume and mute, and whether an app is
/// using a microphone, as during a call. Follows changes to the default output too.
@MainActor
public final class AudioSurroundings {
    public struct State: Equatable, Sendable {
        /// The volume slider, 0...1; nil when the output has no volume control.
        public var volume: Float?
        public var isMuted = false
        /// Some app records from a microphone: per app, not per device, because headsets and AirPods
        /// are one device for both, and playing music would otherwise look like a call.
        public var microphoneInUse = false

        /// How much the volume leaves of the signal, 0...1. The slider is perceptual, so its cube
        /// approximates amplitude: half volume is about −18 dB.
        public var outputGain: Float { isMuted ? 0 : pow(min(1, max(0, volume ?? 1)), 3) }
    }

    public private(set) var state = State()
    private let onChange: (State) -> Void
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    /// System services that listen on their own, such as Siri and Sound Recognition: never a call.
    private static let backgroundListeners = ["com.apple.CoreSpeech", "com.apple.corespeechd", "com.apple.assistantd",
                                              "com.apple.accessibility.heard", "com.apple.SiriSetup"]

    /// `onChange` runs on the main actor whenever the state changes. Keep one for the app’s lifetime.
    public init(onChange: @escaping (State) -> Void) {
        self.onChange = onChange
        watch()
    }

    private func watch() {
        unwatch()
        listen(Self.system, kAudioHardwarePropertyDefaultOutputDevice) { $0.watch() }
        // Apps come and go; watch each one's microphone use.
        listen(Self.system, kAudioHardwarePropertyProcessObjectList) { $0.watch() }
        if let output = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) {
            listen(output, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput) { $0.refresh() }
            listen(output, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput) { $0.refresh() }
        }
        for process in Self.callerCandidates() {
            listen(process, kAudioProcessPropertyIsRunningInput) { $0.refresh() }
        }
        refresh()
    }

    private func refresh() {
        let output = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let next = State(
            volume: output.flatMap { Self.read($0, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput, as: Float32.self) },
            isMuted: output.flatMap { Self.read($0, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, as: UInt32.self) }.map { $0 != 0 } ?? false,
            microphoneInUse: Self.callerCandidates().contains {
                Self.read($0, kAudioProcessPropertyIsRunningInput, as: UInt32.self).map { $0 != 0 } ?? false
            }
        )
        guard next != state else { return }
        state = next
        onChange(next)
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ action: @escaping @MainActor (AudioSurroundings) -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return }
        listeners.append((object, address, block))
    }

    private func unwatch() {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, .main, listener.block)
        }
        listeners = []
    }

    /// Every audio process that could be on a call: not Taptone, whose own capture reads input, and
    /// not the system's background listeners.
    private static func callerCandidates() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return processes.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).filter { process in
            guard read(process, kAudioProcessPropertyPID, as: pid_t.self) != ownPID else { return false }
            guard let bundleID = bundleID(of: process) else { return true }
            return !backgroundListeners.contains { bundleID.hasPrefix($0) }
        }
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        read(system, selector, as: AudioObjectID.self).flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    private static func read<Value>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                    as _: Value.Type) -> Value? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size = UInt32(MemoryLayout<Value>.size)
        let value = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<Value>.size, alignment: MemoryLayout<Value>.alignment)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr,
              size == UInt32(MemoryLayout<Value>.size) else { return nil }
        return value.load(as: Value.self)
    }
}
