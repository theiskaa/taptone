import AppKit
import TaptoneCore
import TaptoneHaptics

/// The menu's top block: name, status and pause switch; a live row with the bass note and its carrier;
/// then intensity and kick sensitivity. AppKit, not SwiftUI: SwiftUI doesn't redraw while a menu is
/// tracking, and this view changes while the menu is open. Call `update` whenever state changes.
@MainActor
final class MenuHeaderView: NSView {
    static let width: CGFloat = 272

    private let status = NSTextField(labelWithString: "")
    private let onOff = MenuSwitch()
    private let liveRow = NSView()
    private let wave = WaveView()
    private let note = NSTextField(labelWithString: "")
    private let intensity = MenuSegments(HapticIntensity.allCases.map { $0.rawValue.capitalized }, name: "Intensity")
    private let sensitivity = MenuSegments(BeatDetector.Sensitivity.allCases.map { $0.rawValue.capitalized }, name: "Kick sensitivity")
    private let stack = NSStackView()

    init(settings: Settings, toggle: @escaping () -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 40))
        onOff.setAccessibilityLabel("Haptics")
        onOff.onChange = toggle
        intensity.onChange = { [unowned intensity] in settings.intensity = HapticIntensity.allCases[intensity.selected] }
        sensitivity.onChange = { [unowned sensitivity] in
            settings.sensitivity = BeatDetector.Sensitivity.allCases[sensitivity.selected]
        }

        let title = NSTextField(labelWithString: "Taptone")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [title, status])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        note.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        note.textColor = .secondaryLabelColor
        note.alignment = .right
        liveRow.setAccessibilityElement(true)
        liveRow.setAccessibilityRole(.staticText)
        liveRow.wantsLayer = true
        liveRow.layer?.cornerRadius = 7
        liveRow.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        for view in [wave, note] {
            view.translatesAutoresizingMaskIntoConstraints = false
            liveRow.addSubview(view)
        }
        NSLayoutConstraint.activate([
            liveRow.heightAnchor.constraint(equalToConstant: 28),
            wave.leadingAnchor.constraint(equalTo: liveRow.leadingAnchor, constant: 8),
            wave.topAnchor.constraint(equalTo: liveRow.topAnchor, constant: 4),
            wave.bottomAnchor.constraint(equalTo: liveRow.bottomAnchor, constant: -4),
            note.leadingAnchor.constraint(equalTo: wave.trailingAnchor, constant: 8),
            note.trailingAnchor.constraint(equalTo: liveRow.trailingAnchor, constant: -8),
            // A fixed width, so the wave doesn't jump as the text changes.
            note.widthAnchor.constraint(equalToConstant: 92),
            note.centerYAnchor.constraint(equalTo: liveRow.centerYAnchor),
        ])

        var rows: [NSView] = [Self.row(labels, onOff), liveRow]
        rows.append(Self.row(Self.caption("Intensity"), intensity))
        rows.append(Self.row(Self.caption("Kicks"), sensitivity))

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 6, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        fitHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func update(_ activity: ActivityModel, settings: Settings) {
        status.stringValue = activity.summary
        status.textColor = { if case .failed = activity.phase { NSColor.systemOrange } else { .secondaryLabelColor } }()
        onOff.isOn = activity.phase.isLive
        intensity.selected = HapticIntensity.allCases.firstIndex(of: settings.intensity) ?? 1
        intensity.isEnabled = activity.usesMotor // Standard taps have one fixed strength.
        sensitivity.selected = BeatDetector.Sensitivity.allCases.firstIndex(of: settings.sensitivity) ?? 1

        // The row always stays; a flat line means nothing is playing on the trackpad.
        let live = activity.phase.isLive ? activity.live : nil
        wave.level = live?.shownLevel ?? 0
        wave.carrierHz = live?.carrierHz ?? HapticSynth.restingHz
        wave.needsDisplay = true
        let text = liveText(activity, live)
        if note.stringValue != text {
            note.stringValue = text
            liveRow.setAccessibilityLabel(text)
        }
    }

    private func liveText(_ activity: ActivityModel, _ live: HapticPlayer.Reading?) -> String {
        guard activity.phase.isLive else { return "—" }
        guard activity.usesMotor else { return "Kicks only" }
        guard let live, live.body >= HapticSynth.bodyGate else { return "No bass" }
        let hertz = "\(Int(live.carrierHz.rounded())) Hz"
        return activity.note.map { "\($0.name) · \(hertz)" } ?? hertz
    }

    private func fitHeight() {
        stack.layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: Self.width, height: stack.fittingSize.height))
    }

    private static func row(_ leading: NSView, _ trailing: NSView) -> NSStackView {
        let row = NSStackView(views: [leading, NSView(), trailing])
        row.distribution = .fill
        row.alignment = .centerY
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }
}

/// A short tapered sine whose height follows the motor level and whose wavelength follows the carrier.
private final class WaveView: NSView {
    var level = 0.0
    var carrierHz = HapticSynth.restingHz

    override func draw(_ dirtyRect: NSRect) {
        // Flat when nothing is playing on the trackpad.
        let amplitude = level > 0.01 ? 2 + 6 * level : 0
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let wave = SoundWave(amplitude: amplitude, cycles: carrierHz / 36,
                             phase: still ? 0 : Date.timeIntervalSinceReferenceDate * 7)
        let path = wave.bezierPath(in: bounds, steps: 60)
        path.lineWidth = 1.4
        NSColor.secondaryLabelColor.setStroke()
        path.stroke()
    }
}
