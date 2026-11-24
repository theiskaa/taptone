import CoreAudio

/// The default output device: what it's called, how it's connected, and how long after a tap timestamp
/// its audio is heard. Latency is the device's own report (Bluetooth reports far more than speakers);
/// it can be wrong, which is why the app offers a small sync adjustment.
public struct OutputDevice: Sendable {
    public enum Connection: Sendable {
        case builtIn, bluetooth, usb, airPlay, display, other

        public var title: String {
            switch self {
            case .builtIn: "Built-in"
            case .bluetooth: "Bluetooth"
            case .usb: "USB"
            case .airPlay: "AirPlay"
            case .display: "Display"
            case .other: "External"
            }
        }
    }

    public static let maximumLatencyNs: UInt64 = 500_000_000

    public let name: String
    public let connection: Connection
    public let latencyNs: UInt64

    public static func current() -> OutputDevice? {
        guard let device = read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                                scope: kAudioObjectPropertyScopeGlobal, as: AudioObjectID.self),
              device != kAudioObjectUnknown,
              let rate = read(device, kAudioDevicePropertyNominalSampleRate, as: Float64.self),
              rate.isFinite, rate > 0 else { return nil }
        let frames = [kAudioDevicePropertyLatency, kAudioDevicePropertySafetyOffset]
            .map { Double(read(device, $0, as: UInt32.self) ?? 0) }
            .reduce(0, +) + Double(firstStreamLatency(device) ?? 0)
        let name = read(device, kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal,
                        as: Unmanaged<CFString>?.self)??.takeRetainedValue() as String?
        return OutputDevice(name: name ?? "Unknown output",
                            connection: connection(read(device, kAudioDevicePropertyTransportType,
                                                        scope: kAudioObjectPropertyScopeGlobal, as: UInt32.self)),
                            latencyNs: min(maximumLatencyNs, UInt64(frames / rate * 1_000_000_000)))
    }

    private static func connection(_ transport: UInt32?) -> Connection {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
        case kAudioDeviceTransportTypeUSB: .usb
        case kAudioDeviceTransportTypeAirPlay: .airPlay
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: .display
        default: .other
        }
    }

    private static func firstStreamLatency(_ device: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioObjectID>.size) else { return nil }
        var streams = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr,
              let stream = streams.first(where: { $0 != kAudioObjectUnknown }) else { return nil }
        return read(stream, kAudioStreamPropertyLatency, scope: kAudioObjectPropertyScopeGlobal, as: UInt32.self)
    }

    private static func read<Value>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput,
                                    as _: Value.Type) -> Value? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Value>.size)
        let value = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<Value>.size, alignment: MemoryLayout<Value>.alignment)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr,
              size == UInt32(MemoryLayout<Value>.size) else { return nil }
        return value.load(as: Value.self)
    }
}
