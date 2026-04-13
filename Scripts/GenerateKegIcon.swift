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
    let rimInset = w * 0.14
    let belly = w * 0.045

    let path = NSBezierPath()
    path.move(to: NSPoint(x: x + rimInset, y: y + h))
    path.curve(
        to: NSPoint(x: x + w - rimInset, y: y + h),
        controlPoint1: NSPoint(x: x + w * 0.30, y: y + h + h * 0.07),
        controlPoint2: NSPoint(x: x + w * 0.70, y: y + h + h * 0.07)
    )
    path.curve(
        to: NSPoint(x: x + w - belly, y: y + h * 0.18),
        controlPoint1: NSPoint(x: x + w * 0.98, y: y + h * 0.90),
        controlPoint2: NSPoint(x: x + w * 1.00, y: y + h * 0.42)
    )
    path.curve(
        to: NSPoint(x: x + w - rimInset, y: y),
        controlPoint1: NSPoint(x: x + w * 0.98, y: y + h * 0.08),
        controlPoint2: NSPoint(x: x + w * 0.92, y: y - h * 0.06)
    )
    path.curve(
        to: NSPoint(x: x + rimInset, y: y),
        controlPoint1: NSPoint(x: x + w * 0.70, y: y - h * 0.07),
        controlPoint2: NSPoint(x: x + w * 0.30, y: y - h * 0.07)
    )
    path.curve(
        to: NSPoint(x: x + belly, y: y + h * 0.18),
        controlPoint1: NSPoint(x: x + w * 0.08, y: y - h * 0.06),
        controlPoint2: NSPoint(x: x + w * 0.02, y: y + h * 0.08)
    )
    path.curve(
        to: NSPoint(x: x + rimInset, y: y + h),
        controlPoint1: NSPoint(x: x, y: y + h * 0.42),
        controlPoint2: NSPoint(x: x + w * 0.02, y: y + h * 0.90)
    )
    path.close()
    return path
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateKegIcon", code: 1)
    }
    try data.write(to: URL(fileURLWithPath: path))
}

func makeBitmap(size: CGFloat) throws -> (NSBitmapImageRep, NSGraphicsContext) {
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
        throw NSError(domain: "GenerateKegIcon", code: 2)
    }

    rep.size = NSSize(width: size, height: size)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "GenerateKegIcon", code: 3)
    }

    context.cgContext.interpolationQuality = .high
    context.shouldAntialias = true
    return (rep, context)
}

