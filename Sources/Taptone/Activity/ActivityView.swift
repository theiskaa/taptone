import SwiftUI

struct ActivityView: View {
    let activity: ActivityModel
    let toggleTaps: () -> Void
    let togglePreview: () -> Void
    let showAudioAccess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 24)
            history.padding(.bottom, 18)
            metrics.padding(.bottom, 18)
            Divider()
            controls.padding(.top, 13)
        }
        .padding(.horizontal, 26)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .frame(minWidth: 520, minHeight: 408)
        .background(Color(nsColor: ActivityPalette.paper))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Taptone")
                    .font(.system(size: 36, weight: .medium, design: .serif))
                    .tracking(-1.1)
                    .accessibilityAddTraits(.isHeader)
                Text("Feel bass accents through your trackpad.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(activity.phase.title).font(.callout.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Status: \(activity.phase.title)")
        }
    }

    private var statusColor: Color {
        switch activity.phase {
        case .listening(true): ActivityPalette.pulse
        case .failed: Color(nsColor: .systemOrange)
        default: .secondary
        }
    }

    private var history: some View {
        let frozen = !activity.phase.isLive && activity.phase != .preview && !activity.history.samples.isEmpty
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Activity").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(frozen ? "Last session" : "Last 12 seconds")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            SignalHistoryView(samples: activity.history.samples, isFrozen: frozen, emptyMessage: emptyMessage)
            HStack(spacing: 18) {
                legend("Input level") { Capsule().fill(Color.primary.opacity(0.72)).frame(width: 12, height: 1.5) }
                legend("Beat only") { Circle().strokeBorder(ActivityPalette.pulse, lineWidth: 1.3).frame(width: 7, height: 7) }
                legend("Tap requested") { RoundedRectangle(cornerRadius: 1).fill(ActivityPalette.pulse).frame(width: 7, height: 7) }
            }
        }
    }

    private var emptyMessage: String {
        switch activity.phase {
        case .off: "Start taps or preview the demo."
        case .starting: "Connecting to system audio…"
        case .listening: "Play audio to see activity."
        case .preview: "Preparing the demo…"
        case .failed(let message): message
        }
    }

    private var metrics: some View {
        let level = activity.history.samples.last.map { Int($0.levelDBFS.rounded()).formatted() } ?? "—"
        return HStack(spacing: 16) {
            metric("Input level", value: level, unit: "dBFS")
            metric("Beats detected", value: activity.history.beatCount.formatted())
            metric("Tap requests", value: activity.history.tapCount.formatted())
                .help("A request doesn’t confirm that a tap was felt.")
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            if case .failed = activity.phase {
                Button("Audio Access…", action: showAudioAccess).buttonStyle(.borderless)
            } else if !activity.phase.isLive {
                Button(activity.phase == .preview ? "Stop Demo" : "Preview Demo", action: togglePreview)
                    .buttonStyle(.borderless)
                if activity.phase == .preview {
                    Text("No audio capture or taps.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button(activity.phase.tapAction, action: toggleTaps)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(ActivityPalette.button)
        }
    }

    private func metric(_ title: String, value: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value).font(.system(size: 24, weight: .medium).monospacedDigit())
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(unit.map { "\(value) \($0)" } ?? value)
    }

    private func legend<Mark: View>(_ title: String, @ViewBuilder mark: () -> Mark) -> some View {
        HStack(spacing: 5) {
            mark().accessibilityHidden(true)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
