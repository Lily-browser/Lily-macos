import AppKit

/// A page snapshot framed for sharing: rounded corners and a soft shadow on a gradient, like Arc's Portrait mode.
/// Pure drawing; the caller decides which pages may be captured (never private windows or sensitive sites).
enum Portrait {
    static let margin: CGFloat = 56
    static let cornerRadius: CGFloat = 12

    /// The framed image: the page with `margin` on every side.
    static func image(of page: NSImage) -> NSImage {
        let size = NSSize(width: page.size.width + margin * 2, height: page.size.height + margin * 2)
        return NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.43, green: 0.36, blue: 0.93, alpha: 1), NSColor(red: 0.93, green: 0.45, blue: 0.62, alpha: 1)])?
                .draw(in: rect, angle: -40)
            let pageRect = NSRect(x: margin, y: margin, width: page.size.width, height: page.size.height)
            let path = NSBezierPath(roundedRect: pageRect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 28
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            NSColor.white.setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            page.draw(in: pageRect)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    /// PNG bytes of `image`, for the pasteboard.
    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
