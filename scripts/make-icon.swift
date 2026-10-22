// Draws the MySheets icon (a green spreadsheet with a highlighted row) and writes Resources/AppIcon.icns.
// Run: swift scripts/make-icon.swift
import AppKit

func draw(_ s: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.09
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = tile.width * 0.22
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.015)
    shadow.shadowBlurRadius = s * 0.03
    shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    shadow.set()
    NSColor(srgbRed: 16 / 255, green: 124 / 255, blue: 65 / 255, alpha: 1).setFill()
    NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    // The sheet.
    let sheet = tile.insetBy(dx: tile.width * 0.16, dy: tile.height * 0.18)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: sheet, xRadius: s * 0.02, yRadius: s * 0.02).fill()
    let rows = 5, cols = 3
    let rh = sheet.height / CGFloat(rows), cw = sheet.width / CGFloat(cols)
    // A highlighted row, as if filled yellow.
    NSColor(srgbRed: 1, green: 0.85, blue: 0.1, alpha: 1).setFill()
    NSRect(x: sheet.minX, y: sheet.maxY - rh * 3, width: sheet.width, height: rh).fill()
    // Header row.
    NSColor(srgbRed: 0.8, green: 0.91, blue: 0.84, alpha: 1).setFill()
    NSRect(x: sheet.minX, y: sheet.maxY - rh, width: sheet.width, height: rh).fill()
    NSColor(srgbRed: 0.05, green: 0.35, blue: 0.18, alpha: 1).setFill()
    let line = max(1, s * 0.012)
    for i in 1..<rows { NSRect(x: sheet.minX, y: sheet.minY + CGFloat(i) * rh - line / 2, width: sheet.width, height: line).fill() }
    for j in 1..<cols { NSRect(x: sheet.minX + CGFloat(j) * cw - line / 2, y: sheet.minY, width: line, height: sheet.height).fill() }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(CGFloat(base * scale)).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
