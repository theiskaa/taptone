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
        guard let device = AudioProperty.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
              let rate = read(device, kAudioDevicePropertyNominalSampleRate, as: Float64.self),
              rate.isFinite, rate > 0 else { return nil }
        let frames = [kAudioDevicePropertyLatency, kAudioDevicePropertySafetyOffset]
            .map { Double(read(device, $0, as: UInt32.self) ?? 0) }
            .reduce(0, +) + Double(firstStreamLatency(device) ?? 0)
        return OutputDevice(name: AudioProperty.string(device, kAudioObjectPropertyName) ?? "Unknown output",
                            connection: connection(AudioProperty.read(device, kAudioDevicePropertyTransportType, as: UInt32.self)),
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
        guard let stream = AudioProperty.objects(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            .first(where: { $0 != kAudioObjectUnknown }) else { return nil }
        return AudioProperty.read(stream, kAudioStreamPropertyLatency, as: UInt32.self)
    }

    /// The output side of the device, where latency and sample rate are read.
    private static func read<Value>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector, as type: Value.Type) -> Value? {
        AudioProperty.read(device, selector, scope: kAudioObjectPropertyScopeOutput, as: type)
    }
}
