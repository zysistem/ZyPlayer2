import AppKit
import Foundation

/// Renders the ZyPlayer app icon: a rounded-square gradient tile with a "Zy"
/// wordmark and a play triangle. Run with `swift Scripts/make-icon.swift`.
///
/// Output: build/AppIcon.iconset + Sources/ZyPlayer/Resources/AppIcon.icns

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // macOS icons sit inside the canvas with a margin.
    let inset = size * 0.055
    let tile = rect.insetBy(dx: inset, dy: inset)
    let corner = tile.width * 0.2237          // Apple's squircle-ish radius
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner,
                          cornerHeight: corner, transform: nil)

    // Background: deep indigo → violet, lit from the top-left.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let colors = [
        NSColor(srgbRed: 0.36, green: 0.31, blue: 0.95, alpha: 1).cgColor,
        NSColor(srgbRed: 0.55, green: 0.24, blue: 0.86, alpha: 1).cgColor,
        NSColor(srgbRed: 0.24, green: 0.13, blue: 0.42, alpha: 1).cgColor
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 0.55, 1]) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: tile.minX, y: tile.maxY),
            end: CGPoint(x: tile.maxX, y: tile.minY),
            options: []
        )
    }

    // Soft highlight arc across the upper half.
    context.setBlendMode(.softLight)
    context.setFillColor(NSColor.white.withAlphaComponent(0.5).cgColor)
    context.fillEllipse(in: CGRect(
        x: tile.minX - tile.width * 0.25,
        y: tile.midY,
        width: tile.width * 1.2,
        height: tile.height * 0.95
    ))
    context.setBlendMode(.normal)
    context.restoreGState()

    // Solid play triangle above the wordmark. A filled shape stays legible at
    // 16pt, where an outline turns to mush.
    let playSize = tile.width * 0.26
    let playCenter = CGPoint(x: tile.midX, y: tile.midY + tile.height * 0.16)
    let h = playSize * 0.5
    // NSBezierPath rather than CGContext: filling a CGPath inside `lockFocus`
    // silently no-ops here, leaving a hollow outline.
    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: playCenter.x - h * 0.70, y: playCenter.y + h))
    triangle.line(to: NSPoint(x: playCenter.x + h * 0.95, y: playCenter.y))
    triangle.line(to: NSPoint(x: playCenter.x - h * 0.70, y: playCenter.y - h))
    triangle.close()
    triangle.lineWidth = playSize * 0.20
    triangle.lineJoinStyle = .round
    triangle.lineCapStyle = .round

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.006),
                      blur: size * 0.03,
                      color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.white.setFill()
    NSColor.white.setStroke()
    triangle.fill()
    triangle.stroke()
    context.restoreGState()

    // "Zy" wordmark under the triangle.
    let fontSize = tile.width * 0.31
    let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
        .kern: -fontSize * 0.03
    ]
    let text = NSAttributedString(string: "Zy", attributes: attributes)
    let textSize = text.size()
    let textOrigin = CGPoint(
        x: tile.midX - textSize.width / 2,
        y: tile.midY - tile.height * 0.32
    )
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.004),
                      blur: size * 0.025,
                      color: NSColor.black.withAlphaComponent(0.3).cgColor)
    text.draw(at: textOrigin)
    context.restoreGState()

    image.unlockFocus()
    return image
}

func png(from image: NSImage, pixels: Int) -> Data? {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Emit the iconset

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for variant in variants {
    let image = drawIcon(size: CGFloat(variant.pixels))
    guard let data = png(from: image, pixels: variant.pixels) else { continue }
    try data.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

print("iconset yazıldı: \(iconset.path)")
