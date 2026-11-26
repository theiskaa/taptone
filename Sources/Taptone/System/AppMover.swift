import AppKit
import OSLog
import TaptoneCore

/// Offers to move Taptone into Applications when it runs from Downloads, or from the read-only copy
/// macOS makes of an app opened straight out of a download. From there, Open at login breaks as soon
/// as the app is moved.
@MainActor
enum AppMover {
    private static let log = Logger(category: "AppMover")

    /// Returns true when Taptone is moving and about to relaunch, so launch should go no further.
    static func offerIfNeeded(_ settings: Settings) -> Bool {
        guard !settings.declinedMoveToApplications, let source = sourceNeedingMove() else { return false }
        let alert = NSAlert()
        alert.messageText = "Move Taptone to Applications?"
        alert.informativeText = "Taptone is running from \(source.deletingLastPathComponent().lastPathComponent). In Applications it stays put, and it can open at login."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            settings.declinedMoveToApplications = true
            return false
        }
        do {
            let destination = try move(source)
            guard relaunch(destination) else {
                // Moved, but this copy can't open the new one: say where it went instead of vanishing.
                NSAlert.inform("Taptone is in Applications", "Quit this copy and open Taptone from Applications.")
                return false
            }
            return true
        } catch {
            log.error("Couldn’t move to Applications: \(error.localizedDescription, privacy: .public)")
            NSAlert.inform("Couldn’t move Taptone", "Drag Taptone into Applications in Finder, then open it from there.")
            return false
        }
    }

    /// Where the app really is, when that's somewhere it shouldn't run from.
    private static func sourceNeedingMove() -> URL? {
        let running = Bundle.main.bundleURL
        if let original = originalURL(ofTranslocated: running) { return original }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.standardizedFileURL.path
        guard let downloads, running.standardizedFileURL.path.hasPrefix(downloads + "/") else { return nil }
        return running
    }

    /// Copies to /Applications, or ~/Applications when that isn't writable, and moves the original to the Trash.
    private static func move(_ source: URL) throws -> URL {
        let manager = FileManager.default
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let folder = manager.isWritableFile(atPath: system.path) ? system
            : manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        // Copy beside the destination first, so a failed copy never leaves Applications without Taptone.
        let staging = folder.appendingPathComponent(".\(source.lastPathComponent).\(UUID().uuidString)")
        try manager.copyItem(at: source, to: staging)
        // The copy came from a download; without this, macOS would translocate it again.
        removeQuarantine(staging)
        do {
            if manager.fileExists(atPath: destination.path) {
                // Replace only an older Taptone, never another app that happens to share the name.
                guard Bundle(url: destination)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try manager.trashItem(at: destination, resultingItemURL: nil)
            }
            try manager.moveItem(at: staging, to: destination)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
        try? manager.trashItem(at: source, resultingItemURL: nil)
        return destination
    }

    private static func removeQuarantine(_ url: URL) {
        let attribute = "com.apple.quarantine"
        removexattr(url.path, attribute, XATTR_NOFOLLOW)
        guard let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
        for case let item as URL in items { removexattr(item.path, attribute, XATTR_NOFOLLOW) }
    }

    /// Opens the moved copy once this one has quit. False when that can't be arranged.
    private static func relaunch(_ app: URL) -> Bool {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", app.path]
        guard (try? process.run()) != nil else { return false }
        NSApp.terminate(nil)
        return true
    }

    /// The download's real location, when macOS runs the app from a translocated copy.
    private static func originalURL(ofTranslocated url: URL) -> URL? {
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSymbol = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let originalSymbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        var translocated = false
        guard unsafeBitCast(isSymbol, to: IsTranslocated.self)(url as CFURL, &translocated, nil), translocated,
              let original = unsafeBitCast(originalSymbol, to: OriginalPath.self)(url as CFURL, nil) else { return nil }
        return original.takeRetainedValue() as URL
    }
}
