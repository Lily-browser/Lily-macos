import AppKit

/// Navigating a tab to an address that imitates another site asks first, before any request: the sheet shows even though
/// the domain doesn't exist, Escape and Return both press Cancel (which stops the load), and a tab nobody is looking at gets
/// a toast with "Review" instead of failing silently. (Typed addresses once skipped the warning because a guard compared
/// the target with the tab's own URL, which already is the target; and a custom Escape key equivalent once took the default
/// away from the first button so Return did nothing. The unit tests couldn't see either.)
@MainActor
enum LookalikeProbe {
    private static let address = "https://xn--pple-43d.com/"

    static func run(window: BrowserWindowController) async -> (ok: Bool, detail: JSONValue) {
        window.window?.makeKeyAndOrderFront(nil)
        let tab = window.tabs.create(url: nil)
        tab.load(URL(string: address)!)
        let sheet = await waitForSheet(window)
        var texts: [String] = []
        func collect(_ view: NSView) { if let field = view as? NSTextField { texts.append(field.stringValue) }; view.subviews.forEach(collect) }
        if let content = sheet?.contentView { collect(content) }
        let shown = sheet != nil
        let explains = texts.contains { $0.contains("imitating another site") } && texts.contains { $0.contains("xn--pple-43d.com") }

        // Escape and Return each press Cancel: sent as real key events, each must dismiss the sheet.
        var escapeCancels = false, returnCancels = false
        if let sheet { escapeCancels = await press(53, "\u{1b}", on: sheet, window) }
        try? await Task.sleep(for: .milliseconds(300))
        tab.load(URL(string: address + "login")!)
        if let second = await waitForSheet(window) { returnCancels = await press(36, "\r", on: second, window) }
        try? await Task.sleep(for: .milliseconds(600))
        let cancelled = tab.title != "Can't open this page"
        window.tabs.close(tab.id)

        // A tab nobody is looking at has no window to ask in: the load is stopped with a toast that offers to open it.
        let background = window.tabs.create(url: nil, activate: false)
        background.load(URL(string: address)!)
        var toast: WindowModel.Toast?
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            if let found = window.model.toast { toast = found; break }
        }
        let toasted = toast?.message.contains("may imitate another site") == true && toast?.action?.title == "Review"
        let stopped = background.title != "Can't open this page"
        // Review: the tab is shown and the full sheet asks; Return cancels it, so the address still never loads.
        toast?.action?.run()
        var reviewAsks = false, reviewCancels = false
        if let review = await waitForSheet(window) { reviewAsks = true; reviewCancels = await press(36, "\r", on: review, window) }
        try? await Task.sleep(for: .milliseconds(600))
        let stayedBlocked = background.title != "Can't open this page"
        window.model.toast = nil
        window.tabs.close(background.id)
        return (shown && explains && escapeCancels && returnCancels && cancelled && toasted && stopped && reviewAsks && reviewCancels && stayedBlocked,
                ["sheetShown": .bool(shown), "explains": .bool(explains), "escapeCancels": .bool(escapeCancels), "returnCancels": .bool(returnCancels),
                 "cancelStopsTheLoad": .bool(cancelled), "backgroundTabToasts": .bool(toasted), "backgroundTabStopped": .bool(stopped),
                 "reviewAsksWithTheSheet": .bool(reviewAsks), "reviewCancelStops": .bool(reviewCancels && stayedBlocked)])
    }

    private static func waitForSheet(_ window: BrowserWindowController) async -> NSWindow? {
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            if let found = window.window?.attachedSheet { return found }
        }
        return nil
    }

    /// Sends a key to the sheet and reports whether the sheet went away. A key only reaches the sheet while it is the key
    /// window, which isn't guaranteed the instant it appears (another window, or the app not active, can hold it), so the
    /// sheet is made key first and the key is sent again if nothing happened. If it never works, the sheet is closed anyway
    /// so the rest of the self-test goes on.
    private static func press(_ keyCode: UInt16, _ character: String, on sheet: NSWindow, _ window: BrowserWindowController) async -> Bool {
        for _ in 0..<3 {
            NSApp.activate(ignoringOtherApps: true)
            sheet.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(150))
            if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: sheet.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
                                            isARepeat: false, keyCode: keyCode) {
                // Return is a key equivalent (the default button); Escape goes through the sheet's key monitor.
                if !sheet.performKeyEquivalent(with: event) { NSApp.sendEvent(event) }
            }
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                if window.window?.attachedSheet == nil { return true }
            }
        }
        window.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        return false
    }
}
