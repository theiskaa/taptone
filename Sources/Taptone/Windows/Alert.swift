import AppKit

extension NSAlert {
    /// A message with an OK button, brought in front: Taptone has no window of its own to show it from.
    @MainActor
    static func inform(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate()
        alert.runModal()
    }
}
