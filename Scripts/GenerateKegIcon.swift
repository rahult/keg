import AppKit
import Foundation

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func barrelPath(in rect: NSRect) -> NSBezierPath {
    let x = rect.minX
    let y = rect.minY
    let w = rect.width
    let h = rect.height
    let inset = w * 0.16

    let path = NSBezierPath()
    path.move(to: NSPoint(x: x + inset, y: y + h))
    path.curve(
        to: NSPoint(x: x + w - inset, y: y + h),
        controlPoint1: NSPoint(x: x + w * 0.28, y: y + h + h * 0.08),
        controlPoint2: NSPoint(x: x + w * 0.72, y: y + h + h * 0.08)
    )
    path.curve(
        to: NSPoint(x: x + w * 0.92, y: y + h * 0.54),
        controlPoint1: NSPoint(x: x + w * 1.00, y: y + h * 0.94),
        controlPoint2: NSPoint(x: x + w * 1.04, y: y + h * 0.76)
    )
    path.curve(
        to: NSPoint(x: x + w - inset, y: y),
        controlPoint1: NSPoint(x: x + w * 1.02, y: y + h * 0.34),
        controlPoint2: NSPoint(x: x + w * 0.98, y: y + h * 0.06)
    )
    path.curve(
        to: NSPoint(x: x + inset, y: y),
        controlPoint1: NSPoint(x: x + w * 0.70, y: y - h * 0.08),
        controlPoint2: NSPoint(x: x + w * 0.30, y: y - h * 0.08)
    )
    path.curve(
        to: NSPoint(x: x + w * 0.08, y: y + h * 0.54),
        controlPoint1: NSPoint(x: x + w * 0.02, y: y + h * 0.06),
        controlPoint2: NSPoint(x: x - w * 0.02, y: y + h * 0.34)
    )
    path.curve(
        to: NSPoint(x: x + inset, y: y + h),
        controlPoint1: NSPoint(x: x - w * 0.04, y: y + h * 0.76),
        controlPoint2: NSPoint(x: x + w * 0.01, y: y + h * 0.94)
    )
    path.close()
    return path
}

