import AppKit
import OSLog
import ServiceManagement

/// Opening Taptone, and so listening, when you log in.
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Turns opening at login on or off. Returns whether it's on afterwards.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Logger(subsystem: "com.theiskaa.taptone", category: "LoginItem")
                .error("Couldn’t change the login item: \(error.localizedDescription, privacy: .public)")
        }
        // macOS may ask the user to allow it first, in Login Items settings.
        if enabled, SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        return isEnabled
    }
}
