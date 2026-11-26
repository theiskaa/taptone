import SwiftUI
import TaptoneCore
import TaptoneHaptics

/// What the trackpad is doing now: the status, the sound on the pad, the bass note, and the last 12 seconds.
struct LiveCard: View {
    let activity: ActivityModel
    let actions: MainView.Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if case .failed(let problem, let needsAccess) = activity.phase {
                failure(problem, needsAccess: needsAccess)
            } else if activity.phase == .noTrackpad {
                failure("Taptone plays on a Force Touch trackpad: the one built into a MacBook, or a Magic Trackpad 2 or later.",
                        needsAccess: false)
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !animates)) { timeline in
                    VStack(spacing: 12) {
                        pad(at: timeline.date)
                        HistoryStrip(history: activity.history, now: HostClock.nowNs(), showsMotor: playsMotor)
                            .frame(height: 22)
                    }
                }
                footer
            }
        }
        .padding(14)
    }

    /// Only while something plays: waiting for audio draws a still, flat line.
    private var animates: Bool {
        switch activity.phase {
        case .listening(true), .preview: true
        default: false
        }
    }

    // MARK: Status

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    if activity.phase == .starting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                    }
                    Text(activity.title).font(.headline)
                }
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: actions.toggleHaptics) {
                Image(systemName: button.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .help(button.label)
            .accessibilityLabel(button.label)
        }
    }

    private var button: (symbol: String, label: String) {
        switch activity.phase {
        case .preview: ("stop.fill", "Stop demo")
        case let phase where phase.isLive: ("pause.fill", "Pause haptics")
        default: ("play.fill", activity.isPaused ? "Resume haptics" : "Start listening")
        }
    }

    private var statusColor: Color {
        switch activity.phase {
        case .listening(true): Brand.tint
        case .listening(false), .preview: .secondary
        case .failed, .noTrackpad: .orange
        default: Color(nsColor: .tertiaryLabelColor)
        }
    }

    private var subtitle: String {
        let output = activity.device?.name ?? "No output"
        switch activity.phase {
        case .off where activity.isPaused: return activity.pauseEnd.map { "Haptics resume at \($0)" } ?? "Haptics are paused"
        case .off where activity.inCall: return "Listening resumes when the call ends"
        case .off: return "Press play to listen"
        case .starting: return "Connecting to \(output)"
        case .listening(true): return activity.usesMotor ? "Following the bass on \(output)" : "One tap per kick on \(output)"
        case .listening(false) where activity.hearsOnlySilence: return "If audio is playing, allow system audio access"
        case .listening(false): return "Play something on \(output)"
        case .preview: return "Generated kicks, nothing sent to the trackpad"
        case .failed(_, let needsAccess): return needsAccess ? "Allow system audio access to start" : "Press play to try again"
        case .noTrackpad: return "Connect a Magic Trackpad, then press play"
        }
    }

    // MARK: The pad

    private func pad(at date: Date) -> some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let shape = Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 12)
            context.fill(shape, with: .color(.primary.opacity(0.035)))
            context.stroke(shape, with: .color(.primary.opacity(0.08)), lineWidth: 1)

            let lane = rect.insetBy(dx: 28, dy: 0)
            let now = HostClock.nowNs()
            let lastKick = lastKickNs
            // Reduce Motion keeps the wave still and drops the ring and the kick wobble.
            let kickAge = reduceMotion ? .infinity : lastKick.map { Double(now &- $0) / 1e9 } ?? .infinity
            if let ring = ringOpacity(kickAge) {
                let radius = 18 + kickAge * 200
                let circle = Path(ellipseIn: CGRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2))
                context.stroke(circle, with: .color(Brand.tint.opacity(ring)), lineWidth: 1.5)
            }
            let level = displayLevel(now: now)
            let style = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
            guard level > 0.01 else {
                context.stroke(SoundWave(amplitude: 0, cycles: 0).path(in: lane, steps: 1),
                               with: .color(Color(nsColor: .tertiaryLabelColor)), style: style)
                return
            }
            let kick = kickAge < 1 ? exp(-kickAge / 0.06) : 0
            let phase = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate * 7
            let wave = SoundWave(amplitude: 6 + 40 * level, cycles: carrierHz / 40 + kick * 2, phase: phase)
            context.stroke(SoundWave(amplitude: wave.amplitude * 0.5, cycles: wave.cycles, phase: phase - 0.9).path(in: lane),
                           with: .color(Brand.tint.opacity(0.3)), lineWidth: 1.2)
            context.stroke(wave.path(in: lane), with: .color(Brand.tint), style: style)
        }
        .frame(height: 112)
        .accessibilityElement()
        .accessibilityLabel(padDescription)
    }

    private func ringOpacity(_ age: Double) -> Double? {
        let opacity = 0.8 - age * 3.2
        return opacity > 0 ? opacity : nil
    }

    /// 0...1: the motor's level when it's playing. Without the motor, each kick swells and fades.
    private func displayLevel(now: UInt64) -> Double {
        guard animates else { return 0 }
        if playsMotor { return activity.live?.shownLevel ?? 0 }
        return activity.kickLevel(now: now)
    }

    private var playsMotor: Bool { activity.usesMotor && activity.phase != .preview }

    private var carrierHz: Double { activity.live?.carrierHz ?? HapticSynth.restingHz }

    private var lastKickNs: UInt64? {
        if playsMotor { return activity.live?.lastKickNs }
        return activity.history.samples.last { $0.kicks > 0 }?.timeNs
    }

    private var padDescription: String {
        guard let live = activity.live, activity.phase == .listening(hasSound: true), activity.usesMotor else {
            return "Trackpad: \(activity.title)"
        }
        let percent = Int(live.shownLevel * 100)
        return "Trackpad playing \(Int(live.carrierHz.rounded())) hertz at \(percent) percent"
    }

    // MARK: Note and kicks

    private var footer: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.note?.name ?? "—")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: activity.note?.name)
                Text(noteDetail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(activity.history.kickCount.formatted())
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(activity.phase == .preview ? "kicks detected" : "kicks played")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var noteDetail: String {
        guard activity.usesMotor, activity.phase.isLive else { return "Bass note" }
        guard let note = activity.note else { return "No steady bass note" }
        return String(format: "%.1f Hz, felt at %d Hz", note.hertz, Int(carrierHz.rounded()))
    }

    // MARK: Failure

    private func failure(_ problem: String, needsAccess: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(problem).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if needsAccess {
                HStack {
                    Button("Open Privacy & Security", action: actions.openPrivacySettings)
                    Button("Why Taptone Needs This", action: actions.explainAudioAccess).buttonStyle(.link)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
    }
}

/// The last 12 seconds: what was sent to the motor (or heard, without one), with a tick for each kick.
private struct HistoryStrip: View {
    let history: ActivityHistory
    let now: UInt64
    let showsMotor: Bool

    var body: some View {
        Canvas { context, size in
            let span = Double(ActivityHistory.durationNs)
            func x(_ time: UInt64) -> Double { size.width - Double(now &- time) / span * size.width }
            // Samples are in time order; skip the ones that have scrolled off.
            let samples = history.samples.drop { now &- $0.timeNs >= ActivityHistory.durationNs }

            var area = Path()
            area.move(to: CGPoint(x: samples.first.map { x($0.timeNs) } ?? 0, y: size.height))
            for sample in samples {
                let value = showsMotor ? Double(sample.motorLevel / HapticPlayer.Reading.fullScaleLevel) : Double(sample.levelDBFS + 60) / 60
                area.addLine(to: CGPoint(x: x(sample.timeNs), y: size.height * (1 - min(1, max(0, value)) * 0.8)))
            }
            area.addLine(to: CGPoint(x: samples.last.map { x($0.timeNs) } ?? 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(Brand.tint.opacity(0.22)))

            var ticks = Path()
            for sample in samples where sample.kicks > 0 {
                ticks.addRoundedRect(in: CGRect(x: x(sample.timeNs) - 1, y: 0, width: 2, height: 5), cornerSize: CGSize(width: 1, height: 1))
            }
            context.fill(ticks, with: .color(Brand.tint))

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(baseline, with: .color(.primary.opacity(0.1)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
