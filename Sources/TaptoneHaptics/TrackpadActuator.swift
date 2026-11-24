import CoreFoundation
import Darwin
import TaptoneCore

/// The Force Touch motor, driven through Apple's private MultitouchSupport framework.
/// This ABI is undocumented and may change in any macOS release; everything here fails closed.
/// Not thread-safe: use one instance from one thread at a time.
public final class TrackpadActuator: HapticOutput, @unchecked Sendable {
    /// The private symbols resolve on this macOS version. Doesn't prove a Force Touch trackpad is present.
    public static var isSupported: Bool { Symbols.shared != nil }

    private let symbols: Symbols
    private let actuator: CFTypeRef
    private let devices: CFArray
    private var isOpen = true

    /// Opens the built-in trackpad's motor, or the first external Force Touch trackpad.
    public static func open() -> TrackpadActuator? {
        guard let symbols = Symbols.shared, let list = symbols.deviceList()?.takeRetainedValue() else { return nil }
        var candidates: [(id: UInt64, builtIn: Bool)] = []
        for index in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            let device = UnsafeMutableRawPointer(mutating: raw)
            var id: UInt64 = 0
            if symbols.deviceID(device, &id) == 0 { candidates.append((id, symbols.isBuiltIn(device))) }
        }
        for candidate in candidates.sorted(by: { $0.builtIn && !$1.builtIn }) {
            guard let actuator = symbols.makeActuator(candidate.id)?.takeRetainedValue(),
                  symbols.openActuator(actuator) == 0 else { continue }
            return TrackpadActuator(symbols: symbols, actuator: actuator, devices: list)
        }
        return nil
    }

    private init(symbols: Symbols, actuator: CFTypeRef, devices: CFArray) {
        self.symbols = symbols
        self.actuator = actuator
        self.devices = devices
    }

    deinit { _ = close() }

    public func play(_ segment: HapticSegment) -> Bool {
        let milliseconds = Double(segment.durationNs) / 1_000_000
        guard isOpen, segment.frequencyHz.isFinite, (40...1_000).contains(segment.frequencyHz),
              (0.5...40).contains(milliseconds), segment.level.isFinite else { return false }
        let level = min(HapticSynth.maximumLevel, max(0, segment.level))
        let description: [String: Any] = [
            "BaseWaveform": ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": milliseconds],
            "Tones": [["Type": "Sine", "Amplitude": 1.0, "DurationMS": milliseconds,
                       "DelayMS": 0.0, "FrequencykHz": segment.frequencyHz / 1_000]],
        ]
        guard let actuation = symbols.makeActuation(description as CFDictionary, 0) else { return false }
        defer { Unmanaged<AnyObject>.fromOpaque(actuation).release() }
        let target = Unmanaged.passUnretained(actuator).toOpaque()
        return symbols.actuate(actuation, target, 0, level, 0) == 0
    }

    @discardableResult
    public func close() -> Bool {
        guard isOpen else { return true }
        isOpen = false
        return withExtendedLifetime(devices) { symbols.closeActuator(actuator) == 0 }
    }
}

private struct Symbols: @unchecked Sendable {
    typealias DeviceList = @convention(c) () -> Unmanaged<CFArray>?
    typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
    typealias DeviceID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    typealias MakeActuator = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    typealias ActuatorCall = @convention(c) (CFTypeRef) -> Int32
    typealias MakeActuation = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
    typealias Actuate = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32

    let deviceList: DeviceList
    let isBuiltIn: IsBuiltIn
    let deviceID: DeviceID
    let makeActuator: MakeActuator
    let openActuator: ActuatorCall
    let closeActuator: ActuatorCall
    let makeActuation: MakeActuation
    let actuate: Actuate

    /// Loaded once and never unloaded.
    static let shared: Symbols? = {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        func load<Fn>(_ name: String, as _: Fn.Type) -> Fn? {
            dlsym(handle, name).map { unsafeBitCast($0, to: Fn.self) }
        }
        guard let deviceList = load("MTDeviceCreateList", as: DeviceList.self),
              let isBuiltIn = load("MTDeviceIsBuiltIn", as: IsBuiltIn.self),
              let deviceID = load("MTDeviceGetDeviceID", as: DeviceID.self),
              let makeActuator = load("MTActuatorCreateFromDeviceID", as: MakeActuator.self),
              let openActuator = load("MTActuatorOpen", as: ActuatorCall.self),
              let closeActuator = load("MTActuatorClose", as: ActuatorCall.self),
              let makeActuation = load("MTActuationCreateFromDictionary", as: MakeActuation.self),
              let actuate = load("MTActuationActuate", as: Actuate.self) else { return nil }
        return Symbols(deviceList: deviceList, isBuiltIn: isBuiltIn, deviceID: deviceID, makeActuator: makeActuator,
                       openActuator: openActuator, closeActuator: closeActuator,
                       makeActuation: makeActuation, actuate: actuate)
    }()
}
