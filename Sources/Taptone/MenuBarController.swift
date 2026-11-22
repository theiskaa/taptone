import AppKit
import OSLog
import SwiftUI
import TaptoneAudio
import TaptoneCore

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private let diagnostics = CommandLine.arguments.contains("--diagnostics")
        || ProcessInfo.processInfo.environment["TAPTONE_DIAGNOSTICS"] == "1"
    private lazy var engine = CaptureEngine(diagnostics: diagnostics)
    private let log = Logger(subsystem: "com.theiskaa.taptone", category: "Pulse")
    private let activity = ActivityModel()
    private lazy var activityWindow = makeActivityWindow()
    private var sessionID: UUID?
    private var trackpadTaps: TapRateLimiter?
    private var tapTestTask: Task<Void, Never>?
    private var quitTask: Task<Void, Never>?
    private var lastAudible: UInt64?
    private var sensitivity = BeatDetector.Sensitivity(
        rawValue: UserDefaults.standard.string(forKey: "sensitivity") ?? ""
    ) ?? .normal

    private let menu = NSMenu()
    private let stateItem = NSMenuItem.sectionHeader(title: "Taptone · Off")
    private var sensitivityItems: [NSMenuItem] = []
    private var statusItem: NSStatusItem!
    private lazy var tapsItem = item("Start Taps", #selector(toggleTaps), key: "s")
    private lazy var previewItem = item("Preview Demo", #selector(togglePreview))
    private lazy var tapTestItem = item("Test Four Taps", #selector(toggleTapTest))
    private lazy var errorItem = item("Audio Access…", #selector(showAudioAccess))
    private lazy var offIcon = TouchIcon.image(listening: false)
    private lazy var activeIcon = TouchIcon.image(listening: true)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        menu.autoenablesItems = false
        menu.addItem(stateItem)
        menu.addItem(tapsItem)
        menu.addItem(item("Show Activity", #selector(showActivity), key: "a"))
        menu.addItem(errorItem)
        menu.addItem(.separator())
        let tuning = NSMenuItem(title: "Beat Sensitivity", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        choices.autoenablesItems = false
        for (index, value) in BeatDetector.Sensitivity.allCases.enumerated() {
            let choice = item(value.rawValue.capitalized, #selector(chooseSensitivity(_:)))
            choice.tag = index
            choices.addItem(choice)
            sensitivityItems.append(choice)
        }
        tuning.submenu = choices
        menu.addItem(tuning)
        let diagnosticsItem = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        let diagnosticsMenu = NSMenu()
        diagnosticsMenu.autoenablesItems = false
        diagnosticsMenu.addItem(previewItem)
        diagnosticsMenu.addItem(tapTestItem)
        diagnosticsMenu.addItem(item("Audio Access…", #selector(showAudioAccess)))
        diagnosticsItem.submenu = diagnosticsMenu
        menu.addItem(diagnosticsItem)
        menu.addItem(.separator())
        menu.addItem(item("Quit Taptone", #selector(quit), key: "q"))
        statusItem.menu = menu
        render()

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(self, selector: #selector(suspend), name: name, object: nil)
        }
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
    }

    private func finishQuit() {
        guard let quitTask else { return }
        quitTask.cancel()
        self.quitTask = nil
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    private func item(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    private func render() {
        let phase = activity.phase
        let status = "Taptone · \(tapTestTask == nil ? phase.title : "Tap Test")"
        stateItem.title = status
        statusItem.button?.toolTip = status
        statusItem.button?.setAccessibilityLabel(status)
        statusItem.button?.image = phase.isLive ? activeIcon : offIcon
        tapsItem.title = phase.tapAction
        previewItem.title = phase == .preview ? "Stop Demo" : "Preview Demo"
        previewItem.isEnabled = !phase.isLive
        tapTestItem.title = tapTestTask == nil ? "Test Four Taps" : "Cancel Tap Test"
        tapTestItem.isEnabled = sessionID == nil
        if case .failed = phase { errorItem.isHidden = false }
        else { errorItem.isHidden = true }
        for (item, value) in zip(sensitivityItems, BeatDetector.Sensitivity.allCases) {
            item.state = value == sensitivity ? .on : .off
        }
    }

    @objc private func toggleTaps() {
        if activity.phase.isLive { stop() } else { start(.system) }
    }

    @objc private func togglePreview() {
        guard !activity.phase.isLive else { return }
        if activity.phase == .preview { stop() } else { start(.demo) }
    }

    @objc private func showActivity() {
        // Let the status menu finish closing before handing focus to the window.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.activityWindow else { return }
            if window.isMiniaturized { window.deminiaturize(nil) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    private func makeActivityWindow() -> NSWindow {
        let view = ActivityView(
            activity: activity,
            toggleTaps: { [weak self] in self?.toggleTaps() },
            togglePreview: { [weak self] in self?.togglePreview() },
            showAudioAccess: { [weak self] in self?.showAudioAccess() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Taptone Activity"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = ActivityPalette.paper
        window.contentMinSize = NSSize(width: 520, height: 408)
        window.setContentSize(NSSize(width: 600, height: 418))
        window.center()
        return window
    }

    private func start(_ source: CaptureEngine.Source) {
        guard quitTask == nil else { return }
        stop(updateMenu: false)
        let id = UUID()
        sessionID = id
        activity.history = ActivityHistory()
        activity.phase = source == .system ? .starting : .preview
        trackpadTaps = source == .system ? TapRateLimiter() : nil
        render()
        engine.start(id: id, source: source, sensitivity: sensitivity) { [weak self] event in
            DispatchQueue.main.async { self?.receive(event, from: id) }
        }
    }

    private func stop(updateMenu: Bool = true) {
        if let sessionID { engine.stop(id: sessionID) }
        sessionID = nil // Invalidate already-enqueued UI and haptic events immediately.
        trackpadTaps = nil
        tapTestTask?.cancel()
        tapTestTask = nil
        lastAudible = nil
        activity.phase = .off
        if updateMenu { render() }
    }

    private func receive(_ event: CaptureEngine.Event, from id: UUID) {
        guard id == sessionID else { return }
        switch event {
        case .failed(let message):
            stop(updateMenu: false)
            activity.phase = .failed(message)
            render()
        case .signal(let level, let beat):
            let now = CaptureEngine.now()
            let freshBeat = beat.flatMap { PulseTiming.isFresh($0, at: now) ? $0 : nil }
            let requestTap = freshBeat.map { trackpadTaps?.accept(beat: $0, now: now) == true } ?? false
            if requestTap { performTap() }
            activity.history.record(at: now, levelDBFS: level, beatTimeNs: freshBeat, tapRequested: requestTap)
            updateSoundState(level: level, now: now)
            if diagnostics, let beat = freshBeat {
                let delay = (Double(now) - Double(beat)) / 1_000_000
                log.info("Detector timestamp to UI event: \(delay, format: .fixed(precision: 1), privacy: .public) ms; tap requested: \(requestTap, privacy: .public)")
            }
        }
    }

    private func updateSoundState(level: Float, now: UInt64) {
        guard activity.phase.isLive else { return }
        if level > -55 { lastAudible = now }
        let hasSound = lastAudible.map { now - $0 < 600_000_000 } ?? false
        let nextPhase = ActivityModel.Phase.listening(hasSound: hasSound)
        guard nextPhase != activity.phase else { return }
        activity.phase = nextPhase
        render()
    }

    @objc private func chooseSensitivity(_ sender: NSMenuItem) {
        sensitivity = BeatDetector.Sensitivity.allCases[sender.tag]
        UserDefaults.standard.set(sensitivity.rawValue, forKey: "sensitivity")
        if let sessionID { engine.setSensitivity(sensitivity, id: sessionID) }
        render()
    }

    @objc private func toggleTapTest() {
        guard sessionID == nil, quitTask == nil else { return }
        if let tapTestTask {
            tapTestTask.cancel()
            self.tapTestTask = nil
        } else {
            tapTestTask = Task { [weak self] in
                try? await TapTest.run { self?.performTap() }
                guard !Task.isCancelled else { return }
                self?.tapTestTask = nil
                self?.render()
            }
        }
        render()
    }

    private func performTap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
    }

    @objc private func showAudioAccess() {
        let alert = NSAlert()
        alert.messageText = "System Audio Access"
        let explanation = "Taptone analyzes audio already playing on your Mac, only while listening. Your audio keeps playing normally. No microphone or screen images are accessed, and audio is never saved or uploaded."
        if case .failed(let problem) = activity.phase {
            alert.informativeText = "\(problem)\n\n\(explanation)"
        } else {
            alert.informativeText = explanation
        }
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    @objc private func suspend() { stop() }
    @objc private func quit() { NSApp.terminate(nil) }
}
