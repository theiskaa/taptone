import AppKit
import OSLog

/// Asks GitHub for the latest release. Nothing else is sent, and no cookies or caches are kept.
@MainActor
enum UpdateChecker {
    struct Release: Equatable {
        let version: String
        let page: URL
    }

    enum Outcome {
        case upToDate, available(Release), failed
    }

    static let interval: TimeInterval = 24 * 60 * 60
    private static let latest = URL(string: "https://api.github.com/repos/theiskaa/taptone/releases/latest")!
    private static let log = Logger(subsystem: "com.theiskaa.taptone", category: "Updates")

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Installed with Homebrew, so `brew upgrade` is the way to update.
    static var isHomebrewInstall: Bool {
        ["/opt/homebrew/Caskroom/taptone", "/usr/local/Caskroom/taptone"].contains {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    static func check() async -> Outcome {
        var request = URLRequest(url: latest, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Taptone/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            guard isNewer(version, than: currentVersion), let page = URL(string: release.html_url) else { return .upToDate }
            return .available(Release(version: version, page: page))
        } catch {
            log.info("Update check failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
    }

    /// Compares dotted versions number by number, so 0.10.0 is newer than 0.9.1.
    static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let (x, y) = (index < a.count ? a[index] : 0, index < b.count ? b[index] : 0)
            if x != y { return x > y }
        }
        return false
    }

    /// Explains the update and offers the way to get it.
    static func present(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Taptone \(release.version) is available"
        let homebrew = isHomebrewInstall
        if homebrew {
            alert.informativeText = "You have \(currentVersion). Update with Homebrew:\n\nbrew upgrade --cask taptone"
            alert.addButtons("Copy Command", "What’s New", "Later")
        } else {
            alert.informativeText = "You have \(currentVersion). The download page lists what’s new."
            alert.addButtons("Download", "Later")
        }
        NSApp.activate()
        switch (alert.runModal(), homebrew) {
        case (.alertFirstButtonReturn, true):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("brew upgrade --cask taptone", forType: .string)
        case (.alertFirstButtonReturn, false), (.alertSecondButtonReturn, true):
            NSWorkspace.shared.open(release.page)
        default:
            break
        }
    }

    static func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = "Taptone is up to date"
        alert.informativeText = "You have the latest version, \(currentVersion)."
        NSApp.activate()
        alert.runModal()
    }

    static func presentFailure() {
        let alert = NSAlert()
        alert.messageText = "Couldn’t check for updates"
        alert.informativeText = "Check your internet connection and try again."
        NSApp.activate()
        alert.runModal()
    }

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: String
    }
}

private extension NSAlert {
    func addButtons(_ titles: String...) { titles.forEach { addButton(withTitle: $0) } }
}
