import AudioListener
import CoreAudio

/// Direct Core Audio entry points. Instance-local overrides let tests fail setup calls without using a device.
struct CaptureHAL {
    var createTap = AudioHardwareCreateProcessTap
    var destroyTap = AudioHardwareDestroyProcessTap
    var readProperty = AudioObjectGetPropertyData
    var propertySize = AudioObjectGetPropertyDataSize
    var createAggregate = AudioHardwareCreateAggregateDevice
    var destroyAggregate = AudioHardwareDestroyAggregateDevice
    var createIO = AudioDeviceCreateIOProcIDWithBlock
    var destroyIO = AudioDeviceDestroyIOProcID
    typealias ChangeListener = (AudioObjectID, AudioObjectPropertyAddress, DispatchQueue, TTAudioListener) -> OSStatus
    var addListener: ChangeListener = { $3.add(forObject: $0, address: $1, queue: $2) }
    var removeListener: ChangeListener = { $3.remove(forObject: $0, address: $1, queue: $2) }
    var startIO = AudioDeviceStart
    var stopIO = AudioDeviceStop
}