func drawIcon(size: CGFloat, to path: String) throws {
    let pixels = Int(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "GenerateKegIcon", code: 1)
    }

    rep.size = NSSize(width: size, height: size)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "GenerateKegIcon", code: 2)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.interpolationQuality = .high
    context.shouldAntialias = true

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    let baseRect = canvas.insetBy(dx: size * 0.055, dy: size * 0.055)
    let basePath = roundedRect(baseRect, radius: size * 0.22)

    let baseShadow = NSShadow()
    baseShadow.shadowOffset = NSSize(width: 0, height: -size * 0.018)
    baseShadow.shadowBlurRadius = size * 0.06
    baseShadow.shadowColor = color(0, 0, 0, 0.28)
    baseShadow.set()

    NSGradient(colorsAndLocations:
        (color(12, 17, 30), 0.0),
        (color(19, 28, 48), 0.38),
        (color(27, 79, 120), 1.0)
    )?.draw(in: basePath, angle: 90)

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    basePath.addClip()

    let glow = NSBezierPath(ovalIn: NSRect(x: size * 0.14, y: size * 0.52, width: size * 0.72, height: size * 0.42))
    NSGradient(colorsAndLocations:
        (color(71, 198, 255, 0.34), 0.0),
        (color(71, 198, 255, 0.0), 1.0)
    )?.draw(in: glow, relativeCenterPosition: .zero)

    let highlight = NSBezierPath(roundedRect: NSRect(x: size * 0.11, y: size * 0.59, width: size * 0.78, height: size * 0.21), xRadius: size * 0.1, yRadius: size * 0.1)
    color(255, 255, 255, 0.10).setFill()
    highlight.fill()

    let vignette = NSBezierPath(ovalIn: NSRect(x: size * 0.03, y: size * 0.02, width: size * 0.94, height: size * 0.94))
    NSGradient(colorsAndLocations:
        (color(0, 0, 0, 0.0), 0.0),
        (color(0, 0, 0, 0.0), 0.62),
        (color(0, 0, 0, 0.22), 1.0)
    )?.draw(in: vignette, relativeCenterPosition: .zero)

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    let barrelRect = NSRect(x: size * 0.25, y: size * 0.16, width: size * 0.5, height: size * 0.66)
    let barrel = barrelPath(in: barrelRect)

    let barrelShadow = NSShadow()
    barrelShadow.shadowOffset = NSSize(width: 0, height: -size * 0.02)
    barrelShadow.shadowBlurRadius = size * 0.05
    barrelShadow.shadowColor = color(0, 0, 0, 0.25)
    barrelShadow.set()

    NSGradient(colorsAndLocations:
        (color(255, 194, 84), 0.0),
        (color(242, 150, 54), 0.5),
        (color(181, 93, 27), 1.0)
    )?.draw(in: barrel, angle: 90)

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    barrel.addClip()

    for offset in [0.18, 0.33, 0.5, 0.67, 0.82] {
        let stave = NSBezierPath(roundedRect: NSRect(x: barrelRect.minX + barrelRect.width * offset - size * 0.012, y: barrelRect.minY + size * 0.03, width: size * 0.024, height: barrelRect.height - size * 0.06), xRadius: size * 0.012, yRadius: size * 0.012)
        color(255, 232, 170, 0.14).setFill()
        stave.fill()
    }

    let bandYs: [CGFloat] = [0.18, 0.47, 0.76]
    for bandY in bandYs {
        let bandRect = NSRect(x: barrelRect.minX - size * 0.02, y: barrelRect.minY + barrelRect.height * bandY - size * 0.035, width: barrelRect.width + size * 0.04, height: size * 0.07)
        let band = roundedRect(bandRect, radius: size * 0.03)
        NSGradient(colorsAndLocations:
            (color(114, 237, 255), 0.0),
            (color(62, 188, 238), 0.5),
            (color(24, 107, 176), 1.0)
        )?.draw(in: band, angle: 90)
        color(255, 255, 255, 0.20).setStroke()
        band.lineWidth = max(1, size * 0.006)
        band.stroke()
    }

    let topRim = NSBezierPath(ovalIn: NSRect(x: barrelRect.minX + size * 0.045, y: barrelRect.maxY - size * 0.052, width: barrelRect.width - size * 0.09, height: size * 0.072))
    color(255, 245, 214, 0.38).setFill()
    topRim.fill()

    let bottomRim = NSBezierPath(ovalIn: NSRect(x: barrelRect.minX + size * 0.05, y: barrelRect.minY - size * 0.02, width: barrelRect.width - size * 0.10, height: size * 0.07))
    color(92, 43, 9, 0.24).setFill()
    bottomRim.fill()

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    color(255, 244, 214, 0.98).setStroke()
    let monogram = NSBezierPath()
    monogram.lineWidth = size * 0.07
    monogram.lineCapStyle = .round
    monogram.lineJoinStyle = .round
    monogram.move(to: NSPoint(x: size * 0.41, y: size * 0.30))
    monogram.line(to: NSPoint(x: size * 0.41, y: size * 0.64))
    monogram.move(to: NSPoint(x: size * 0.43, y: size * 0.48))
    monogram.line(to: NSPoint(x: size * 0.58, y: size * 0.64))
    monogram.move(to: NSPoint(x: size * 0.43, y: size * 0.48))
    monogram.line(to: NSPoint(x: size * 0.60, y: size * 0.30))

    let monogramShadow = NSShadow()
    monogramShadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
    monogramShadow.shadowBlurRadius = size * 0.02
    monogramShadow.shadowColor = color(98, 44, 17, 0.35)
    monogramShadow.set()
    monogram.stroke()

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateKegIcon", code: 3)
    }
    try data.write(to: URL(fileURLWithPath: path))
}

func renderIconset(output: String) throws {
    let fileManager = FileManager.default
    let outputURL = URL(fileURLWithPath: output)
    let iconsetURL = outputURL.deletingPathExtension().appendingPathExtension("iconset")

    try? fileManager.removeItem(at: iconsetURL)
    try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: iconsetURL) }

    let entries: [(String, CGFloat)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    for (name, size) in entries {
        try drawIcon(size: size, to: iconsetURL.appendingPathComponent(name).path)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["--convert", "icns", "--output", outputURL.path, iconsetURL.path]
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw NSError(domain: "GenerateKegIcon", code: Int(process.terminationStatus))
    }
}

let arguments = CommandLine.arguments
let output = arguments.dropFirst().first ?? "Resources/Keg.icns"
try renderIconset(output: output)
print("Generated \(output)")
