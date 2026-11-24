import AppKit

/// The status item: a trackpad with the sound on it, as in the app icon. While bass plays, the wave
/// grows with the bass level in four steps; it never flashes on kicks.
@MainActor
enum TouchIcon {
    enum State: Hashable {
        case off, connecting, waiting, listening(step: Int), taps, demo, failed
    }

    private static let amplitudes = [1.1, 1.7, 2.3, 2.9]
    private static var cache: [State: NSImage] = [:]

    static func image(_ state: State) -> NSImage {
        if let image = cache[state] { return image }
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let pad = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2.5, width: 15, height: 11), xRadius: 3, yRadius: 3)
            pad.lineWidth = 1.2
            pad.stroke()
            switch state {
            case .off: line(dashed: false, alpha: 0.5)
            case .connecting: line(dashed: true, alpha: 1)
            case .waiting: line(dashed: false, alpha: 1)
            case .taps: wave(amplitudes[0])
            case .listening(let step): wave(amplitudes[min(3, max(0, step))])
            case .demo:
                NSColor.black.withAlphaComponent(0.45).setStroke()
                wave(amplitudes[1])
            case .failed:
                let mark = NSBezierPath()
                mark.move(to: NSPoint(x: 9, y: 5))
                mark.line(to: NSPoint(x: 9, y: 8.6))
                mark.lineWidth = 1.5
                mark.lineCapStyle = .round
                mark.stroke()
                NSBezierPath(ovalIn: NSRect(x: 8.2, y: 10, width: 1.6, height: 1.6)).fill()
            }
            return true
        }
        image.isTemplate = true
        cache[state] = image
        return image
    }

    private static let lane = (from: 4.5, to: 13.5, y: 8.0)

    private static func wave(_ amplitude: Double) {
        let path = SoundWave(amplitude: amplitude, cycles: 2)
            .bezierPath(in: CGRect(x: lane.from, y: lane.y, width: lane.to - lane.from, height: 0), steps: 32)
        path.lineWidth = 1.3
        path.stroke()
    }

    private static func line(dashed: Bool, alpha: Double) {
        NSColor.black.withAlphaComponent(alpha).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: lane.from, y: lane.y))
        path.line(to: NSPoint(x: lane.to, y: lane.y))
        path.lineWidth = 1.3
        path.lineCapStyle = .round
        if dashed { path.setLineDash([1.5, 2], count: 2, phase: 0) }
        path.stroke()
    }
}
