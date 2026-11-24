import AppKit
import OSLog
import SwiftUI
import TaptoneAudio
import TaptoneCore
import TaptoneHaptics

/// Owns the menu, the capture session, the trackpad output, and the windows. Runs on the main actor.
@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    private static let trackpadSettings = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension")!

    private let diagnostics = flag("diagnostics")

    private static func flag(_ name: String) -> Bool {
        CommandLine.arguments.contains("--\(name)") || ProcessInfo.processInfo.environment["TAPTONE_\(name.uppercased())"] == "1"
    }
    private lazy var engine = CaptureEngine(diagnostics: diagnostics)
    private let log = Logger(subsystem: "com.theiskaa.taptone", category: "Session")
    private let settings = Settings()
    private let activity = ActivityModel()

    // A live session or the kick test, never both.
    private var sessionID: UUID?
    private var output: TrackpadOutput?
    private var kickTest: Task<Void, Never>?
    private var lastAudible: UInt64?
    private var liveTimer: Timer?
    private var quitTask: Task<Void, Never>?
    private var reconnects: [Date] = []
    // Sleep, lock, and wake. A resume waits a second, so it checks nothing has suspended since.
    private var screenLocked = false
    private var suspensions = 0
    /// The first launch's welcome starts listening when it closes; reopening it later doesn't.
    private var welcomeStartsListening = false
    /// Listening to resume after the kick test, and the failure to show again if it doesn't.
    private var resumesAfterKickTest = false
    private var failureBeforeKickTest: ActivityModel.Phase?

    private var statusItem: NSStatusItem!
    private lazy var header = MenuHeaderView(settings: settings) { [weak self] in
        self?.toggleHaptics()
    }
    private lazy var accessItem = item("Allow system audio access…", #selector(openPrivacySettings))
    private lazy var previewItem = item("Preview demo", #selector(togglePreview))
    private lazy var mainWindow = window("Taptone", MainView(activity: activity, settings: settings, actions: .init(
        toggleHaptics: { [weak self] in self?.toggleHaptics() },
        openPrivacySettings: { [weak self] in self?.openPrivacySettings() },
        explainAudioAccess: { [weak self] in self?.explainAudioAccess() }
    )), showsTitle: true)
    private lazy var welcomeWindow = window("Welcome to Taptone", WelcomeView(activity: activity, actions: .init(
        toggleKickTest: { [weak self] in self?.toggleKickTest() },
        openTrackpadSettings: { NSWorkspace.shared.open(Self.trackpadSettings) },
        start: { [weak self] in self?.closeWelcome() }
    )), showsTitle: false)

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let headerItem = NSMenuItem()
        headerItem.view = header
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(headerItem)
        menu.addItem(accessItem)
        menu.addItem(.separator())
        menu.addItem(item("Open Taptone", #selector(showMainWindow), key: "o"))
        menu.addItem(submenu("Diagnostics", [previewItem, item("Welcome…", #selector(showWelcome))]))
        menu.addItem(.separator())
        menu.addItem(item("Quit Taptone", #selector(quit), key: "q"))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = menu

        settings.onChange = { [weak self] in self?.settingsChanged() }
        activity.usesMotor = TrackpadActuator.isSupported
        activity.device = OutputDevice.current()
        render()

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(suspend), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(resume), name: name, object: nil)
        }
        let screen = DistributedNotificationCenter.default()
        screen.addObserver(self, selector: #selector(screenDidLock), name: .init("com.apple.screenIsLocked"), object: nil)
        screen.addObserver(self, selector: #selector(screenDidUnlock), name: .init("com.apple.screenIsUnlocked"), object: nil)

        // The first launch explains the audio permission before asking; closing the welcome starts listening.
        // Developer aids, each also an environment variable such as TAPTONE_DEMO=1: `--demo` plays the
        // generated demo instead of listening, `--open` shows the main window, `--welcome` the welcome,
        // and `--diagnostics` logs session details.
        if Self.flag("demo") {
            activity.isPaused = true
            start(.demo)
        } else if settings.didShowWelcome {
            start(.system)
        } else {
            showWelcome()
        }
        if Self.flag("open") { showMainWindow() }
        if Self.flag("welcome") { showWelcome() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard quitTask == nil else { return .terminateLater }
        stop(updateMenu: false)
        quitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            // HAL can wait on a system consent dialog. Don’t make Quit wait on that indefinitely.
            self?.finishQuit()
        }
        engine.shutdown { [weak self] _ in DispatchQueue.main.async { self?.finishQuit() } }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    private func finishQuit() {
        guard let quitTask else { return }
        quitTask.cancel()
        self.quitTask = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if !activity.phase.isLive { activity.device = OutputDevice.current() }
        render()
    }

    // MARK: Session

    private func start(_ source: CaptureEngine.Source) {
        guard quitTask == nil else { return }
        stop(updateMenu: false)
        let id = UUID()
        sessionID = id
        activity.history = ActivityHistory()
        activity.phase = source == .system ? .starting : .preview
        // The demo is visual only: it never drives the trackpad.
        if source == .system {
            let output = makeOutput { [weak self] in self?.motorFailed(id) }
            activity.device = output.device
            if diagnostics, let device = output.device {
                log.info("Output \(device.name, privacy: .public) reports \(Double(device.latencyNs) / 1e6, format: .fixed(precision: 1), privacy: .public) ms; motor: \(output.usesMotor, privacy: .public)")
            }
            if output.usesMotor {
                let timer = Timer(timeInterval: 1 / 12, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshLive() }
                }
                RunLoop.main.add(timer, forMode: .common) // Keep ticking while the menu is open.
                liveTimer = timer
            }
        }
        render()
        engine.start(id: id, source: source, sensitivity: settings.sensitivity,
                     consumePCM: output?.consumePCM) { [weak self] event in
            DispatchQueue.main.async { self?.receive(event, from: id) }
        }
    }

    private func stop(updateMenu: Bool = true) {
        if let sessionID { engine.stop(id: sessionID) }
        sessionID = nil // Invalidate already-enqueued UI events immediately.
        kickTest?.cancel()
        kickTest = nil
        if case .running = activity.kickTest { activity.kickTest = .idle }
        output?.stop()
        output = nil
        liveTimer?.invalidate()
        liveTimer = nil
        lastAudible = nil
        activity.update(live: nil)
        activity.phase = .off
        if updateMenu { render() }
    }

    private func receive(_ event: CaptureEngine.Event, from id: UUID) {
        guard id == sessionID else { return }
        switch event {
        case .failed(let message, let needsAccess):
            fail(message, needsAccess: needsAccess)
        case .interrupted(let reason):
            reconnect(reason)
        case .signal(let level, let beat):
            let now = CaptureEngine.now()
            let fresh = beat.flatMap { PulseTiming.isFresh($0, at: now) ? $0 : nil }
            // The demo has no output: its detected kicks go straight to the chart.
            let (kicks, motorLevel) = output?.update(beat: fresh, now: now) ?? (fresh == nil ? 0 : 1, 0)
            activity.history.record(at: now, levelDBFS: level, motorLevel: motorLevel, kicks: kicks)
            // Quiet apps still count as sound: the analyzer normalizes their level.
            if level > -70 || motorLevel > 0 { lastAudible = now }
            let phase = ActivityModel.Phase.listening(hasSound: lastAudible.map { now - $0 < 600_000_000 } ?? false)
            if activity.phase.isLive, phase != activity.phase {
                activity.phase = phase
                render()
            }
        }
    }

    /// Twelve times a second while listening: the motor's live state for the window, header, and icon.
    private func refreshLive() {
        guard let reading = output?.reading() else { return }
        activity.update(live: reading)
        renderIcon()
        header.update(activity, settings: settings)
    }

    /// Starts over after the output changes or the stream drops, unless that keeps happening.
    private func reconnect(_ reason: String) {
        let now = Date.now
        reconnects = reconnects.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard reconnects.count <= 3 else {
            reconnects = []
            return fail("\(reason) Start listening again when your audio output is ready.")
        }
        if diagnostics { log.info("Reconnecting: \(reason, privacy: .public)") }
        stop(updateMenu: false)
        activity.phase = .starting
        render()
        // Give the new output a moment to settle before tapping it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.activity.phase == .starting, self.sessionID == nil else { return }
            self.start(.system)
        }
    }

    private func motorFailed(_ id: UUID) {
        guard id == sessionID else { return }
        fail("The trackpad motor stopped responding.")
    }

    private func fail(_ message: String, needsAccess: Bool = false) {
        stop(updateMenu: false)
        activity.phase = .failed(message, needsAccess: needsAccess)
        render()
    }

    /// The trackpad output for a session or the kick test. `onFailure` runs on the main actor.
    private func makeOutput(onFailure: @escaping @MainActor () -> Void) -> TrackpadOutput {
        let output = TrackpadOutput(settings: settings) {
            DispatchQueue.main.async { MainActor.assumeIsolated(onFailure) }
        }
        self.output = output
        activity.usesMotor = output.usesMotor
        return output
    }

    private func settingsChanged() {
        output?.apply(settings)
        if let sessionID { engine.setSensitivity(settings.sensitivity, id: sessionID) }
        render()
    }

    // MARK: Kick test

    /// Pauses listening while it runs; listening picks up again afterwards.
    private func toggleKickTest() {
        guard quitTask == nil else { return }
        if case .running = activity.kickTest {
            stop()
            return resumeAfterKickTest()
        }
        resumesAfterKickTest = activity.phase.isLive
        if case .failed = activity.phase { failureBeforeKickTest = activity.phase } else { failureBeforeKickTest = nil }
        stop()
        let output = makeOutput { [weak self] in self?.kickTestFailed() }
        activity.kickTest = .running(sent: 0)
        kickTest = Task { [weak self] in
            try? await KickTest.run { number in
                output.kick()
                self?.activity.kickTest = .running(sent: number)
            }
            try? await Task.sleep(for: .milliseconds(300)) // Let the last kick ring out.
            guard !Task.isCancelled, let self else { return }
            self.stop()
            self.activity.kickTest = .finished
            self.resumeAfterKickTest()
        }
    }

    private func resumeAfterKickTest() {
        defer { failureBeforeKickTest = nil }
        if resumesAfterKickTest {
            resumesAfterKickTest = false
            start(.system)
        } else if let failure = failureBeforeKickTest {
            activity.phase = failure
            render()
        }
    }

    private func kickTestFailed() {
        guard case .running = activity.kickTest else { return }
        stop()
        activity.kickTest = .failed
        resumeAfterKickTest()
    }

    // MARK: Menu

    private func render() {
        let status = "Taptone · \(activity.summary)"
        statusItem.button?.toolTip = status
        statusItem.button?.setAccessibilityLabel(status)
        renderIcon()
        accessItem.isHidden = !activity.needsAudioAccess
        previewItem.title = activity.phase == .preview ? "Stop demo" : "Preview demo"
        previewItem.isEnabled = !activity.phase.isLive
        header.update(activity, settings: settings)
    }

    private func renderIcon() {
        let state: TouchIcon.State = switch activity.phase {
        case .off: .off
        case .starting: .connecting
        case .listening(false): .waiting
        case .listening(true) where !activity.usesMotor: .taps
        case .listening(true):
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                ? .listening(step: 1) : .listening(step: min(3, Int((activity.live?.body ?? 0) * 4)))
        case .preview: .demo
        case .failed: .failed
        }
        let image = TouchIcon.image(state)
        if statusItem.button?.image !== image { statusItem.button?.image = image }
    }

    @objc private func toggleHaptics() {
        activity.isPaused = activity.phase.isLive
        if activity.isPaused { stop() } else { start(.system) }
    }

    @objc private func togglePreview() {
        guard !activity.phase.isLive else { return }
        if activity.phase == .preview { stop() } else { start(.demo) }
    }

    @objc private func showMainWindow() { present(mainWindow) }

    @objc private func showWelcome() {
        welcomeStartsListening = !settings.didShowWelcome
        welcomeWindow.delegate = self
        present(welcomeWindow)
    }

    private func closeWelcome() { welcomeWindow.close() }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === welcomeWindow else { return }
        // Seen once it's closed, so quitting during the first welcome shows it again next time.
        if !settings.didShowWelcome { settings.didShowWelcome = true }
        if case .running = activity.kickTest {
            stop()
            resumeAfterKickTest()
        }
        guard welcomeStartsListening else { return }
        welcomeStartsListening = false
        // A pause set while the first welcome was open still holds.
        if !activity.isPaused, !activity.phase.isLive { start(.system) }
    }

    @objc private func openPrivacySettings() { NSWorkspace.shared.open(Self.privacySettings) }

    private func explainAudioAccess() {
        let alert = NSAlert()
        alert.messageText = "Why Taptone needs system audio"
        alert.informativeText = "While it’s open and not paused, Taptone listens to audio already playing on your Mac to find the bass and kicks. Your audio keeps playing normally. No microphone or screen images are used, and audio is never saved or uploaded."
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    @objc private func suspend() {
        suspensions += 1
        stop()
    }

    /// After wake or unlock. Audio devices take a moment to come back, so wait a little, and don't
    /// start if the screen is still locked or something suspended Taptone again meanwhile.
    @objc private func resume() {
        let suspensionsAtWake = suspensions
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, suspensionsAtWake == self.suspensions, !self.screenLocked, !self.activity.isPaused,
                  !self.activity.phase.isLive, self.activity.phase != .preview, !self.welcomeStartsListening else { return }
            // A kick test started meanwhile resumes listening when it ends.
            if self.kickTest != nil {
                self.resumesAfterKickTest = true
                return
            }
            self.start(.system)
        }
    }

    @objc private func screenDidLock() {
        screenLocked = true
        suspend()
    }

    @objc private func screenDidUnlock() {
        screenLocked = false
        resume()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Building blocks

    private func present(_ window: NSWindow) {
        // Let the status menu finish closing before handing focus to the window.
        DispatchQueue.main.async {
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func window<Content: View>(_ title: String, _ view: Content, showsTitle: Bool) -> NSWindow {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        if !showsTitle {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.remove(.miniaturizable)
        }
        window.center()
        return window
    }

    private func item(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let row = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        row.target = self
        return row
    }

    private func submenu(_ title: String, _ rows: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        menu.autoenablesItems = false
        rows.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }
}
