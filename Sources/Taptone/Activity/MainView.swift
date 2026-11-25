import AppKit
import SwiftUI
import TaptoneCore

/// The main window: what the trackpad is doing now, then the settings, grouped like System Settings.
struct MainView: View {
    struct Actions {
        let toggleHaptics: () -> Void
        let openPrivacySettings: () -> Void
        let explainAudioAccess: () -> Void
        let toggleKickTest: () -> Void
        let openTrackpadSettings: () -> Void
        let checkForUpdates: () -> Void
    }

    let activity: ActivityModel
    @Bindable var settings: Settings
    let actions: Actions
    @State private var opensAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                LiveCard(activity: activity, actions: actions)
                    .listRowInsets(EdgeInsets())
            }
            Section("Haptics") {
                Picker("Intensity", selection: $settings.intensity) {
                    ForEach(HapticIntensity.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!activity.usesMotor)
                Picker("Kicks", selection: $settings.sensitivity) {
                    ForEach(BeatDetector.Sensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle(isOn: $settings.followsVolume) {
                    Text("Follow volume")
                    Text("Haptics get weaker as you turn the sound down. Off, they keep the same strength at any volume. Muting always stops them.")
                }
                .disabled(!activity.usesMotor)
                KickTestView(activity: activity, toggle: actions.toggleKickTest,
                             openTrackpadSettings: actions.openTrackpadSettings)
            }
            Section("Listening") {
                Toggle(isOn: $settings.pausesDuringCalls) {
                    Text("Pause during calls")
                    Text("Haptics pause while an app uses the microphone, so voices don’t buzz the trackpad.")
                }
                IgnoredAppsView(apps: $settings.ignoredApps)
            }
            Section("Timing") {
                LabeledContent("Output") {
                    Text(activity.device.map { "\($0.name), \($0.connection.title)" } ?? "None")
                }
                LabeledContent {
                    Stepper(value: $settings.syncOffsetMs, in: Settings.syncOffsetRangeMs, step: Settings.syncOffsetStepMs) {
                        Text(delay).monospacedDigit()
                    }
                } label: {
                    Text("Haptic delay")
                    Text(delayNote)
                }
                .disabled(!activity.usesMotor)
            }
            Section {
                Toggle("Open at login", isOn: $opensAtLogin)
                    .onChange(of: opensAtLogin) { _, wanted in
                        // Also skips the write-back below, which would otherwise undo a pending approval.
                        guard wanted != LoginItem.isEnabled else { return }
                        if LoginItem.set(wanted) != wanted { opensAtLogin = !wanted }
                    }
                Toggle(isOn: $settings.pauseShortcut) {
                    Text("Pause shortcut")
                    if activity.shortcutTaken {
                        Text("Another app already uses \(HotKey.title), so it can’t pause Taptone.")
                            .foregroundStyle(.orange)
                    } else {
                        Text("\(HotKey.title) pauses or resumes Taptone from any app.")
                    }
                }
                Toggle(isOn: $settings.checksForUpdates) {
                    Text("Check for updates")
                    Text("Once a day, Taptone asks GitHub for its latest version.")
                }
                LabeledContent("Version \(UpdateChecker.currentVersion)") {
                    if let update = activity.availableUpdate {
                        Button("Get \(update.version)…", action: actions.checkForUpdates)
                    } else {
                        Button("Check Now", action: actions.checkForUpdates)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .tint(Brand.tint)
        .frame(width: 480, height: 760)
        .onAppear { opensAtLogin = LoginItem.isEnabled }
    }

    private var delay: String {
        let reported = activity.device.map { Int($0.latencyNs / 1_000_000) } ?? 0
        return "\(max(0, reported + settings.syncOffsetMs)) ms"
    }

    private var delayNote: String {
        let offset = settings.syncOffsetMs
        var note = switch offset {
        case 0: "Matches the output’s reported latency, so you feel it as you hear it."
        case 1...: "\(offset) ms later than the output reports."
        default: "\(-offset) ms earlier than the output reports."
        }
        if activity.device?.connection == .airPlay { note += " AirPlay delay varies, so adjust it until kicks line up." }
        return note
    }
}

/// Apps whose audio Taptone leaves out, such as a call or a game.
private struct IgnoredAppsView: View {
    @Binding var apps: [String]

    var body: some View {
        LabeledContent {
            Button("Add App…", action: add)
        } label: {
            Text("Ignored apps")
            Text("Their sound never reaches the trackpad. Safari and other WebKit browsers can’t be told apart, so they can’t be ignored.")
        }
        ForEach(apps, id: \.self) { id in
            HStack(spacing: 8) {
                Image(nsImage: Self.icon(id)).resizable().frame(width: 20, height: 20)
                Text(Self.name(id))
                Spacer()
                Button {
                    apps.removeAll { $0 == id }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop ignoring \(Self.name(id))")
            }
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "Ignore"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, !apps.contains(id) else { continue }
            apps.append(id)
        }
    }

    private static func url(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    private static func name(_ id: String) -> String {
        url(id).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
    }

    private static func icon(_ id: String) -> NSImage {
        url(id).map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(named: NSImage.applicationIconName)!
    }
}
