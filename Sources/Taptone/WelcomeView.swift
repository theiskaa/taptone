import AppKit
import SwiftUI
import TaptoneCore

/// Shown on first launch, before Taptone listens, so the system audio prompt never arrives unexplained.
struct WelcomeView: View {
    struct Actions {
        let toggleKickTest: () -> Void
        let openTrackpadSettings: () -> Void
        let start: () -> Void
    }

    let activity: ActivityModel
    let actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)
                .accessibilityHidden(true)
            Text("Welcome to Taptone")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 10)
            Text("Feel the bass of anything playing on your Mac, right through your trackpad.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 18) {
                feature("waveform", "Bass you can feel",
                        "Bass notes hum in tune and kicks land as a thump, in time with what you hear.")
                feature("hand.point.up.left", "Rest a fingertip on the trackpad",
                        "A light touch is all it takes. Your speakers or headphones play as usual.")
                feature("lock", "Private by design",
                        "Taptone listens to what’s playing only while it’s open. Nothing is recorded, saved, or sent anywhere.")
            }
            .padding(.top, 28)

            kickTest.padding(.top, 26)

            Spacer(minLength: 20)
            Button(action: actions.start) {
                Text("Continue").frame(width: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Text("macOS will ask once to allow system audio recording.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 10)
        }
        .padding(.horizontal, 44)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .frame(width: 500, height: 640)
        .tint(Brand.tint)
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(Brand.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Motor test

    private var kickTest: some View {
        HStack(spacing: 12) {
            KickDots(test: activity.kickTest)
            VStack(alignment: .leading, spacing: 1) {
                Text(testTitle).font(.callout.weight(.medium))
                Text(testDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if activity.kickTest == .finished {
                Button("Trackpad Settings…", action: actions.openTrackpadSettings).buttonStyle(.link)
            }
            Button(testButton, action: actions.toggleKickTest)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var testTitle: String {
        switch activity.kickTest {
        case .idle: "Try the motor first"
        case .running(0): "Rest a fingertip on the trackpad"
        case .running(let sent): "Kick \(sent) of \(KickTest.count)"
        case .finished: "That’s how a kick feels"
        case .failed: "The motor stopped responding"
        }
    }

    private var testDetail: String {
        switch activity.kickTest {
        case .idle: "Four kicks, one a second. No audio needed."
        case .running: activity.usesMotor ? "Sent to the trackpad motor." : "Sent as standard taps."
        case .finished: "Felt nothing? Turn on Force Click in Trackpad Settings."
        case .failed: "Try again, or restart your Mac if it keeps happening."
        }
    }

    private var testButton: String {
        switch activity.kickTest {
        case .idle: "Try"
        case .running: "Stop"
        case .finished, .failed: "Again"
        }
    }
}

/// Four dots, filled as kicks are sent; the newest one stays enlarged while the test runs.
private struct KickDots: View {
    let test: ActivityModel.KickTestState

    private var sent: Int {
        switch test {
        case .idle, .failed: 0
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
