import AppKit
import SwiftUI

@MainActor
enum ActivityPalette {
    static let paper = adaptive(light: (249, 248, 245), dark: (33, 32, 29))
    static let plot = Color(nsColor: adaptive(light: (241, 239, 234), dark: (42, 40, 36)))
    static let pulse = Color(nsColor: adaptive(light: (57, 98, 77), dark: (166, 200, 178)))
    static let button = Color(nsColor: adaptive(light: (49, 84, 68), dark: (69, 108, 89)))

    private static func adaptive(light: (Int, Int, Int), dark: (Int, Int, Int)) -> NSColor {
        NSColor(name: nil) { appearance in
            let (red, green, blue) = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: 1)
        }
    }
}
