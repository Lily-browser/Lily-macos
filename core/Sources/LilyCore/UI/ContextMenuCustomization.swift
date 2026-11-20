import AppKit
import SwiftUI

/// Which items of a page's right-click menu the user has hidden (Settings → Context Menu).
/// Stored as a space-separated list of item identifiers; nothing hidden is how Lily always behaved.
enum ContextMenuPrefs {
    static let hiddenKey = "HiddenContextMenuItems"

    static let splitViewID = "LilyMenuItemOpenLinkInSplitView"
    static let littleLilyID = "LilyMenuItemOpenLinkInLittleLily"

    struct Entry: Identifiable, Sendable {
        let id: String
        let title: String
    }

    struct Group: Identifiable, Sendable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    /// The items a person can hide, in the order WebKit and Lily show them. Anything WebKit adds that
    /// isn't listed (and Cut, Copy and Paste) always appears.
    static let groups: [Group] = [
        Group(title: "Links", entries: [
            Entry(id: "WKMenuItemIdentifierOpenLinkInNewWindow", title: "Open Link in New Tab"),
            Entry(id: splitViewID, title: "Open Link in Split View"),
            Entry(id: littleLilyID, title: "Open Link in Little Lily"),
            Entry(id: "WKMenuItemIdentifierDownloadLinkedFile", title: "Download Linked File"),
            Entry(id: "WKMenuItemIdentifierCopyLink", title: "Copy Link"),
        ]),
        Group(title: "Images", entries: [
            Entry(id: "WKMenuItemIdentifierOpenImageInNewWindow", title: "Open Image in New Tab"),
            Entry(id: "WKMenuItemIdentifierDownloadImage", title: "Download Image"),
            Entry(id: "WKMenuItemIdentifierCopyImage", title: "Copy Image"),
            Entry(id: "WKMenuItemIdentifierCopyImageURL", title: "Copy Image Address"),
        ]),
        Group(title: "Video and audio", entries: [
            Entry(id: "WKMenuItemIdentifierOpenMediaInNewWindow", title: "Open Video in New Tab"),
            Entry(id: "WKMenuItemIdentifierDownloadMedia", title: "Download Video"),
            Entry(id: "WKMenuItemIdentifierCopyMediaLink", title: "Copy Video Address"),
        ]),
        Group(title: "Page and text", entries: [
            Entry(id: "WKMenuItemIdentifierGoBack", title: "Back"),
            Entry(id: "WKMenuItemIdentifierGoForward", title: "Forward"),
            Entry(id: "WKMenuItemIdentifierReload", title: "Reload"),
            Entry(id: "WKMenuItemIdentifierLookUp", title: "Look Up"),
            Entry(id: "WKMenuItemIdentifierSearchWeb", title: "Search the Web"),
            Entry(id: "WKMenuItemIdentifierTranslate", title: "Translate"),
            Entry(id: "WKMenuItemIdentifierShareMenu", title: "Share"),
            Entry(id: "WKMenuItemIdentifierSpeechMenu", title: "Speech"),
            Entry(id: "WKMenuItemIdentifierSpellingMenu", title: "Spelling and Grammar"),
            Entry(id: "WKMenuItemIdentifierInspectElement", title: "Inspect Element"),
        ]),
    ]

    static var allIDs: Set<String> { Set(groups.flatMap { $0.entries.map(\.id) }) }

    /// Unknown identifiers (from an older or newer version) are dropped, so they can't pile up.
    static func hidden(from stored: String?) -> Set<String> {
        Set((stored ?? "").split(separator: " ").map(String.init)).intersection(allIDs)
    }

    static func stored(_ hidden: Set<String>) -> String { hidden.intersection(allIDs).sorted().joined(separator: " ") }

    static func currentlyHidden(in defaults: UserDefaults = .standard) -> Set<String> {
        hidden(from: defaults.string(forKey: hiddenKey))
    }

    /// Removes the hidden items from a menu about to open, then the separators they leave behind
    /// (leading, trailing or doubled).
    @MainActor static func apply(hidden: Set<String>, to menu: NSMenu) {
        guard !hidden.isEmpty else { return }
        for item in menu.items where hidden.contains(item.identifier?.rawValue ?? "") { menu.removeItem(item) }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        var index = menu.items.count - 1
        while index > 0 {
            if menu.items[index].isSeparatorItem, menu.items[index - 1].isSeparatorItem { menu.removeItem(at: index) }
            index -= 1
        }
    }
}

struct ContextMenuSettingsView: View {
    @AppStorage(ContextMenuPrefs.hiddenKey) private var stored = ""

    private var hidden: Set<String> { ContextMenuPrefs.hidden(from: stored) }

    var body: some View {
        Form {
            ForEach(ContextMenuPrefs.groups) { group in
                LabeledContent(group.title + ":") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(group.entries) { entry in
                            Toggle(entry.title, isOn: Binding(
                                get: { !hidden.contains(entry.id) },
                                set: { shown in
                                    var next = hidden
                                    if shown { next.remove(entry.id) } else { next.insert(entry.id) }
                                    stored = ContextMenuPrefs.stored(next)
                                }))
                        }
                    }
                }
            }
            LabeledContent("") {
                Text("Choose what shows when you right-click a page. Changes apply the next time you open the menu. Cut, Copy and Paste always show.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("") {
                Button("Show All") { stored = "" }.disabled(hidden.isEmpty)
            }
        }
        .formStyle(.columns)
        .padding(20)
    }
}