func drawIcon(size: CGFloat, to path: String) throws {
    let (rep, context) = try makeBitmap(size: size)
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    canvas.fill()

    let baseRect = canvas.insetBy(dx: size * 0.06, dy: size * 0.06)
    let base = roundedRect(baseRect, radius: size * 0.23)

    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.shadowBlurRadius = size * 0.04
    shadow.shadowColor = color(0, 0, 0, 0.18)
    shadow.set()

    NSGradient(colorsAndLocations:
        (color(246, 248, 252), 0.0),
        (color(225, 232, 241), 0.18),
        (color(156, 174, 197), 1.0)
    )?.draw(in: base, angle: 90)

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    color(255, 255, 255, 0.46).setStroke()
    base.lineWidth = max(1, size * 0.008)
    base.stroke()

    let topWash = NSBezierPath(roundedRect: NSRect(x: size * 0.14, y: size * 0.60, width: size * 0.72, height: size * 0.16), xRadius: size * 0.08, yRadius: size * 0.08)
    color(255, 255, 255, 0.18).setFill()
    topWash.fill()

    let kegRect = NSRect(x: size * 0.305, y: size * 0.165, width: size * 0.39, height: size * 0.63)
    let keg = barrelPath(in: kegRect)

    let kegShadow = NSShadow()
    kegShadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    kegShadow.shadowBlurRadius = size * 0.03
    kegShadow.shadowColor = color(0, 0, 0, 0.16)
    kegShadow.set()

    NSGradient(colorsAndLocations:
        (color(252, 253, 255), 0.0),
        (color(219, 225, 235), 0.20),
        (color(168, 177, 191), 0.50),
        (color(235, 239, 246), 0.78),
        (color(176, 184, 196), 1.0)
    )?.draw(in: keg, angle: 0)

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    color(255, 255, 255, 0.32).setStroke()
    keg.lineWidth = max(1, size * 0.004)
    keg.stroke()

    keg.addClip()

    let leftHighlight = NSBezierPath(roundedRect: NSRect(x: kegRect.minX + size * 0.02, y: kegRect.minY + size * 0.05, width: size * 0.022, height: kegRect.height - size * 0.10), xRadius: size * 0.011, yRadius: size * 0.011)
    color(255, 255, 255, 0.34).setFill()
    leftHighlight.fill()

    let rightShade = NSBezierPath(roundedRect: NSRect(x: kegRect.maxX - size * 0.036, y: kegRect.minY + size * 0.05, width: size * 0.024, height: kegRect.height - size * 0.10), xRadius: size * 0.012, yRadius: size * 0.012)
    color(37, 51, 69, 0.10).setFill()
    rightShade.fill()

    let bandColorTop = color(41, 59, 82)
    let bandColorBottom = color(73, 97, 127)
    for bandY in [0.30, 0.70] as [CGFloat] {
        let band = roundedRect(
            NSRect(
                x: kegRect.minX - size * 0.008,
                y: kegRect.minY + kegRect.height * bandY - size * 0.024,
                width: kegRect.width + size * 0.016,
                height: size * 0.048
            ),
            radius: size * 0.024
        )
        NSGradient(colorsAndLocations:
            (bandColorTop, 0.0),
            (bandColorBottom, 1.0)
        )?.draw(in: band, angle: 90)
    }

    let badgeRect = NSRect(x: size * 0.435, y: size * 0.405, width: size * 0.13, height: size * 0.16)
    let badge = roundedRect(badgeRect, radius: size * 0.032)
    NSGradient(colorsAndLocations:
        (color(37, 55, 79), 0.0),
        (color(28, 43, 64), 1.0)
    )?.draw(in: badge, angle: 90)
    color(255, 255, 255, 0.14).setStroke()
    badge.lineWidth = max(1, size * 0.0035)
    badge.stroke()

    color(198, 221, 242, 0.92).setStroke()
    let door = NSBezierPath()
    door.lineCapStyle = .round
    door.lineWidth = max(1.4, size * 0.010)
    for xOffset in [0.28, 0.5, 0.72] as [CGFloat] {
        door.move(to: NSPoint(x: badgeRect.minX + badgeRect.width * xOffset, y: badgeRect.minY + badgeRect.height * 0.20))
        door.line(to: NSPoint(x: badgeRect.minX + badgeRect.width * xOffset, y: badgeRect.maxY - badgeRect.height * 0.20))
    }
    door.move(to: NSPoint(x: badgeRect.minX + badgeRect.width * 0.18, y: badgeRect.midY))
    door.line(to: NSPoint(x: badgeRect.maxX - badgeRect.width * 0.18, y: badgeRect.midY))
    door.stroke()

    let topRim = NSBezierPath(ovalIn: NSRect(x: kegRect.minX + size * 0.035, y: kegRect.maxY - size * 0.044, width: kegRect.width - size * 0.07, height: size * 0.058))
    color(255, 255, 255, 0.42).setFill()
    topRim.fill()

    let bottomRim = NSBezierPath(ovalIn: NSRect(x: kegRect.minX + size * 0.035, y: kegRect.minY - size * 0.018, width: kegRect.width - size * 0.07, height: size * 0.060))
    color(80, 95, 116, 0.16).setFill()
    bottomRim.fill()

    NSGraphicsContext.restoreGraphicsState()

    try writePNG(rep, to: path)
}

func drawMenuBarTemplate(size: CGFloat, to path: String) throws {
    let (rep, context) = try makeBitmap(size: size)
    let canvas = NSRect(x: 0, y: 0, width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    canvas.fill()

    let kegRect = NSRect(x: size * 0.24, y: size * 0.12, width: size * 0.52, height: size * 0.76)
    let keg = barrelPath(in: kegRect)
    NSColor.black.setFill()
    keg.fill()

    for bandY in [0.30, 0.70] as [CGFloat] {
        let band = roundedRect(
            NSRect(
                x: kegRect.minX - size * 0.008,
                y: kegRect.minY + kegRect.height * bandY - size * 0.030,
                width: kegRect.width + size * 0.016,
                height: size * 0.060
            ),
            radius: size * 0.02
        )
        NSGraphicsContext.saveGraphicsState()
        band.addClip()
        NSGraphicsContext.current?.compositingOperation = .clear
        NSColor.clear.setFill()
        canvas.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    try writePNG(rep, to: path)
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
let iconOutput = arguments.dropFirst().first ?? "Resources/Keg.icns"
let menuBarOutput = arguments.dropFirst().dropFirst().first ?? "Resources/KegMenuBarTemplate.png"
try renderIconset(output: iconOutput)
try drawMenuBarTemplate(size: 32, to: menuBarOutput)
print("Generated \(iconOutput)")
print("Generated \(menuBarOutput)")
