import AppKit
import Testing
@testable import LilyCore

@Suite @MainActor struct ContextMenuCustomizationTests {
    func item(_ id: String, _ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier(id)
        return item
    }

    @Test func storedListRoundTripsAndDropsUnknownIDs() {
        let hidden: Set = ["WKMenuItemIdentifierCopyLink", ContextMenuPrefs.splitViewID]
        #expect(ContextMenuPrefs.hidden(from: ContextMenuPrefs.stored(hidden)) == hidden)
        #expect(ContextMenuPrefs.hidden(from: "WKMenuItemIdentifierCopyLink GoneInANewerVersion") == ["WKMenuItemIdentifierCopyLink"])
        #expect(ContextMenuPrefs.hidden(from: nil).isEmpty)
        #expect(ContextMenuPrefs.hidden(from: "").isEmpty)
    }

    @Test func hidingRemovesItemsAndTheSeparatorsTheyLeave() {
        let menu = NSMenu()
        menu.addItem(item("WKMenuItemIdentifierOpenLinkInNewWindow", "New Tab"))
        menu.addItem(.separator())
        menu.addItem(item("WKMenuItemIdentifierCopyLink", "Copy Link"))
        menu.addItem(.separator())
        menu.addItem(item("WKMenuItemIdentifierInspectElement", "Inspect"))
        ContextMenuPrefs.apply(hidden: ["WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierCopyLink"], to: menu)
        #expect(menu.items.map(\.title) == ["Inspect"]) // no leading, trailing or doubled separators

        let kept = NSMenu()
        kept.addItem(item("WKMenuItemIdentifierGoBack", "Back"))
        kept.addItem(.separator())
        kept.addItem(item("WKMenuItemIdentifierReload", "Reload"))
        ContextMenuPrefs.apply(hidden: [], to: kept)
        #expect(kept.items.count == 3) // nothing hidden: untouched
    }

    @Test func itemsOutsideTheCatalogAreNeverHidden() {
        let menu = NSMenu()
        menu.addItem(item("WKMenuItemIdentifierCopy", "Copy"))
        menu.addItem(item("SomethingWebKitAddsLater", "Later"))
        ContextMenuPrefs.apply(hidden: ContextMenuPrefs.hidden(from: "WKMenuItemIdentifierCopy SomethingWebKitAddsLater"), to: menu)
        #expect(menu.items.count == 2)
    }

    @Test func catalogIDsAreRealAndUnique() {
        let ids = ContextMenuPrefs.groups.flatMap { $0.entries.map(\.id) }
        #expect(Set(ids).count == ids.count)
        for id in ids where id.hasPrefix("WKMenuItemIdentifier") {
            #expect(BrowserWebView.restyle[id] != nil, "\(id) is not a WebKit identifier Lily knows")
        }
        #expect(NSImage(systemSymbolName: "contextualmenu.and.cursorarrow", accessibilityDescription: nil) != nil)
    }
}
