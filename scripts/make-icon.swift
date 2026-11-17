// Renders the Lily app icon straight into an .icns.
// Usage: swift scripts/make-icon.swift <out.icns>
// One image per pixel size: iconutil would also store "128@2x" and "256@2x", byte-for-byte
// copies of the 256 and 512 px images (about 220 KB); macOS picks an icon image by pixel size.
// Follows the macOS icon grid: an 824pt rounded square centered on a 1024pt canvas.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <out.icns>\n".utf8))
    exit(64)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the tile, as on system icons.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    // One calm hue, lighter at the top: a soft vertical gradient.
    let top = NSColor(srgbRed: 0.56, green: 0.60, blue: 1.00, alpha: 1).cgColor
    let bottom = NSColor(srgbRed: 0.27, green: 0.24, blue: 0.86, alpha: 1).cgColor
    let gradient = CGGradient(colorsSpace: srgb, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Faint glow from above, the way system icons catch light.
    let glow = CGGradient(colorsSpace: srgb, colors: [NSColor(white: 1, alpha: 0.22).cgColor,
                                                      NSColor(white: 1, alpha: 0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 960), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 960), endRadius: 620, options: [])

    // The mark: a lily made of three pointed petals fanning out from one point.
    func petal(angle: CGFloat, length: CGFloat, width: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addCurve(to: CGPoint(x: 0, y: length), control1: CGPoint(x: width * 1.25, y: length * 0.28),
                      control2: CGPoint(x: width * 0.7, y: length * 0.78))
        path.addCurve(to: .zero, control1: CGPoint(x: -width * 0.7, y: length * 0.78),
                      control2: CGPoint(x: -width * 1.25, y: length * 0.28))
        path.closeSubpath()
        return path.copy(using: [CGAffineTransform(rotationAngle: -angle)])!
    }
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 262)
    for (angle, length, alpha, width) in [(CGFloat.pi * 0.21, CGFloat(420), CGFloat(0.70), CGFloat(112)),
                                   (-CGFloat.pi * 0.21, CGFloat(420), CGFloat(0.70), CGFloat(112)),
                                   (0, CGFloat(500), CGFloat(1), CGFloat(132))] {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: NSColor.black.withAlphaComponent(0.16).cgColor)
        ctx.addPath(petal(angle: angle, length: length, width: width))
        ctx.setFillColor(NSColor(white: 1, alpha: alpha).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.restoreGState()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// icns: "icns", total length, then (type, length including its 8-byte header, PNG) chunks, all
// lengths big-endian.
func bigEndian(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).bigEndian) { Data($0) } }
let chunks: [(type: String, pixels: Int)] = [("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64),
                                             ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)]
var body = Data()
for chunk in chunks {
    let png = render(pixels: chunk.pixels)
    body += Data(chunk.type.utf8) + bigEndian(png.count + 8) + png
}
try (Data("icns".utf8) + bigEndian(body.count + 8) + body).write(to: out)
