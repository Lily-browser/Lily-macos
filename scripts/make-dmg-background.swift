// Renders the DMG window background (660x400 pt) as <out>.png (1x) and <out>@2x.png (Retina); the
// caller combines them with tiffutil so Finder picks the right one.
// Usage: swift scripts/make-dmg-background.swift <out-without-extension>
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <out-base>\n".utf8))
    exit(64)
}
let size = CGSize(width: 660, height: 400)
func render(scale: Int, to path: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: srgb, colors: [NSColor(srgbRed: 0.97, green: 0.97, blue: 1.0, alpha: 1).cgColor,
                                                          NSColor(srgbRed: 0.90, green: 0.91, blue: 0.98, alpha: 1).cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])

    // Icons sit at y = 190 from the top (Finder coordinates), so y = 210 here; the arrow joins them.
    let accent = NSColor(srgbRed: 0.36, green: 0.34, blue: 0.92, alpha: 0.55).cgColor
    ctx.setStrokeColor(accent)
    ctx.setLineWidth(5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 268, y: 210))
    ctx.addLine(to: CGPoint(x: 392, y: 210))
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 372, y: 230))
    ctx.addLine(to: CGPoint(x: 394, y: 210))
    ctx.addLine(to: CGPoint(x: 372, y: 190))
    ctx.strokePath()

    let text = "Drag Lily to the Applications folder" as NSString
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium),
                                                .foregroundColor: NSColor(srgbRed: 0.30, green: 0.31, blue: 0.45, alpha: 0.85)]
    let textSize = text.size(withAttributes: attrs)
    text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: 60), withAttributes: attrs)

    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
try render(scale: 1, to: CommandLine.arguments[1] + ".png")
try render(scale: 2, to: CommandLine.arguments[1] + "@2x.png")
