// Draws Taptone's app icon (App/AppIcon.icns) and logo (assets/logo.svg, assets/icon.png) from one set of shapes.
// The mark is the menu bar glyph (Sources/Taptone/TouchIcon.swift) scaled up: a trackpad outline with the
// sound wave inside, in white on a pine tile.
//
//     swift scripts/make-brand.swift
import AppKit

// MARK: Shapes, in a y-down 1024 × 1024 canvas.

struct Paint { let top: String, bottom: String }

/// Pine, the app's tint, lit from above.
let pine = Paint(top: "#4C8A6B", bottom: "#1C3A2C")
let white = "#FFFFFF"

/// The squircle macOS icons sit in: 824 points on a 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185

/// The glyph is drawn on an 18 × 16 canvas: a 15 × 11 pad (radius 3, line 1.2) centered on (9, 8), and a
/// wave from x 4.5 to 13.5 on y 8 (line 1.3, amplitude up to 2.9). `glyph` maps that canvas onto the tile.
let glyphScale: CGFloat = 35
func glyph(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: 512 + (x - 9) * glyphScale, y: 512 + (y - 8) * glyphScale) }

/// The trackpad: a white outline.
let pad = CGRect(origin: glyph(1.5, 2.5), size: CGSize(width: 15 * glyphScale, height: 11 * glyphScale))
let padRadius: CGFloat = 3 * glyphScale
let padStroke: CGFloat = 40

/// The sound: a sine that swells in the middle and fades at both ends, as the app draws it.
func wave(from start: CGPoint, to end: CGPoint, amplitude: CGFloat, cycles: CGFloat, steps: Int = 240) -> CGPath {
    let path = CGMutablePath()
    for step in 0...steps {
        let u = CGFloat(step) / CGFloat(steps)
        let swell = sin(.pi * u)
        let point = CGPoint(x: start.x + u * (end.x - start.x), y: start.y - amplitude * swell * sin(2 * .pi * cycles * u))
        step == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    return path
}

let wavePath = wave(from: glyph(4.5, 8), to: glyph(13.5, 8), amplitude: 2.9 * glyphScale, cycles: 2)
let waveStroke: CGFloat = 44

// MARK: Raster icon

func renderIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = context.cgContext
    let scale = CGFloat(pixels) / 1024
    cg.translateBy(x: 0, y: CGFloat(pixels))
    cg.scaleBy(x: scale, y: -scale) // y-down, 1024 units

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil)

    // The tile with the standard macOS drop shadow. Shadows ignore the transform: they are given in pixels, y-up.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale, color: CGColor(gray: 0, alpha: 0.3))
    cg.addPath(tilePath)
    cg.setFillColor(color(pine.bottom))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(tilePath)
    cg.clip()
    let fill = CGGradient(colorsSpace: space, colors: [color(pine.top), color(pine.bottom)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(fill, start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])
    // Light from above.
    let sheen = CGGradient(colorsSpace: space, colors: [color(white, 0.10), color(white, 0)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(sheen, start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: 512), options: [])
    cg.restoreGState()

    cg.setStrokeColor(color(white))
    cg.addPath(CGPath(roundedRect: pad, cornerWidth: padRadius, cornerHeight: padRadius, transform: nil))
    cg.setLineWidth(padStroke)
    cg.strokePath()

    cg.addPath(wavePath)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.setLineWidth(waveStroke)
    cg.strokePath()

    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

func color(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
    let value = Int(hex.dropFirst(), radix: 16)!
    return CGColor(srgbRed: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                   blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

// MARK: SVG

func f(_ v: CGFloat) -> String {
    let s = String(format: "%.2f", v)
    return s.hasSuffix(".00") ? String(s.dropLast(3)) : s
}

func svgPath(_ path: CGPath) -> String {
    var d: [String] = []
    path.applyWithBlock { element in
        let e = element.pointee, p = e.points
        switch e.type {
        case .moveToPoint: d.append("M\(f(p[0].x)) \(f(p[0].y))")
        case .addLineToPoint: d.append("L\(f(p[0].x)) \(f(p[0].y))")
        case .addQuadCurveToPoint: d.append("Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))")
        case .addCurveToPoint:
            d.append("C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))")
        case .closeSubpath: d.append("Z")
        @unknown default: break
        }
    }
    return d.joined()
}

let logo = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <title>Taptone</title>
  <defs>
    <linearGradient id="fill" x1="0" y1="\(f(tile.minY))" x2="0" y2="\(f(tile.maxY))" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="\(pine.top)"/><stop offset="1" stop-color="\(pine.bottom)"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="\(f(tile.minY))" x2="0" y2="512" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="\(white)" stop-opacity="0.10"/><stop offset="1" stop-color="\(white)" stop-opacity="0"/>
    </linearGradient>
    <filter id="shadow" x="-10%" y="-10%" width="120%" height="125%">
      <feDropShadow dx="0" dy="10" stdDeviation="14" flood-color="#000" flood-opacity="0.3"/>
    </filter>
  </defs>
  <rect x="\(f(tile.minX))" y="\(f(tile.minY))" width="\(f(tile.width))" height="\(f(tile.height))" rx="\(f(tileRadius))" fill="url(#fill)" filter="url(#shadow)"/>
  <rect x="\(f(tile.minX))" y="\(f(tile.minY))" width="\(f(tile.width))" height="\(f(tile.height))" rx="\(f(tileRadius))" fill="url(#sheen)"/>
  <g fill="none" stroke="\(white)" stroke-linecap="round" stroke-linejoin="round">
    <rect x="\(f(pad.minX))" y="\(f(pad.minY))" width="\(f(pad.width))" height="\(f(pad.height))" rx="\(f(padRadius))" stroke-width="\(f(padStroke))"/>
    <path d="\(svgPath(wavePath))" stroke-width="\(f(waveStroke))"/>
  </g>
</svg>

"""

// MARK: Write

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appending(path: "assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try logo.write(to: assets.appending(path: "logo.svg"), atomically: true, encoding: .utf8)
try renderIcon(pixels: 512).write(to: assets.appending(path: "icon.png"))

let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try renderIcon(pixels: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try renderIcon(pixels: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["--convert", "icns", "--output", root.appending(path: "App/AppIcon.icns").path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote App/AppIcon.icns, assets/logo.svg, assets/icon.png")
