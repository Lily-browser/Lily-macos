import AppKit

// The Lily app icon, drawn in code. Standalone on purpose (AppKit only, nothing from LilyCore):
// the app renders variants at runtime (Settings → Appearance → Icon), and scripts/bundle.sh
// compiles this same file to write the default AppIcon.icns, so there is one drawing.
// Follows the macOS icon grid: an 824pt rounded square centered on a 1024pt canvas.

/// The four icons to choose from. Each is a colour scheme of the same lily, with a lighter
/// rendering for the light appearance and a deeper one for dark.
enum AppIconVariant: String, CaseIterable, Sendable {
    case iris, rose, meadow, graphite

    var label: String { rawValue.capitalized }
}

enum AppIconArt {
    struct Palette: Sendable {
        /// Gradient from the top edge to the bottom edge, sRGB.
        let top: (r: CGFloat, g: CGFloat, b: CGFloat)
        let bottom: (r: CGFloat, g: CGFloat, b: CGFloat)
        /// Brightness of the petals (1 = white) and of the glow from above.
        let petal: CGFloat
        let glow: CGFloat
        /// A faint inner edge that keeps a dark tile readable on a dark Dock.
        let rim: CGFloat
    }

    static func palette(_ variant: AppIconVariant, dark: Bool) -> Palette {
        switch (variant, dark) {
        case (.iris, false): return Palette(top: (0.56, 0.60, 1.00), bottom: (0.27, 0.24, 0.86), petal: 1, glow: 0.22, rim: 0)
        case (.iris, true): return Palette(top: (0.31, 0.33, 0.66), bottom: (0.10, 0.09, 0.34), petal: 0.93, glow: 0.10, rim: 0.16)
        case (.rose, false): return Palette(top: (1.00, 0.64, 0.76), bottom: (0.86, 0.20, 0.46), petal: 1, glow: 0.22, rim: 0)
        case (.rose, true): return Palette(top: (0.56, 0.24, 0.38), bottom: (0.27, 0.07, 0.18), petal: 0.93, glow: 0.10, rim: 0.16)
        case (.meadow, false): return Palette(top: (0.56, 0.92, 0.68), bottom: (0.08, 0.56, 0.44), petal: 1, glow: 0.22, rim: 0)
        case (.meadow, true): return Palette(top: (0.18, 0.43, 0.34), bottom: (0.04, 0.19, 0.17), petal: 0.93, glow: 0.10, rim: 0.16)
        case (.graphite, false): return Palette(top: (0.80, 0.82, 0.86), bottom: (0.30, 0.32, 0.38), petal: 1, glow: 0.22, rim: 0)
        case (.graphite, true): return Palette(top: (0.24, 0.25, 0.29), bottom: (0.05, 0.05, 0.07), petal: 0.92, glow: 0.08, rim: 0.18)
        }
    }

    /// A PNG of the icon at `pixels` × `pixels`.
    static func png(pixels: Int, variant: AppIconVariant, dark: Bool) -> Data {
        let colors = palette(variant, dark: dark)
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
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(dark ? 0.5 : 0.3).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        // One calm hue, lighter at the top: a soft vertical gradient.
        let top = NSColor(srgbRed: colors.top.r, green: colors.top.g, blue: colors.top.b, alpha: 1).cgColor
        let bottom = NSColor(srgbRed: colors.bottom.r, green: colors.bottom.g, blue: colors.bottom.b, alpha: 1).cgColor
        let gradient = CGGradient(colorsSpace: srgb, colors: [top, bottom] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        // Faint glow from above, the way system icons catch light.
        let glow = CGGradient(colorsSpace: srgb, colors: [NSColor(white: 1, alpha: colors.glow).cgColor,
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
            ctx.setFillColor(NSColor(white: colors.petal, alpha: alpha).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.restoreGState()
        ctx.restoreGState()

        if colors.rim > 0 {
            ctx.saveGState()
            ctx.addPath(shape)
            ctx.setStrokeColor(NSColor(white: 1, alpha: colors.rim).cgColor)
            ctx.setLineWidth(4)
            ctx.strokePath()
            ctx.restoreGState()
        }

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    /// The icon as an image at its natural size of `points` (drawn at twice that for sharpness).
    @MainActor static func image(variant: AppIconVariant, dark: Bool, points: CGFloat = 128) -> NSImage {
        let image = NSImage(data: png(pixels: Int(points * 2), variant: variant, dark: dark)) ?? NSImage()
        image.size = NSSize(width: points, height: points)
        return image
    }
}
