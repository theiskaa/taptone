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
    private typealias Listener = (object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)
    /// The default output's volume and mute; replaced when the output changes.
    private var outputListeners: [Listener] = []
    /// Each app's microphone use, by audio process. Kept across process list changes, so only apps
    /// that come or go are touched.
    private var processListeners: [AudioObjectID: Listener] = [:]
    /// System services that listen on their own, such as Siri and Sound Recognition: never a call.
    private static let backgroundListeners = ["com.apple.CoreSpeech", "com.apple.corespeechd", "com.apple.assistantd",
                                              "com.apple.accessibility.heard", "com.apple.SiriSetup"]

    /// `onChange` runs on the main actor whenever the state changes. Keep one for the app’s lifetime.
    public init(onChange: @escaping (State) -> Void) {
        self.onChange = onChange
        _ = listen(AudioProperty.system, kAudioHardwarePropertyDefaultOutputDevice) { $0.watchOutput() }
        _ = listen(AudioProperty.system, kAudioHardwarePropertyProcessObjectList) { $0.watchProcesses() }
        watchOutput()
        watchProcesses()
    }

    private func watchOutput() {
        for var listener in outputListeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, .main, listener.block)
        }
        outputListeners = []
        if let output = AudioProperty.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) {
            for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
                if let listener = listen(output, selector, scope: kAudioObjectPropertyScopeOutput, { $0.refresh() }) {
                    outputListeners.append(listener)
                }
            }
        }
        refresh()
    }

    private func watchProcesses() {
        let candidates = Set(Self.callerCandidates())
        // A process that's gone took its listener with it; removing that would only log an error.
        processListeners = processListeners.filter { candidates.contains($0.key) }
        for process in candidates where processListeners[process] == nil {
            processListeners[process] = listen(process, kAudioProcessPropertyIsRunningInput) { $0.refresh() }
        }
        refresh()
    }

    private func refresh() {
        let output = AudioProperty.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let scope = kAudioObjectPropertyScopeOutput
        let next = State(
            volume: output.flatMap { AudioProperty.read($0, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope, as: Float32.self) },
            isMuted: output.flatMap { AudioProperty.read($0, kAudioDevicePropertyMute, scope: scope, as: UInt32.self) }.map { $0 != 0 } ?? false,
            microphoneInUse: Self.callerCandidates().contains {
                AudioProperty.read($0, kAudioProcessPropertyIsRunningInput, as: UInt32.self).map { $0 != 0 } ?? false
            }
        )
        guard next != state else { return }
        state = next
        onChange(next)
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ action: @escaping @MainActor (AudioSurroundings) -> Void) -> Listener? {
        var address = AudioProperty.address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return nil }
        return (object, address, block)
    }

    /// Every audio process that could be on a call: not Taptone, whose own capture reads input, and
    /// not the system's background listeners.
    private static func callerCandidates() -> [AudioObjectID] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return AudioProperty.objects(AudioProperty.system, kAudioHardwarePropertyProcessObjectList).filter { process in
            guard AudioProperty.read(process, kAudioProcessPropertyPID, as: pid_t.self) != ownPID else { return false }
            guard let bundleID = AudioProperty.string(process, kAudioProcessPropertyBundleID) else { return true }
            return !backgroundListeners.contains { bundleID.hasPrefix($0) }
        }
    }
}
