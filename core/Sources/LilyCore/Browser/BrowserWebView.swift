import AppKit
import WebKit

/// The tab's web view. Tidies WebKit's context menu: SF Symbol icons on every item, "New Tab"
/// instead of "New Window" (Lily opens new windows as tabs), and Open Link in Split View.
@MainActor
final class BrowserWebView: WKWebView {
    /// Called just before WebKit is asked to open the right-clicked link in a new window, so the
    /// tab can route that request into split view instead of a plain new tab.
    /// Where the next link opened from the context menu should go, set just before WebKit asks
    /// for a new window (`Tab.webView(_:createWebViewWith:…)`).
    enum LinkTarget { case split, little }
    var willOpenLink: ((LinkTarget) -> Void)?

    /// WebKit's menu item identifiers (stable strings) → our title (nil keeps WebKit's) and symbol.
    static let restyle: [String: (title: String?, symbol: String)] = [
        "WKMenuItemIdentifierOpenLinkInNewWindow": ("Open Link in New Tab", "plus.square.on.square"),
        "WKMenuItemIdentifierDownloadLinkedFile": ("Download Linked File", "arrow.down.circle"),
        "WKMenuItemIdentifierCopyLink": ("Copy Link", "link"),
        "WKMenuItemIdentifierOpenImageInNewWindow": ("Open Image in New Tab", "photo"),
        "WKMenuItemIdentifierDownloadImage": ("Download Image", "arrow.down.circle"),
        "WKMenuItemIdentifierCopyImage": ("Copy Image", "doc.on.doc"),
        "WKMenuItemIdentifierCopyImageURL": ("Copy Image Address", "link"),
        "WKMenuItemIdentifierOpenMediaInNewWindow": ("Open Video in New Tab", "play.rectangle"),
        "WKMenuItemIdentifierDownloadMedia": ("Download Video", "arrow.down.circle"),
        "WKMenuItemIdentifierCopyMediaLink": ("Copy Video Address", "link"),
        "WKMenuItemIdentifierToggleFullScreen": (nil, "arrow.up.left.and.arrow.down.right"),
        "WKMenuItemIdentifierToggleEnhancedFullScreen": (nil, "pip.enter"),
        "WKMenuItemIdentifierShowHideMediaControls": (nil, "slider.horizontal.below.rectangle"),
        "WKMenuItemIdentifierPlayPause": (nil, "playpause"),
        "WKMenuItemIdentifierMute": (nil, "speaker.slash"),
        "WKMenuItemIdentifierGoBack": (nil, "chevron.backward"),
        "WKMenuItemIdentifierGoForward": (nil, "chevron.forward"),
        "WKMenuItemIdentifierReload": (nil, "arrow.clockwise"),
        "WKMenuItemIdentifierCopy": (nil, "doc.on.doc"),
        "WKMenuItemIdentifierCut": (nil, "scissors"),
        "WKMenuItemIdentifierPaste": (nil, "doc.on.clipboard"),
        "WKMenuItemIdentifierLookUp": (nil, "character.book.closed"),
        "WKMenuItemIdentifierSearchWeb": (nil, "magnifyingglass"),
        "WKMenuItemIdentifierTranslate": (nil, "translate"),
        "WKMenuItemIdentifierShareMenu": (nil, "square.and.arrow.up"),
        "WKMenuItemIdentifierSpeechMenu": (nil, "waveform"),
        "WKMenuItemIdentifierSpellingMenu": (nil, "textformat.abc"),
        "WKMenuItemIdentifierInspectElement": (nil, "hammer"),
    ]

    // MARK: Swipe diagnostics (#160)

    private var swipeProbePending = false

