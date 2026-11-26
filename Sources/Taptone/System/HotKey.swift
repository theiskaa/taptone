import Carbon.HIToolbox

/// ⌃⌥⌘P from anywhere. Carbon's hot keys need no Accessibility permission.
@MainActor
final class HotKey {
    static let title = "⌃⌥⌘P"

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    /// Safe to call repeatedly. False when another app already owns the shortcut; then nothing is left installed.
    @discardableResult
    func register() -> Bool {
        guard handler == nil else { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &type, context, &handler)
        guard installed == noErr else {
            handler = nil
            return false
        }
        let id = EventHotKeyID(signature: OSType(0x5450_4E45), id: 1) // "TPNE"
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey | cmdKey), id,
                                             GetApplicationEventTarget(), 0, &reference)
        guard registered == noErr else {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
        reference = nil
        handler = nil
    }
}
