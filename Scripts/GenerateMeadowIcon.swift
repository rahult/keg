import AppKit
import Foundation

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

/// Draws a tapered blade-of-grass shape from `base` to `tip`.
///
/// Control points bulge perpendicular to the blade's spine so leaning blades
/// still taper naturally — without this, a non-vertical blade drawn with
/// vertical control points looks like a banana.
func bladePath(
    baseX: CGFloat, baseY: CGFloat,
    tipX: CGFloat, tipY: CGFloat,
    baseWidth: CGFloat,
    bulge: CGFloat = 0.18
) -> NSBezierPath {
    let halfW = baseWidth / 2
    let dx = tipX - baseX
    let dy = tipY - baseY
    let length = max(sqrt(dx * dx + dy * dy), 0.0001)
    let nx = -dy / length  // perpendicular, rotated +90°
    let ny = dx / length
    let mx = (baseX + tipX) / 2
    let my = (baseY + tipY) / 2
    let out = halfW + bulge * length

    let baseLeft = NSPoint(x: baseX + nx * halfW, y: baseY + ny * halfW)
    let baseRight = NSPoint(x: baseX - nx * halfW, y: baseY - ny * halfW)
    let tip = NSPoint(x: tipX, y: tipY)
    let leftBulge = NSPoint(x: mx + nx * out, y: my + ny * out)
    let rightBulge = NSPoint(x: mx - nx * out, y: my - ny * out)
    let nearTipLeft = NSPoint(x: leftBulge.x * 0.35 + tipX * 0.65,
                              y: leftBulge.y * 0.35 + tipY * 0.65)
    let nearTipRight = NSPoint(x: rightBulge.x * 0.35 + tipX * 0.65,
                               y: rightBulge.y * 0.35 + tipY * 0.65)

    let path = NSBezierPath()
    path.move(to: baseLeft)
    path.curve(to: tip, controlPoint1: leftBulge, controlPoint2: nearTipLeft)
    path.curve(to: baseRight, controlPoint1: nearTipRight, controlPoint2: rightBulge)
    path.close()
    return path
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateMeadowIcon", code: 1)
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
        throw NSError(domain: "GenerateMeadowIcon", code: 2)
    }

    rep.size = NSSize(width: size, height: size)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "GenerateMeadowIcon", code: 3)
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

    // Rounded-square tile, brand dark palette (matches site --bg / --bg-inner).
    let tileRect = canvas.insetBy(dx: size * 0.06, dy: size * 0.06)
    let tile = roundedRect(tileRect, radius: size * 0.23)

    let tileShadow = NSShadow()
    tileShadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    tileShadow.shadowBlurRadius = size * 0.045
    tileShadow.shadowColor = color(0, 0, 0, 0.32)
    tileShadow.set()

    NSGradient(colorsAndLocations:
        (color(18, 20, 28), 0.0),  // top: #12141c (slightly lifted)
        (color(8, 8, 12), 0.55),
        (color(4, 4, 6), 1.0)      // bottom: near-black
    )?.draw(in: tile, angle: -90)

    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context

    // Everything from here in is clipped to the tile (glow + blades).
    tile.addClip()

    // Soft accent-green radial glow anchored to the "ground" line.
    let glowCenter = NSPoint(
        x: tileRect.midX,
        y: tileRect.minY + tileRect.height * 0.22
    )
    NSGradient(colorsAndLocations:
        (color(0, 224, 136, 0.38), 0.0),
        (color(0, 224, 136, 0.10), 0.45),
        (color(0, 224, 136, 0.00), 1.0)
    )?.draw(
        fromCenter: glowCenter, radius: 0,
        toCenter: glowCenter, radius: tileRect.width * 0.55,
        options: []
    )

    // Faint horizon line where blades emerge.
    let horizonY = tileRect.minY + tileRect.height * 0.22
    let horizon = NSBezierPath()
    horizon.move(to: NSPoint(x: tileRect.minX + tileRect.width * 0.18, y: horizonY))
    horizon.line(to: NSPoint(x: tileRect.maxX - tileRect.width * 0.18, y: horizonY))
    color(0, 224, 136, 0.22).setStroke()
    horizon.lineWidth = max(0.6, size * 0.003)
    horizon.stroke()

    // Three blades — base coordinates are fractions of the tile rect so the
    // composition stays identical at every render size.
    let bx = tileRect.minX
    let by = tileRect.minY
    let sz = tileRect.width

    // TUNABLE — blade geometry. Adjust tipX/tipY for lean, baseWidth for heft.
    let leftBlade = bladePath(
        baseX: bx + sz * 0.36, baseY: by + sz * 0.22,
        tipX:  bx + sz * 0.26, tipY:  by + sz * 0.62,
        baseWidth: sz * 0.075
    )
    let midBlade = bladePath(
        baseX: bx + sz * 0.50, baseY: by + sz * 0.20,
        tipX:  bx + sz * 0.505, tipY: by + sz * 0.86,
        baseWidth: sz * 0.085
    )
    let rightBlade = bladePath(
        baseX: bx + sz * 0.64, baseY: by + sz * 0.22,
        tipX:  bx + sz * 0.74, tipY:  by + sz * 0.68,
        baseWidth: sz * 0.075
    )

    // Side blades: darker, desaturated — they frame the middle blade.
    let sideGradient = NSGradient(colorsAndLocations:
        (color(10, 58, 40), 0.0),
        (color(28, 110, 78), 0.55),
        (color(52, 162, 116), 1.0)
    )
    sideGradient?.draw(in: leftBlade, angle: 96)
    sideGradient?.draw(in: rightBlade, angle: 84)

    // Middle blade: full-strength brand accent, brighter at tip.
    NSGradient(colorsAndLocations:
        (color(0, 130, 80), 0.0),
        (color(0, 224, 136), 0.55),
        (color(120, 255, 198), 1.0)
    )?.draw(in: midBlade, angle: 90)

    // Hairline highlight on middle blade edge — only shows at larger sizes.
    color(200, 255, 224, 0.45).setStroke()
    midBlade.lineWidth = max(0.5, size * 0.0028)
    midBlade.stroke()

    NSGraphicsContext.restoreGraphicsState()

    // Inner tile edge — thin bright rim for depth.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    color(255, 255, 255, 0.09).setStroke()
    tile.lineWidth = max(1, size * 0.006)
    tile.stroke()
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

    // Template images are pure alpha — macOS tints them for light/dark menus,
    // so we fill black on clear and let the system handle appearance.
    NSColor.black.setFill()

    // Blades scaled to fill the menu-bar canvas. Slightly heftier widths
    // than the app-icon version so strokes survive at 16–18px menu heights.
    let left = bladePath(
        baseX: size * 0.30, baseY: size * 0.14,
        tipX:  size * 0.20, tipY:  size * 0.58,
        baseWidth: size * 0.11
    )
    let mid = bladePath(
        baseX: size * 0.50, baseY: size * 0.12,
        tipX:  size * 0.505, tipY: size * 0.84,
        baseWidth: size * 0.12
    )
    let right = bladePath(
        baseX: size * 0.70, baseY: size * 0.14,
        tipX:  size * 0.80, tipY:  size * 0.64,
        baseWidth: size * 0.11
    )

    left.fill()
    mid.fill()
    right.fill()

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
        throw NSError(domain: "GenerateMeadowIcon", code: Int(process.terminationStatus))
    }
}

let arguments = CommandLine.arguments
let iconOutput = arguments.dropFirst().first ?? "Resources/Meadow.icns"
let menuBarOutput = arguments.dropFirst().dropFirst().first ?? "Resources/MeadowMenuBarTemplate.png"
try renderIconset(output: iconOutput)
try drawMenuBarTemplate(size: 32, to: menuBarOutput)
print("Generated \(iconOutput)")
print("Generated \(menuBarOutput)")
