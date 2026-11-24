import AppKit

/// Renders the sidebar and checks the active tab is drawn as one pill: the list's own selection pill and Lily's accent
/// fill must have the same shape, or a strip of the second colour shows at the edge (#173). Compares the pill's colour
/// at its left edge with the colour a little further in.
@MainActor
enum PillProbe {
    static func run(window: BrowserWindowController) async -> (ok: Bool, detail: JSONValue) {
        window.window?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(600))
        guard let content = window.window?.contentView, let table = DragHarness.list(in: content),
              let index = window.model.regularItems.firstIndex(where: { if case .tab(let t) = $0 { return t.id == window.model.activeID } else { return false } }),
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return (true, "skipped: nothing to render") }
        let row = table.numberOfRows - window.model.regularItems.count - 1 + index
        guard row >= 0, row < table.numberOfRows else { return (true, "skipped: row not found") }
        content.cacheDisplay(in: content.bounds, to: rep)
        let frame = content.convert(table.convert(table.rect(ofRow: row), to: nil), from: nil)
        let scale = Double(rep.pixelsWide) / content.bounds.width
        let y = Int((content.isFlipped ? frame.midY : content.bounds.height - frame.midY) * scale)
        func color(_ x: Int) -> [Int] {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return [0, 0, 0] }
            return [Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255)]
        }
        func differ(_ a: [Int], _ b: [Int], by limit: Int) -> Bool { zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } > limit }
        let start = Int(frame.minX * scale) + 2
        let background = color(start)
        guard let edge = (start..<start + Int(40 * scale)).first(where: { differ(color($0), background, by: 14) }) else { return (true, "skipped: no pill drawn") }
        let atEdge = color(edge + 3), inside = color(edge + 9) // both in the padding before the favicon
        let uniform = !differ(atEdge, inside, by: 8)
        return (uniform, ["edgePx": .number(Double(edge)), "atEdge": .string("\(atEdge)"), "inside": .string("\(inside)")])
    }
}
