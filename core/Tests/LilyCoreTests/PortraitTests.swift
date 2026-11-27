import AppKit
import Testing
@testable import LilyCore

@MainActor struct PortraitTests {
    private func page() -> NSImage {
        let image = NSImage(size: NSSize(width: 200, height: 120))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 200, height: 120).fill(); image.unlockFocus()
        return image
    }

    @Test func theFrameAddsAMarginAroundThePage() throws {
        let framed = Portrait.image(of: page())
        #expect(framed.size == NSSize(width: 200 + Portrait.margin * 2, height: 120 + Portrait.margin * 2))
        let png = try #require(Portrait.png(framed))
        let rep = try #require(NSBitmapImageRep(data: png))
        let centre = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        #expect(centre.redComponent > 0.9 && centre.greenComponent < 0.2) // the page
        let corner = try #require(rep.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
        #expect(corner.alphaComponent > 0.99 && !(corner.redComponent > 0.9 && corner.greenComponent < 0.2)) // the backdrop, opaque
    }
}
