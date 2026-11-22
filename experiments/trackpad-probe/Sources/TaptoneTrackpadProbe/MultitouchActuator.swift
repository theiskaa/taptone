import CoreFoundation
import Darwin
import Foundation

/// Private ABI, intentionally confined to this executable. The main app never links this target.
final class MultitouchActuator {
    private typealias DeviceList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool
    private typealias ReadID = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>) -> Int32
    private typealias MakeActuator = @convention(c) (UInt64) -> Unmanaged<CFTypeRef>?
    private typealias ActuatorOperation = @convention(c) (CFTypeRef) -> Int32
    private typealias MakePulse = @convention(c) (CFDictionary, Int32) -> UnsafeMutableRawPointer?
    private typealias RequestPulse = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32, Float, Float) -> Int32

    private let library: UnsafeMutableRawPointer
    private let deviceList: DeviceList
    private let isBuiltIn: IsBuiltIn
    private let readID: ReadID
    private let makeActuator: MakeActuator
    private let openActuator: ActuatorOperation
    private let closeActuator: ActuatorOperation
    private let makePulse: MakePulse
    private let requestPulse: RequestPulse

    init() throws {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw ProbeError(message: "MultitouchSupport could not be loaded on this Mac.")
        }
        func load<Fn>(_ name: String) throws -> Fn {
            guard let symbol = dlsym(handle, name) else {
                throw ProbeError(message: "MultitouchSupport does not provide \(name) on this macOS version.")
            }
            return unsafeBitCast(symbol, to: Fn.self)
        }
        do {
            deviceList = try load("MTDeviceCreateList")
            isBuiltIn = try load("MTDeviceIsBuiltIn")
            readID = try load("MTDeviceGetDeviceID")
            makeActuator = try load("MTActuatorCreateFromDeviceID")
            openActuator = try load("MTActuatorOpen")
            closeActuator = try load("MTActuatorClose")
            makePulse = try load("MTActuationCreateFromDictionary")
            requestPulse = try load("MTActuationActuate")
            library = handle
        } catch {
            dlclose(handle)
            throw error
        }
    }

    deinit { dlclose(library) }

    typealias Request = (ProbeSequence.Strength, () -> Bool) throws -> Bool

    /// The request function is scoped to a single successful open of a built-in actuator.
    func withBuiltInActuator(check: @escaping () throws -> Void, beforeClose: () -> Void = {},
                             run: (Request) throws -> Void) throws {
        try check()
        guard let list = deviceList()?.takeRetainedValue() else {
            throw ProbeError(message: "MultitouchSupport did not return a device list.")
        }
        var devices: [UnsafeMutableRawPointer] = []
        for index in 0..<CFArrayGetCount(list) {
            try check()
            if let raw = CFArrayGetValueAtIndex(list, index) {
                devices.append(UnsafeMutableRawPointer(mutating: raw))
            }
        }
        try withExtendedLifetime(list) {
            try ProbeResources.withBuiltIn(devices: devices, isBuiltIn: { isBuiltIn($0) }, open: { device in
                var id: UInt64 = 0
                guard readID(device, &id) == 0, let actuator = makeActuator(id)?.takeRetainedValue() else { return nil }
                try check()
                return openActuator(actuator) == 0 ? actuator : nil
            }, close: {
                beforeClose()
                return closeActuator($0)
            }, check: check) { (actuator: CFTypeRef) in
                try run { strength, permit in
                    try play(strength, on: actuator, check: check, permit: permit)
                }
            }
        }
    }

    private func play(_ strength: ProbeSequence.Strength, on actuator: CFTypeRef,
                      check: () throws -> Void, permit: () -> Bool) throws -> Bool {
        let duration = Double(ProbeSequence.durationMs)
        let base: [String: Any] = ["Type": "Gaussian", "Amplitude": 0.0, "DurationMS": duration]
        let tone: [String: Any] = ["Type": "Sine", "Amplitude": 1.0, "DurationMS": duration,
                                   "DelayMS": 0.0, "FrequencykHz": ProbeSequence.frequencyHz / 1_000]
        let description: [String: Any] = ["BaseWaveform": base, "Tones": [tone]]
        let target = Unmanaged.passUnretained(actuator).toOpaque()
        return try ProbeResources.submit(make: { () throws -> UnsafeMutableRawPointer in
            guard let pulse = makePulse(description as CFDictionary, 0) else {
                throw ProbeError(message: "The driver did not accept the fixed pulse waveform.")
            }
            return pulse
        }, release: { Unmanaged<AnyObject>.fromOpaque($0).release() }, check: check) { pulse in
            guard permit() else { return false }
            let status = requestPulse(pulse, target, 0, strength.level, 0)
            guard status == 0 else {
                throw ProbeError(message: "The driver returned \(status) for the pulse request. No more pulses will be requested.")
            }
            return true
        }
    }
}
