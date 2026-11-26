import AppKit
import OSLog
import TaptoneCore

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
    private static let log = Logger(category: "Updates")

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// The same command installs and updates.
    static let installCommand = "curl -fsSL https://raw.githubusercontent.com/theiskaa/taptone/main/install.sh | sh"

    static func check() async -> Outcome {
        var request = URLRequest(url: latest, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Taptone/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            guard isNewer(version, than: currentVersion), let page = URL(string: release.page) else { return .upToDate }
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

    /// Explains the update and offers the command that installs it.
    static func present(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Taptone \(release.version) is available"
        alert.informativeText = "You have \(currentVersion). To update, run this in Terminal:\n\n\(installCommand)"
        for title in ["Copy Command", "What’s New", "Later"] { alert.addButton(withTitle: title) }
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(installCommand, forType: .string)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.page)
        default:
            break
        }
    }

    static func presentUpToDate() {
        NSAlert.inform("Taptone is up to date", "You have the latest version, \(currentVersion).")
    }

    static func presentFailure() {
        NSAlert.inform("Couldn’t check for updates", "Check your internet connection and try again.")
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let page: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", page = "html_url"
        }
    }
}
