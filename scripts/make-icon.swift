// Dessine l'icône de Lumio et produit Resources/AppIcon.icns.
// Usage : swift scripts/make-icon.swift   (depuis la racine du projet)
import AppKit

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)

    NSGradient(colors: [
        NSColor(red: 0.13, green: 0.11, blue: 0.13, alpha: 1),
        NSColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1),
    ])!.draw(in: shape, angle: -90)

    // Halo chaud derrière le symbole.
    shape.addClip()
    NSGradient(colors: [
        NSColor(red: 1, green: 0.33, blue: 0.22, alpha: 0.55),
        NSColor(red: 1, green: 0.33, blue: 0.22, alpha: 0),
    ])!.draw(in: tile.insetBy(dx: -s * 0.1, dy: -s * 0.1), relativeCenterPosition: NSPoint(x: 0, y: -0.25))

    // Triangle de lecture arrondi.
    let c = NSPoint(x: s * 0.52, y: s * 0.5)
    let r = s * 0.2
    let triangle = NSBezierPath()
    triangle.move(to: NSPoint(x: c.x - r * 0.75, y: c.y + r))
    triangle.line(to: NSPoint(x: c.x + r, y: c.y))
    triangle.line(to: NSPoint(x: c.x - r * 0.75, y: c.y - r))
    triangle.close()
    triangle.lineJoinStyle = .round
    triangle.lineWidth = s * 0.06
    NSColor(red: 1, green: 0.36, blue: 0.24, alpha: 1).set()
    triangle.fill()
    triangle.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
print("Resources/AppIcon.icns")
