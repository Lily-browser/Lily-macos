import AppKit

/// Navigating a tab to an address that imitates another site asks first, before any request: the sheet shows even though
/// the domain doesn't exist, and "Go Back" cancels the load. (Typed addresses once skipped the warning because the guard
/// compared the target with the tab's own URL, which already is the target; the unit tests couldn't see that.)
@MainActor
enum LookalikeProbe {
    static func run(window: BrowserWindowController) async -> (ok: Bool, detail: JSONValue) {
        window.window?.makeKeyAndOrderFront(nil)
        let tab = window.tabs.create(url: nil)
        tab.load(URL(string: "https://xn--pple-43d.com/")!)
        var sheet: NSWindow?
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            if let found = window.window?.attachedSheet { sheet = found; break }
        }
        var texts: [String] = []
        func collect(_ view: NSView) { if let field = view as? NSTextField { texts.append(field.stringValue) }; view.subviews.forEach(collect) }
        if let content = sheet?.contentView { collect(content) }
        let shown = sheet != nil
        let explains = texts.contains { $0.contains("imitating another site") } && texts.contains { $0.contains("xn--pple-43d.com") }
        // Go Back: the navigation is cancelled and the tab never loads the address.
        if let sheet { window.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        try? await Task.sleep(for: .milliseconds(600))
        let cancelled = tab.title != "Can't open this page"
        window.tabs.close(tab.id)
        return (shown && explains && cancelled, ["sheetShown": .bool(shown), "explains": .bool(explains), "goBackCancelsTheLoad": .bool(cancelled)])
    }
}
