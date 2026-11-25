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
    private lazy var surroundings = AudioSurroundings { [weak self] in self?.surroundingsChanged($0) }
    private lazy var hotKey = HotKey { [weak self] in self?.toggleHaptics() }

    // A live session or the kick test, never both.
    private var sessionID: UUID?
    private var output: TrackpadOutput?
    private var kickTest: Task<Void, Never>?
    private var lastAudible: UInt64?
    private var liveTimer: Timer?
    private var pauseTimer: Timer?
    private var updateTimer: Timer?
    private var quitTask: Task<Void, Never>?
    private var reconnects: [Date] = []
    // Sleep, lock, and wake. A resume waits a second, so it checks nothing has suspended since.
    private var screenLocked = false
    /// Asleep, the display off, or another user's session in front: nothing starts listening by itself.
    private var suspended = false
    private var sessionActive = true
    private var suspensions = 0
    /// Calls pause listening only as they start, so pressing play during one still works.
    private var microphoneWasInUse = false
    /// The first launch's welcome starts listening when it closes; reopening it later doesn't.
    private var welcomeStartsListening = false
    /// Listening to resume after the kick test, and the failure to show again if it doesn't.
    private var resumesAfterKickTest = false
    private var failureBeforeKickTest: ActivityModel.Phase?
    /// A Bluetooth trackpad can take a few seconds to come back after wake, so a missing one is
    /// looked for again a few times before Taptone gives up.
    private var trackpadRetries = 0
    /// The apps the running session ignores, so only a real change rewrites the tap.
    private var ignoredApps: Set<String> = []

    private var statusItem: NSStatusItem!
    private lazy var header = MenuHeaderView(settings: settings) { [weak self] in
        self?.toggleHaptics()
    }
    private lazy var updateItem = item("Update Available…", #selector(checkForUpdates))
    private lazy var accessItem = item("Allow System Audio Access…", #selector(openPrivacySettings))
    private lazy var pauseHourItem = item("Pause for 1 Hour", #selector(pauseForAnHour))
    private lazy var previewItem = item("Preview Demo", #selector(togglePreview))
    private lazy var mainWindow: NSWindow = {
        let window = window("Taptone", MainView(activity: activity, settings: settings, actions: .init(
            toggleHaptics: { [weak self] in self?.toggleHaptics() },
            openPrivacySettings: { [weak self] in self?.openPrivacySettings() },
            explainAudioAccess: { [weak self] in self?.explainAudioAccess() },
            toggleKickTest: { [weak self] in self?.toggleKickTest() },
            openTrackpadSettings: { NSWorkspace.shared.open(Self.trackpadSettings) },
            checkForUpdates: { [weak self] in self?.checkForUpdates() }
        )), showsTitle: true)
        window.delegate = self
        return window
    }()
    private var welcomeWindow: NSWindow?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let headerItem = NSMenuItem()
        headerItem.view = header
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        menu.addItem(headerItem)
        menu.addItem(updateItem)
        menu.addItem(accessItem)
        menu.addItem(.separator())
        menu.addItem(item("Open Taptone", #selector(showMainWindow), key: "o"))
        menu.addItem(pauseHourItem)
        menu.addItem(submenu("Diagnostics", [previewItem, item("Welcome…", #selector(showWelcome))]))
        menu.addItem(.separator())
        menu.addItem(item("About Taptone", #selector(showAbout)))
        menu.addItem(item("Quit Taptone", #selector(quit), key: "q"))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = menu

        settings.onChange = { [weak self] in self?.settingsChanged() }
        activity.usesMotor = TrackpadActuator.isSupported
        activity.device = OutputDevice.current()
        microphoneWasInUse = surroundings.state.microphoneInUse
        applyShortcut()
        render()

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspace.addObserver(self, selector: #selector(suspend), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(self, selector: #selector(resume), name: name, object: nil)
        }
        workspace.addObserver(self, selector: #selector(sessionDidResignActive),
                              name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionDidBecomeActive),
                              name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        let screen = DistributedNotificationCenter.default()
        screen.addObserver(self, selector: #selector(screenDidLock), name: .init("com.apple.screenIsLocked"), object: nil)
        screen.addObserver(self, selector: #selector(screenDidUnlock), name: .init("com.apple.screenIsUnlocked"), object: nil)

        // The first launch explains the audio permission before asking; closing the welcome starts listening.
        // Developer aids, each also an environment variable such as TAPTONE_DEMO=1: `--demo` plays the
        // generated demo instead of listening, `--open` shows the main window, `--welcome` the welcome,
        // and `--diagnostics` logs session details.
        let demo = Self.flag("demo")
        if !demo, AppMover.offerIfNeeded(settings) { return }
        activity.pausedUntil = settings.pausedUntil
        schedulePauseEnd()
        if demo {
            activity.pausedUntil = .distantFuture // Not saved: the next launch listens as usual.
            start(.demo)
        } else if !settings.didShowWelcome {
            showWelcome()
        } else {
            autoStart()
        }
        render()
        if Self.flag("open") { showMainWindow() }
        if Self.flag("welcome") { showWelcome() }
        scheduleUpdateCheck()
    }

    /// Opening Taptone again, from Finder or Spotlight, shows its window: the way back in when the
    /// menu bar hides its icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
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
        hotKey.unregister()
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

    /// Listening that starts by itself: at launch, after wake, after a pause or a call. It holds back
    /// while paused, locked, in a demo or kick test, or during a call.
    private func autoStart() {
        // A timer can fire late, as after sleep; a pause that has run out is over.
        if let until = activity.pausedUntil, until <= .now { endPause() }
        guard quitTask == nil, settings.didShowWelcome, !activity.isPaused, !screenLocked, !suspended, sessionActive,
              !activity.phase.isLive, activity.phase != .preview else { return }
        // The kick test has the motor; listening picks up when it ends.
        if kickTest != nil {
            resumesAfterKickTest = true
            return
        }
        if settings.pausesDuringCalls, surroundings.state.microphoneInUse {
            activity.inCall = true
            return render()
        }
        start(.system)
    }

    private func start(_ source: CaptureEngine.Source) {
        guard quitTask == nil else { return }
        stop(updateMenu: false)
        activity.inCall = false
        activity.history = ActivityHistory()
        let id = UUID()
        var consumePCM: CaptureEngine.ConsumePCM?
        // The demo is visual only: it never drives the trackpad.
        if source == .system {
            let output = makeOutput { [weak self] in self?.motorFailed(id) }
            activity.device = output.device
            if diagnostics, let device = output.device {
                log.info("Output \(device.name, privacy: .public) reports \(Double(device.latencyNs) / 1e6, format: .fixed(precision: 1), privacy: .public) ms; mode: \(String(describing: output.mode), privacy: .public)")
            }
            guard output.mode != .none else {
                self.output = nil
                activity.phase = .noTrackpad
                render()
                return retryTrackpad()
            }
            trackpadRetries = 0
            consumePCM = output.consumePCM
        }
        sessionID = id
        ignoredApps = Set(settings.ignoredApps)
        activity.phase = source == .system ? .starting : .preview
        if activity.usesMotor || source == .demo {
            let timer = Timer(timeInterval: 1 / 12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshLive() }
            }
            RunLoop.main.add(timer, forMode: .common) // Keep ticking while the menu is open.
            liveTimer = timer
        }
        render()
        engine.start(id: id, source: source, sensitivity: settings.sensitivity, ignoring: ignoredApps,
                     consumePCM: consumePCM) { [weak self] event in
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
        activity.hearsOnlySilence = false
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
        case .onlySilence(let silent):
            activity.hearsOnlySilence = silent
            render()
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

    /// Twelve times a second while listening or in the demo: the live state for the window, header, and icon.
    private func refreshLive() {
        if let reading = output?.reading() { activity.update(live: reading) }
        renderIcon()
        header.update(activity, settings: settings)
    }

    /// Starts over after the output changes or the stream drops, unless that keeps happening.
    private func reconnect(_ reason: String) {
        let now = Date.now
        reconnects = reconnects.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard reconnects.count <= 3 else {
            reconnects = []
            return fail("\(reason) Press play when your audio output is ready.")
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

    /// Looks for the trackpad again after 2, 4, and 6 seconds, then waits for play.
    private func retryTrackpad() {
        guard trackpadRetries < 3 else {
            trackpadRetries = 0
            return
        }
        trackpadRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2 * trackpadRetries)) { [weak self] in
            guard let self, self.activity.phase == .noTrackpad else { return }
            self.autoStart()
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
        let output = TrackpadOutput(settings: settings, surroundings: surroundings.state) {
            DispatchQueue.main.async { MainActor.assumeIsolated(onFailure) }
        }
        self.output = output
        activity.usesMotor = output.usesMotor
        return output
    }

    private func settingsChanged() {
        output?.apply(settings)
        if let sessionID {
            engine.setSensitivity(settings.sensitivity, id: sessionID)
            if Set(settings.ignoredApps) != ignoredApps {
                ignoredApps = Set(settings.ignoredApps)
                engine.ignore(ignoredApps, id: sessionID)
            }
        }
        if !settings.pausesDuringCalls, activity.inCall {
            activity.inCall = false
            autoStart()
        }
        applyShortcut()
        if settings.checksForUpdates != (updateTimer != nil) { scheduleUpdateCheck() }
        render()
    }

    /// Volume, mute, and calls.
    private func surroundingsChanged(_ state: AudioSurroundings.State) {
        if diagnostics {
            log.info("Volume \(state.volume ?? -1, privacy: .public), muted \(state.isMuted, privacy: .public), microphone in use \(state.microphoneInUse, privacy: .public)")
        }
        output?.follow(state)
        let callStarted = state.microphoneInUse && !microphoneWasInUse
        let callEnded = !state.microphoneInUse && microphoneWasInUse
        microphoneWasInUse = state.microphoneInUse
        if callStarted, settings.pausesDuringCalls, activity.phase.isLive {
            stop(updateMenu: false)
            activity.inCall = true
            render()
        } else if callEnded, activity.inCall {
            activity.inCall = false
            autoStart()
            render()
        }
    }

    // MARK: Pause

    @objc private func toggleHaptics() {
        if activity.phase == .preview { return stop() }
        if activity.phase.isLive {
            pause(until: .distantFuture)
        } else {
            endPause()
            start(.system)
        }
    }

    @objc private func pauseForAnHour() { pause(until: .now.addingTimeInterval(60 * 60)) }

    private func pause(until date: Date) {
        activity.pausedUntil = date
        settings.pausedUntil = date
        stop()
        schedulePauseEnd()
    }

    private func endPause() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        activity.pausedUntil = nil
        if settings.pausedUntil != nil { settings.pausedUntil = nil }
    }

    private func schedulePauseEnd() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        guard let until = activity.pausedUntil, until != .distantFuture else { return }
        let timer = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.activity.pausedUntil == until else { return }
                self.endPause()
                self.autoStart()
                self.render()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pauseTimer = timer
    }

    private func applyShortcut() {
        if settings.pauseShortcut {
            activity.shortcutTaken = !hotKey.register()
        } else {
            hotKey.unregister()
            activity.shortcutTaken = false
        }
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
        switch activity.phase {
        case .failed, .noTrackpad: failureBeforeKickTest = activity.phase
        default: failureBeforeKickTest = nil
        }
        stop()
        let output = makeOutput { [weak self] in self?.kickTestFailed() }
        guard output.mode != .none else {
            self.output = nil
            activity.kickTest = .noTrackpad
            return resumeAfterKickTest()
        }
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
            // The motor just worked, so an earlier "no trackpad" or motor failure no longer holds.
            self.failureBeforeKickTest = nil
            self.resumeAfterKickTest()
        }
    }

    private func resumeAfterKickTest() {
        defer { failureBeforeKickTest = nil }
        if resumesAfterKickTest {
            resumesAfterKickTest = false
            autoStart()
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

    // MARK: Updates

    /// Once a day, counted from the last check, so relaunching doesn't check again.
    /// After a failed check (offline, rate limited), tries again in an hour instead.
    private func scheduleUpdateCheck(retrying: Bool = false) {
        updateTimer?.invalidate()
        updateTimer = nil
        guard settings.checksForUpdates else { return }
        let due = (settings.lastUpdateCheck ?? .distantPast).addingTimeInterval(UpdateChecker.interval)
        let wait = retrying ? 60 * 60 : max(15, due.timeIntervalSinceNow)
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkQuietly() }
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    private func checkQuietly() {
        Task {
            let outcome = await UpdateChecker.check()
            if case .available(let release) = outcome {
                activity.availableUpdate = release
                render()
            }
            if case .failed = outcome { return scheduleUpdateCheck(retrying: true) }
            settings.lastUpdateCheck = .now
            scheduleUpdateCheck()
        }
    }

    @objc private func checkForUpdates() {
        if let release = activity.availableUpdate { return UpdateChecker.present(release) }
        Task {
            let outcome = await UpdateChecker.check()
            if case .failed = outcome {} else {
                settings.lastUpdateCheck = .now
                scheduleUpdateCheck()
            }
            switch outcome {
            case .available(let release):
                activity.availableUpdate = release
                render()
                UpdateChecker.present(release)
            case .upToDate: UpdateChecker.presentUpToDate()
            case .failed: UpdateChecker.presentFailure()
            }
        }
    }

    // MARK: Menu

    private func render() {
        let status = "Taptone · \(activity.summary)"
        statusItem.button?.toolTip = status
        statusItem.button?.setAccessibilityLabel(status)
        renderIcon()
        updateItem.isHidden = activity.availableUpdate == nil
        updateItem.title = activity.availableUpdate.map { "Update Available: \($0.version)…" } ?? "Update Available…"
        accessItem.isHidden = !activity.needsAudioAccess
        pauseHourItem.isHidden = !activity.phase.isLive
        previewItem.title = activity.phase == .preview ? "Stop Demo" : "Preview Demo"
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
        case .failed, .noTrackpad: .failed
        }
        let image = TouchIcon.image(state)
        if statusItem.button?.image !== image { statusItem.button?.image = image }
    }

    @objc private func togglePreview() {
        guard !activity.phase.isLive else { return }
        if activity.phase == .preview { stop() } else { start(.demo) }
    }

    @objc private func showMainWindow() { present(mainWindow) }

    @objc private func showWelcome() {
        welcomeStartsListening = !settings.didShowWelcome
        let view = WelcomeView(activity: activity, firstRun: welcomeStartsListening, actions: .init(
            toggleKickTest: { [weak self] in self?.toggleKickTest() },
            openTrackpadSettings: { NSWorkspace.shared.open(Self.trackpadSettings) },
            start: { [weak self] in self?.welcomeWindow?.close() }
        ))
        if let welcomeWindow {
            welcomeWindow.contentViewController = hosting(view)
        } else {
            let window = window("Welcome to Taptone", view, showsTitle: false)
            window.delegate = self
            welcomeWindow = window
        }
        present(welcomeWindow!)
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu bar app, without a Dock icon, once its last window closes. A minimized
        // window still counts: it's in the Dock.
        DispatchQueue.main.async { [weak self] in
            guard !NSApp.windows.contains(where: { ($0.isVisible || $0.isMiniaturized) && $0.delegate === self }) else { return }
            NSApp.setActivationPolicy(.accessory)
        }
        guard notification.object as? NSWindow === welcomeWindow else { return }
        // Seen once it's closed, so quitting during the first welcome shows it again next time.
        if !settings.didShowWelcome { settings.didShowWelcome = true }
        // The welcome's kick test ends with it; one run from the main window carries on.
        if case .running = activity.kickTest, NSApp.windows.first(where: { $0.delegate === self && $0 !== welcomeWindow })?.isVisible != true {
            stop()
            resumeAfterKickTest()
        }
        guard welcomeStartsListening else { return }
        welcomeStartsListening = false
        // A pause set while the first welcome was open still holds.
        autoStart()
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
        suspended = true
        stop()
    }

    /// After wake or unlock. Audio devices take a moment to come back, so wait a little, and don't
    /// start if the screen is still locked or something suspended Taptone again meanwhile.
    @objc private func resume() {
        let suspensionsAtWake = suspensions
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, suspensionsAtWake == self.suspensions else { return }
            self.suspended = false
            // Timers count only time awake, so one set before sleep would fire late: set them again.
            self.schedulePauseEnd()
            self.scheduleUpdateCheck()
            guard !self.welcomeStartsListening else { return }
            self.autoStart()
            self.render()
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

    /// Another user's session came to the front: their trackpad isn't Taptone's to drive.
    @objc private func sessionDidResignActive() {
        sessionActive = false
        suspend()
    }

    @objc private func sessionDidBecomeActive() {
        sessionActive = true
        resume()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Building blocks

    /// The app menu, so ⌘W, ⌘M, ⌘Q, and ⌘, work while one of Taptone's windows is in front.
    private func installMainMenu() {
        let app = NSMenu()
        app.addItem(item("About Taptone", #selector(showAbout)))
        app.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(showMainWindow), key: ","))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide Taptone", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        app.addItem(item("Quit Taptone", #selector(quit), key: "q"))
        // Cut, copy and paste in text fields, such as the Add App… panel's search.
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let main = NSMenu()
        for (title, submenu) in [("Taptone", app), ("Edit", edit), ("Window", window)] {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = submenu
            main.addItem(top)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    /// Shows a window, with a Dock icon while it's open so ⌘Tab can find it.
    private func present(_ window: NSWindow) {
        // Let the status menu finish closing before handing focus to the window.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func hosting<Content: View>(_ view: Content) -> NSHostingController<Content> {
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        return host
    }

    private func window<Content: View>(_ title: String, _ view: Content, showsTitle: Bool) -> NSWindow {
        let window = NSWindow(contentViewController: hosting(view))
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
