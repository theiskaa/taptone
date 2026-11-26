import AppKit

/// Controls drawn for the menu header. AppKit's own switch and segmented control draw in their
/// inactive (gray) style inside a menu, because a menu's window is never key.
@MainActor
class MenuControl: NSControl {
    var onChange: () -> Void = {}

    override var acceptsFirstResponder: Bool { false }
    // A bare NSControl isn't exposed to VoiceOver, so its role, label and actions would go unseen.
    override func isAccessibilityElement() -> Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            alphaValue = isEnabled ? 1 : 0.4
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        clicked(at: convert(event.locationInWindow, from: nil))
    }

    func clicked(at point: NSPoint) {}
}

/// An on/off switch in the accent color.
@MainActor
final class MenuSwitch: MenuControl {
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(isOn)
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        setAccessibilityValue(isOn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 18) }

    override func clicked(at point: NSPoint) {
        isOn.toggle()
        onChange()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        clicked(at: .zero)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (isOn ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.16)).setFill()
        track.fill()
        let inset: CGFloat = 1.5
        let diameter = bounds.height - inset * 2
        let knob = NSRect(x: isOn ? bounds.maxX - inset - diameter : bounds.minX + inset, y: inset,
                          width: diameter, height: diameter)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.3)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1.5
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// A pick-one row of equal segments; the chosen one is a raised pill.
@MainActor
final class MenuSegments: MenuControl {
    let labels: [String]
    var selected = 0 {
        didSet {
            guard selected != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(labels.indices.contains(selected) ? labels[selected] : nil)
        }
    }

    init(_ labels: [String], name: String) {
        self.labels = labels
        super.init(frame: .zero)
        // Adjustable like a slider, so VoiceOver can step through the choices.
        setAccessibilityRole(.slider)
        setAccessibilityLabel(name)
        setAccessibilityValue(labels.first)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override var intrinsicContentSize: NSSize { NSSize(width: 168, height: 22) }

    override func clicked(at point: NSPoint) {
        choose(Int(point.x / (bounds.width / CGFloat(labels.count))))
    }

    override func accessibilityPerformIncrement() -> Bool { choose(selected + 1) }
    override func accessibilityPerformDecrement() -> Bool { choose(selected - 1) }

    @discardableResult
    private func choose(_ index: Int) -> Bool {
        guard isEnabled, labels.indices.contains(index), index != selected else { return false }
        selected = index
        onChange()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor.labelColor.withAlphaComponent(dark ? 0.10 : 0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let width = bounds.width / CGFloat(labels.count)
        for (index, label) in labels.enumerated() {
            let cell = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
            let chosen = index == selected
            if chosen {
                let pill = cell.insetBy(dx: 2, dy: 2)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = .black.withAlphaComponent(dark ? 0.4 : 0.16)
                shadow.shadowOffset = NSSize(width: 0, height: -0.5)
                shadow.shadowBlurRadius = 1.5
                shadow.set()
                (dark ? NSColor.white.withAlphaComponent(0.22) : .white).setFill()
                NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            let text = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: chosen ? .medium : .regular),
                .foregroundColor: chosen ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2))
        }
    }
}
