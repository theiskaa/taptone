import SwiftUI
import TaptoneCore

/// Four kicks, one a second, with no audio: how a kick feels, and whether the motor works.
/// The welcome shows it as a panel; the main window as a row.
struct KickTestView: View {
    let activity: ActivityModel
    let toggle: () -> Void
    let openTrackpadSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            KickDots(test: activity.kickTest)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if activity.kickTest == .finished {
                Button("Trackpad Settings…", action: openTrackpadSettings).buttonStyle(.link)
            }
            Button(button, action: toggle)
        }
    }

    private var title: String {
        switch activity.kickTest {
        case .idle: "Try the motor"
        case .running(0): "Rest a fingertip on the trackpad"
        case .running(let sent): "Kick \(sent) of \(KickTest.count)"
        case .finished: "That’s how a kick feels"
        case .failed: "The motor stopped responding"
        case .noTrackpad: "No Force Touch trackpad found"
        }
    }

    private var detail: String {
        switch activity.kickTest {
        case .idle: "Four kicks, one a second. No audio needed."
        case .running: "Feel for a thump."
        case .finished: "Felt nothing? Turn on Force Click and haptic feedback in Trackpad Settings."
        case .failed: "Try again, or restart your Mac if it keeps happening."
        case .noTrackpad: "Taptone needs a MacBook trackpad or a Magic Trackpad 2 or later."
        }
    }

    private var button: String {
        switch activity.kickTest {
        case .idle: "Try"
        case .running: "Stop"
        case .finished, .failed, .noTrackpad: "Again"
        }
    }
}

/// Four dots, filled as kicks are sent; the newest one stays enlarged while the test runs.
private struct KickDots: View {
    let test: ActivityModel.KickTestState

    private var sent: Int {
        switch test {
        case .idle, .failed, .noTrackpad: 0
        case .running(let sent): sent
        case .finished: KickTest.count
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<KickTest.count, id: \.self) { index in
                Circle()
                    .fill(index < sent ? Brand.tint : Color.secondary.opacity(0.25))
                    .frame(width: 8, height: 8)
                    .scaleEffect(index == sent - 1 && test != .finished ? 1.35 : 1)
                    .animation(.spring(duration: 0.3, bounce: 0.5), value: test)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(sent) of \(KickTest.count) kicks sent")
    }
}
