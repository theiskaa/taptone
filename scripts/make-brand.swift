// Draws Taptone's brand from one set of shapes: the app icon (App/AppIcon.icns), the logo
// (assets/logo.svg), and the README banners (assets/banner-light.svg, assets/banner-dark.svg).
// One idea: a sound wave on a trackpad. The menu bar glyph (Sources/Taptone/TouchIcon.swift) draws the same.
// Text becomes outlines, so the banners look the same on every machine.
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

/// The trackpad: a pane of frosted glass on the tile.
let pad = CGRect(x: 222, y: 322, width: 580, height: 400)
let padRadius: CGFloat = 68

/// The sound: a sine that swells in the middle and fades at both ends, as the app draws it.
func wave(in rect: CGRect, amplitude: CGFloat, cycles: CGFloat, steps: Int = 240) -> CGPath {
    let path = CGMutablePath()
    for step in 0...steps {
        let u = CGFloat(step) / CGFloat(steps)
        let swell = sin(.pi * u)
        let point = CGPoint(x: rect.minX + u * rect.width, y: rect.midY - amplitude * swell * sin(2 * .pi * cycles * u))
        step == 0 ? path.move(to: point) : path.addLine(to: point)
    }
    return path
}

let waveRect = CGRect(x: 292, y: 422, width: 440, height: 200)
let wavePath = wave(in: waveRect, amplitude: 120, cycles: 2)
let waveStroke: CGFloat = 42

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

    // The tile with the standard macOS drop shadow.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: CGColor(gray: 0, alpha: 0.32))
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
    let sheen = CGGradient(colorsSpace: space, colors: [color(white, 0.16), color(white, 0)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(sheen, start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: 512), options: [])

    // The trackpad, with a soft shadow under it.
    let padPath = CGPath(roundedRect: pad, cornerWidth: padRadius, cornerHeight: padRadius, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: 12), blur: 36, color: CGColor(gray: 0, alpha: 0.22))
    cg.addPath(padPath)
    cg.setFillColor(color(white, 0.13))
    cg.fillPath()
    cg.restoreGState()
    cg.addPath(padPath)
    cg.setStrokeColor(color(white, 0.30))
    cg.setLineWidth(5)
    cg.strokePath()
    cg.restoreGState()

    cg.addPath(wavePath)
    cg.setStrokeColor(color(white))
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

func svgPath(_ path: CGPath) -> String {
    var d: [String] = []
    func f(_ v: CGFloat) -> String {
        let s = String(format: "%.2f", v)
        return s.hasSuffix(".00") ? String(s.dropLast(3)) : s
    }
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

/// The icon as SVG elements in the 1024 canvas. `id` keeps gradient ids unique per file.
func iconSVG(id: String) -> String {
    """
    <defs>
        <linearGradient id="\(id)-fill" x1="0" y1="\(Int(tile.minY))" x2="0" y2="\(Int(tile.maxY))" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="\(pine.top)"/><stop offset="1" stop-color="\(pine.bottom)"/>
        </linearGradient>
        <linearGradient id="\(id)-sheen" x1="0" y1="\(Int(tile.minY))" x2="0" y2="512" gradientUnits="userSpaceOnUse">
          <stop offset="0" stop-color="\(white)" stop-opacity="0.16"/><stop offset="1" stop-color="\(white)" stop-opacity="0"/>
        </linearGradient>
      </defs>
      <rect x="\(Int(tile.minX))" y="\(Int(tile.minY))" width="\(Int(tile.width))" height="\(Int(tile.height))" rx="\(Int(tileRadius))" fill="url(#\(id)-fill)"/>
      <rect x="\(Int(tile.minX))" y="\(Int(tile.minY))" width="\(Int(tile.width))" height="\(Int(tile.height))" rx="\(Int(tileRadius))" fill="url(#\(id)-sheen)"/>
      <rect x="\(Int(pad.minX))" y="\(Int(pad.minY))" width="\(Int(pad.width))" height="\(Int(pad.height))" rx="\(Int(padRadius))" fill="\(white)" fill-opacity="0.13" stroke="\(white)" stroke-opacity="0.30" stroke-width="5"/>
      <path d="\(svgPath(wavePath))" fill="none" stroke="\(white)" stroke-width="\(Int(waveStroke))" stroke-linecap="round" stroke-linejoin="round"/>
    """
}

/// `text` as outlines with its baseline at `origin`, y-down.
func textPath(_ text: String, font: NSFont, origin: CGPoint) -> (path: CGPath, width: CGFloat) {
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        for (glyph, position) in zip(glyphs, positions) {
            guard let outline = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
            let place = CGAffineTransform(translationX: origin.x + position.x, y: origin.y).scaledBy(x: 1, y: -1)
            path.addPath(outline, transform: place)
        }
    }
    return (path, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
}

func banner(ink: String, ink2: String, id: String) -> String {
    let display = NSFont.systemFont(ofSize: 52, weight: .semibold)
    let sans = NSFont.systemFont(ofSize: 19, weight: .regular)
    let iconSize: CGFloat = 112, textX: CGFloat = 124
    let title = textPath("Taptone", font: display, origin: CGPoint(x: textX, y: 62))
    let tagline = textPath("Feel the bass through your trackpad", font: sans, origin: CGPoint(x: textX + 2, y: 94))
    let width = Int((textX + max(title.width, tagline.width + 2) + 8).rounded(.up))
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(width) 112" width="\(width)" height="112">
      <title>Taptone: feel the bass through your trackpad</title>
      <g transform="scale(\(iconSize / 1024))">
      \(iconSVG(id: id))
      </g>
      <path fill="\(ink)" d="\(svgPath(title.path))"/>
      <path fill="\(ink2)" d="\(svgPath(tagline.path))"/>
    </svg>

    """
}

// MARK: Write

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appending(path: "assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let logo = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <title>Taptone</title>
  \(iconSVG(id: "logo"))
</svg>

"""
try logo.write(to: assets.appending(path: "logo.svg"), atomically: true, encoding: .utf8)
try banner(ink: "#1F1E1B", ink2: "#66625A", id: "light").write(to: assets.appending(path: "banner-light.svg"), atomically: true, encoding: .utf8)
try banner(ink: "#EDEBE6", ink2: "#A9A59C", id: "dark").write(to: assets.appending(path: "banner-dark.svg"), atomically: true, encoding: .utf8)
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
print("Wrote App/AppIcon.icns, assets/logo.svg, assets/icon.png, assets/banner-light.svg, assets/banner-dark.svg")
