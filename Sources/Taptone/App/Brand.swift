import AppKit
import SwiftUI

/// Taptone's one color, pine, tuned for light and dark. Everything else uses system colors.
@MainActor
enum Brand {
    static let tintColor = NSColor(name: "TaptoneTint") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.42, green: 0.78, blue: 0.59, alpha: 1)
            : NSColor(srgbRed: 0.20, green: 0.48, blue: 0.36, alpha: 1)
    }
    static let tint = Color(nsColor: tintColor)
}

/// A sine that swells in the middle and fades at both ends: the sound on the trackpad. The menu bar
/// glyph, the menu's live row, and the main window draw it; scripts/make-brand.swift draws the icon's.
struct SoundWave {
    var amplitude: Double
    var cycles: Double
    var phase = 0.0

    /// Points across `rect`, centered on its middle line. In a flipped (y-down) space, peaks go up.
    func points(in rect: CGRect, steps: Int = 96) -> [CGPoint] {
        (0...steps).map { step in
            let u = Double(step) / Double(steps)
            return CGPoint(x: rect.minX + u * rect.width,
                           y: rect.midY - amplitude * sin(.pi * u) * sin(2 * .pi * cycles * u - phase))
        }
    }

    func path(in rect: CGRect, steps: Int = 96) -> Path {
        Path { $0.addLines(points(in: rect, steps: steps)) }
    }

    func bezierPath(in rect: CGRect, steps: Int = 96) -> NSBezierPath {
        let path = NSBezierPath()
        for (index, point) in points(in: rect, steps: steps).enumerated() {
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }
}
