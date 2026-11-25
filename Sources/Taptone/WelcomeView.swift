import AppKit
import SwiftUI

/// Shown on first launch, before Taptone listens, so the system audio prompt never arrives unexplained.
/// Opened again later, it's only a tour: Done closes it.
struct WelcomeView: View {
    struct Actions {
        let toggleKickTest: () -> Void
        let openTrackpadSettings: () -> Void
        let start: () -> Void
    }

    let activity: ActivityModel
    let firstRun: Bool
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
                        "Audio is felt as it plays, right on your Mac. It’s never saved or sent anywhere.")
            }
            .padding(.top, 28)

            KickTestView(activity: activity, toggle: actions.toggleKickTest,
                         openTrackpadSettings: actions.openTrackpadSettings)
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 26)

            Spacer(minLength: 20)
            Button(action: actions.start) {
                Text(firstRun ? "Continue" : "Done").frame(width: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            Text(firstRun
                 ? "Next, macOS asks to allow system audio recording. Taptone only listens.\nAfterwards, find Taptone in the menu bar."
                 : "Taptone lives in the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .padding(.horizontal, 44)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 500, height: 650)
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
}
