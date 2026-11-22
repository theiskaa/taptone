import AppKit

@MainActor
enum TouchIcon {
    static func image(listening: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            NSColor.black.setStroke()
            let finger = NSBezierPath()
            finger.lineCapStyle = .round
            finger.lineJoinStyle = .round
            finger.lineWidth = 1.3
            finger.move(to: CGPoint(x: 5.4, y: 13.75))
            finger.line(to: CGPoint(x: 2.9, y: 10.35))
            finger.curve(
                to: CGPoint(x: 4.2, y: 8.9),
                controlPoint1: CGPoint(x: 2.1, y: 9.25),
                controlPoint2: CGPoint(x: 3.35, y: 8.15)
            )
            finger.line(to: CGPoint(x: 5.9, y: 10.25))
            finger.line(to: CGPoint(x: 5.9, y: 4.65))
            finger.curve(
                to: CGPoint(x: 8.4, y: 4.65),
                controlPoint1: CGPoint(x: 5.9, y: 2.98),
                controlPoint2: CGPoint(x: 8.4, y: 2.98)
            )
            finger.line(to: CGPoint(x: 8.4, y: 7.05))
            finger.line(to: CGPoint(x: 10.85, y: 7.05))
            finger.curve(
                to: CGPoint(x: 12.95, y: 9.2),
                controlPoint1: CGPoint(x: 12.25, y: 7.05),
                controlPoint2: CGPoint(x: 13.1, y: 7.9)
            )
            finger.line(to: CGPoint(x: 12.45, y: 13.75))
            finger.stroke()

            if listening {
                let marks = NSBezierPath()
                marks.lineCapStyle = .round
                marks.lineWidth = 1.15
                marks.move(to: CGPoint(x: 3.95, y: 2.65))
                marks.line(to: CGPoint(x: 3.15, y: 1.55))
                marks.move(to: CGPoint(x: 10.35, y: 2.65))
                marks.line(to: CGPoint(x: 11.15, y: 1.55))
                marks.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
