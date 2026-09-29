// Draws the Awake app icon into an .iconset folder (one PNG per required size).
// Usage: make-icon <output.iconset>
// build.sh compiles and runs this, then calls `iconutil -c icns`.

import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <output.iconset>\n".utf8))
    exit(2)
}
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// A white version of an SF Symbol.
func whiteSymbol(named name: String, pointSize: CGFloat) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) else { return nil }
    return NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceIn)
        return true
    }
}

/// Renders the icon at an exact pixel size.
func renderIcon(pixels: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    bitmap.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.current = context

    let size = CGFloat(pixels)
    // macOS icon grid: the rounded square fills 824 of 1024 units.
    let inset = size * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2237, yRadius: tile.width * 0.2237)

    // Soft drop shadow under the tile.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.shadowBlurRadius = size * 0.03
    shadow.set()
    NSColor.black.setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Warm amber-to-orange gradient, light at the top.
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 1.00, green: 0.74, blue: 0.28, alpha: 1),
        ending: NSColor(calibratedRed: 0.95, green: 0.42, blue: 0.16, alpha: 1)
    )
    gradient?.draw(in: tilePath, angle: -90)

    // Cup and saucer, centred and slightly above centre for optical balance.
    if let symbol = whiteSymbol(named: "cup.and.saucer.fill", pointSize: size * 0.5) {
        let target = tile.width * 0.62
        let scale = target / max(symbol.size.width, symbol.size.height)
        let drawSize = NSSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let origin = NSPoint(
            x: tile.midX - drawSize.width / 2,
            y: tile.midY - drawSize.height / 2 + size * 0.008
        )
        NSGraphicsContext.saveGraphicsState()
        let symbolShadow = NSShadow()
        symbolShadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        symbolShadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
        symbolShadow.shadowBlurRadius = size * 0.015
        symbolShadow.set()
        symbol.draw(in: NSRect(origin: origin, size: drawSize))
        NSGraphicsContext.restoreGraphicsState()
    }

    return bitmap.representation(using: .png, properties: [:])
}

// (point size, scale) pairs an .iconset needs.
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

for variant in variants {
    let pixels = variant.points * variant.scale
    guard let png = renderIcon(pixels: pixels) else {
        FileHandle.standardError.write(Data("could not render \(pixels)px\n".utf8))
        exit(1)
    }
    let suffix = variant.scale == 2 ? "@2x" : ""
    try png.write(to: outputDirectory.appendingPathComponent("icon_\(variant.points)x\(variant.points)\(suffix).png"))
}
