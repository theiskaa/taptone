import AppKit

@main
@MainActor
struct TaptoneApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = MenuBarController()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