    /// A horizontal two-finger gesture may be WebKit's back/forward swipe. The gray page of #160 can't be seen from outside,
    /// so a gesture that looks like a swipe logs, once, what is on screen: WebKit's swipe layers and whether their snapshot
    /// holds an image, then the layers around the web view. Counts and sizes only, never page content. Event driven: nothing
    /// runs unless a horizontal gesture starts.
    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        guard !swipeProbePending, event.hasPreciseScrollingDeltas, event.phase == .began || event.phase == .changed,
              abs(event.scrollingDeltaX) > 4, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.5 else { return }
        swipeProbePending = true
        Task { @MainActor [weak self] in
            for stage in ["150 ms", "600 ms"] {
                try? await Task.sleep(for: .milliseconds(stage == "150 ms" ? 150 : 450))
                self?.logSwipeLayers(stage: stage)
            }
            self?.swipeProbePending = false
        }
    }

    @discardableResult
    func logSwipeLayers(stage: String) -> String {
        func color(_ layer: CALayer) -> String {
            guard let cg = layer.backgroundColor, let c = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) else { return "none" }
            return "\(Int(c.redComponent * 255)),\(Int(c.greenComponent * 255)),\(Int(c.blueComponent * 255))"
        }
        var found: [String] = []
        func walk(_ layer: CALayer, _ depth: Int) {
            if let name = layer.name, name.hasPrefix("Gesture Swipe") {
                found.append("\(name.dropFirst(14)) \(Int(layer.bounds.width))x\(Int(layer.bounds.height)) image=\(layer.contents != nil) hidden=\(layer.isHidden) alpha=\(layer.opacity) bg=\(color(layer))")
            }
            if depth < 5 { for sub in layer.sublayers ?? [] { walk(sub, depth + 1) } }
        }
        if let layer { walk(layer, 0) }
        guard !found.isEmpty else {
            Log.web.info("Horizontal gesture (\(stage, privacy: .public)): no swipe layers")
            return "no swipe layers"
        }
        var chain: [String] = []
        var view: NSView? = self
        while let v = view, chain.count < 5 {
            let l = v.layer
            chain.append("\(String(describing: type(of: v)).split(separator: ".").last ?? "") \(Int(v.frame.width))x\(Int(v.frame.height)) mask=\(l?.masksToBounds == true) radius=\(Int(l?.cornerRadius ?? 0)) bg=\(l.map { color($0) } ?? "none")")
            view = v.superview
        }
        let history = "back \(backForwardList.backList.count) forward \(backForwardList.forwardList.count)"
        let line = "Swipe (\(stage)), \(history); swipe layers: \(found.joined(separator: " | ")); views: \(chain.joined(separator: " < "))"
        Log.web.notice("\(line, privacy: .public)")
        return line
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // Last of all, so the items Lily adds below can be hidden too (also on the early return).
        defer { ContextMenuPrefs.apply(hidden: ContextMenuPrefs.currentlyHidden(), to: menu) }
        Self.dropOpenLink(from: menu)
        Self.restyle(menu)
        Self.routeInspectElement(in: menu, through: self)
        if let newTab = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }),
           let index = menu.items.firstIndex(of: newTab) {
            let split = NSMenuItem(title: "Open Link in Split View", action: #selector(openLinkInSplit(_:)), keyEquivalent: "")
            split.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
            split.target = self
            split.identifier = NSUserInterfaceItemIdentifier(ContextMenuPrefs.splitViewID)
            split.representedObject = newTab
            menu.insertItem(split, at: index + 1)
            // Little Lily windows use the regular profile, so private windows don't offer them.
            guard (window?.windowController as? BrowserWindowController)?.isPrivate != true else { return }
            let little = NSMenuItem(title: "Open Link in Little Lily", action: #selector(openLinkInLittle(_:)), keyEquivalent: "")
            little.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
            little.target = self
            little.identifier = NSUserInterfaceItemIdentifier(ContextMenuPrefs.littleLilyID)
            little.representedObject = newTab
            menu.insertItem(little, at: index + 2)
        }
    }

    /// Removes WebKit's plain "Open Link" (it navigates the current tab), so "Open Link in New Tab"
    /// becomes the first item of a link's menu.
    static func dropOpenLink(from menu: NSMenu) {
        for item in menu.items where item.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" { menu.removeItem(item) }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
    }

    /// WebKit's own Inspect Element item opens the inspector docked. Run it as usual, then move the
    /// inspector into its own window (see `InspectorWindow`).
    static func routeInspectElement(in menu: NSMenu, through view: BrowserWebView) {
        guard let item = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierInspectElement" }),
              let action = item.action, item.target !== view else { return }
        item.representedObject = OriginalAction(target: item.target, action: action)
        item.target = view
        item.action = #selector(inspectElement(_:))
    }

    private struct OriginalAction { let target: AnyObject?; let action: Selector }

    @objc private func inspectElement(_ sender: NSMenuItem) {
        guard let original = sender.representedObject as? OriginalAction else { return }
        NSApp.sendAction(original.action, to: original.target, from: sender)
        InspectorWindow.keepDetached(for: self)
    }

    static func restyle(_ menu: NSMenu) {
        for item in menu.items {
            guard let id = item.identifier?.rawValue, let style = restyle[id] else { continue }
            if let title = style.title { item.title = title }
            if item.image == nil { item.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil) }
        }
    }

    /// WebKit keeps the right-clicked link to itself; its own "open in new window" item knows it.
    /// Mark where the next new-window request goes, then let that item run.
    @objc private func openLinkInSplit(_ sender: NSMenuItem) { openLink(sender, in: .split) }
    @objc private func openLinkInLittle(_ sender: NSMenuItem) { openLink(sender, in: .little) }

    private func openLink(_ sender: NSMenuItem, in target: LinkTarget) {
        guard let newTab = sender.representedObject as? NSMenuItem, let action = newTab.action else { return }
        willOpenLink?(target)
        NSApp.sendAction(action, to: newTab.target, from: newTab)
    }
}
