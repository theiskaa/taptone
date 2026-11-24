import SwiftUI
import TaptoneCore

/// The main window: what the trackpad is doing now, then the settings, grouped like System Settings.
struct MainView: View {
    struct Actions {
        let toggleHaptics: () -> Void
        let openPrivacySettings: () -> Void
        let explainAudioAccess: () -> Void
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
                Picker("Kick sensitivity", selection: $settings.sensitivity) {
                    ForEach(BeatDetector.Sensitivity.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                Toggle(isOn: $settings.followsVolume) {
                    Text("Follow volume")
                    Text("Haptics get weaker as you turn the sound down. Off, they keep the same strength at any volume.")
                }
                .disabled(!activity.usesMotor)
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
            }
        }
        .formStyle(.grouped)
        .tint(Brand.tint)
        .frame(width: 480, height: 730)
        .onAppear { opensAtLogin = LoginItem.isEnabled }
    }

    private var delay: String {
        let reported = activity.device.map { Int($0.latencyNs / 1_000_000) } ?? 0
        return "\(max(0, reported + settings.syncOffsetMs)) ms"
    }

    private var delayNote: String {
        let offset = settings.syncOffsetMs
        guard offset != 0 else { return "Matches the output’s latency, so you feel it as you hear it." }
        return "\(offset > 0 ? "+" : "−")\(abs(offset)) ms from the output’s reported latency."
    }
}
