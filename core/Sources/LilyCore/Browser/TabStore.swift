import Foundation
import LilyKit

/// Ordered tab collection for one window, divided into spaces. `tabs` holds every space's tabs;
/// `visibleTabs` is the current space. Pinned tabs always sort before unpinned ones.
///
/// The rules (order, selection, spaces, closing, splits, recently closed) are LilyKit's `TabCollection`, shared
/// with Lily-ios. This class keeps the web-view `Tab` objects in step with it and fires the window's callbacks.
@MainActor
public final class TabStore {
    public typealias ClosedTab = LilyKit.ClosedTab
    public typealias AfterClose = LilyKit.AfterClose

    private var collection = TabCollection(spaces: [Space(name: "Personal", symbol: "house.fill")])
    /// Every live tab object by id; `tabs` is these in the collection's order.
    private var objects: [UUID: Tab] = [:]
    public private(set) var tabs: [Tab] = [] { didSet { byID = nil } }
    /// id → tab, rebuilt lazily after the list changes; lookups happen far more often than changes.
    private var byID: [UUID: Tab]?

    public var activeID: UUID? { collection.activeID }
    public var recentlyClosed: [ClosedTab] { collection.recentlyClosed }
    public func clearRecentlyClosed() { collection.clearRecentlyClosed() }

    /// Every split group; a tab belongs to at most one. Each shows as one pill in the sidebar.
    public var splits: [SplitGroup] { collection.splits }
    /// The split the active tab is in, which is the one on screen.
    public var split: SplitGroup? { collection.split }
    public func splitGroup(containing id: UUID) -> SplitGroup? { collection.splitGroup(containing: id) }
    public var onSplitChange: (@MainActor () -> Void)?

    public var spaces: [Space] { collection.spaces }
    public var currentSpaceID: UUID { collection.currentSpaceID }
    public var onSpaceChange: (@MainActor (_ forward: Bool) -> Void)?

    public var currentSpace: Space { collection.currentSpace }
    public var visibleTabs: [Tab] { tabs.filter { $0.spaceID == currentSpaceID } }

    public var onChange: (@MainActor () -> Void)?
    public var onActiveChange: (@MainActor (Tab?) -> Void)?
    /// Tab lifecycle, for the web extension APIs.
    public var onTabAdded: (@MainActor (Tab) -> Void)?
    public var onTabRemoved: (@MainActor (Tab) -> Void)?
    public var onActiveTabSwitched: (@MainActor (_ new: Tab?, _ previous: Tab?) -> Void)?
    public weak var tabDelegate: TabDelegate?

    private let factory: WebViewFactory
    private let router: IPCRouter

    public init(factory: WebViewFactory, router: IPCRouter) {
        self.factory = factory
        self.router = router
    }

    public var active: Tab? { activeID.flatMap(tab) }

    public func tab(_ id: UUID) -> Tab? {
        if byID == nil { byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        return byID?[id]
    }

    // MARK: Keeping the tab objects in step with the collection

    /// What `mutate` removed from the collection; the caller decides whether to tear them down (see `takeRemoved`).
    private var removed: [Tab] = []
    private func takeRemoved() -> [Tab] { defer { removed = [] }; return removed }

    /// Hands the web views' current address, title and activity to the collection, runs `change`, then makes `tabs`
    /// match (making tab objects for tabs the collection added, such as blank split panes).
    /// `sync: false` for changes that don't read those (adding, pinning, moving): with thousands of tabs it is the cost.
    @discardableResult
    private func mutate<T>(sync: Bool = true, inserted: UUID? = nil, _ change: (inout TabCollection) -> T) -> T {
        if sync {
            collection.updateEach { model in
                guard let tab = objects[model.id] else { return }
                model.url = tab.url; model.title = tab.title; model.lastActivated = tab.lastActivated; model.isSleeping = tab.isSleeping
            }
        }
        let splitsBefore = collection.splits
        let result = change(&collection)
        if let inserted, let at = collection.index(of: inserted), collection.tabs.count == tabs.count + 1 {
            // Exactly one tab was added: place it without re-matching thousands of others.
            tabs.insert(makeTab(for: collection.tabs[at]), at: at)
        } else {
            rebuild()
        }
        if collection.splits != splitsBefore { onSplitChange?(); onChange?() }
        return result
    }

    private func rebuild() {
        var list: [Tab] = []
        list.reserveCapacity(collection.tabs.count)
        for model in collection.tabs {
            let tab = objects[model.id] ?? makeTab(for: model)
            if tab.spaceID != model.spaceID { tab.spaceID = model.spaceID }
            if tab.isPinned != model.isPinned { tab.isPinned = model.isPinned }
            list.append(tab)
        }
        removed = []
        if objects.count != list.count {
            let alive = Set(list.map(\.id))
            removed = objects.values.filter { !alive.contains($0.id) }
            for tab in removed { objects[tab.id] = nil }
        }
        tabs = list
    }

    private func makeTab(for model: TabModel) -> Tab {
        // A file is opened by `restoreFileTab`/`openFile`, which hold its security scope before loading.
        let url = model.url?.isFileURL == true ? nil : model.url
        let tab = Tab(id: model.id, factory: factory, router: router, url: url, pinned: model.isPinned, space: model.spaceID,
                      asleepWithTitle: model.isSleeping ? model.title : nil)
        tab.delegate = tabDelegate
        objects[model.id] = tab
        onTabAdded?(tab)
        return tab
    }

    /// Fires what a selection change fires: the extension APIs, the tab waking, the window.
    private func notifyActive(from previousID: UUID?) {
        let changed = activeID != previousID
        if changed { onActiveTabSwitched?(active, previousID.flatMap(tab)) }
        active?.markActivated()
        if changed { onActiveChange?(active) }
        onChange?()
    }

    private func spaceIndex(_ id: UUID) -> Int { spaces.firstIndex { $0.id == id } ?? 0 }

    // MARK: Tabs

    @discardableResult
    /// `nextToActive: nil` follows Settings → Tabs ("Open new tabs next to the current tab").
    public func create(url: URL?, activate: Bool = true, pinned: Bool = false, nextToActive: Bool? = nil) -> Tab {
        let nextToActive = nextToActive ?? Preferences.opensTabsNextToCurrent
        let id = UUID()
        let previous = activeID
        mutate(sync: false, inserted: id) { $0.create(id: id, url: url, activate: activate, pinned: pinned, nextToActive: nextToActive) }
        if activate || previous == nil { notifyActive(from: previous) } else { onChange?() }
        return objects[id]!
    }

    /// Imported tabs: added to `space`, unloaded until first used, without switching to them.
    @discardableResult
    public func createAsleep(url: URL, title: String, pinned: Bool, in space: UUID) -> Tab {
        let id = UUID()
        mutate(sync: false, inserted: id) { $0.createAsleep(id: id, url: url, title: title, pinned: pinned, in: space) }
        onChange?()
        return objects[id]!
    }

    /// Settings → Tabs → After closing a tab, show: which tab takes over when the active one closes.
    /// `then: nil` follows Settings → Tabs → After closing a tab.
    public func close(_ id: UUID, then: AfterClose? = nil) {
        guard tab(id) != nil else { return }
        let previous = activeID
        let wasActive = previous == id
        mutate { $0.close(id, then: then ?? AfterClose.current) }
        for tab in takeRemoved() {
            onTabRemoved?(tab)
            router.forget(tab: tab.id)
            tab.tearDown()
        }
        if wasActive { notifyActive(from: previous) } else { onChange?() }
    }

    @discardableResult
    public func reopenClosed() -> Tab? {
        let previous = activeID, previousSpace = currentSpaceID
        guard let model = mutate({ $0.reopenClosed() }) else { return nil }
        if currentSpaceID != previousSpace { onSpaceChange?(spaceIndex(currentSpaceID) > spaceIndex(previousSpace)) }
        notifyActive(from: previous)
        return objects[model.id]
    }

    /// Activating a tab from another space switches to that space.
    public func activate(_ id: UUID) {
        guard tab(id) != nil else { return }
        let previous = activeID, previousSpace = currentSpaceID
        mutate { $0.activate(id) }
        if currentSpaceID != previousSpace { onSpaceChange?(spaceIndex(currentSpaceID) > spaceIndex(previousSpace)) }
        notifyActive(from: previous)
    }

    public func activate(index: Int) {
        let visible = visibleTabs
        guard visible.indices.contains(index) else { return }
        activate(visible[index].id)
    }

    public func activateLast() {
        if let last = visibleTabs.last { activate(last.id) }
    }

    public func cycle(by offset: Int) {
        let visible = visibleTabs
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == activeID } ?? 0
        activate(visible[(current + offset % visible.count + visible.count) % visible.count].id)
    }

    // MARK: Spaces

    public func switchSpace(to id: UUID) {
        guard id != currentSpaceID, spaces.contains(where: { $0.id == id }) else { return }
        let forward = spaceIndex(id) > spaceIndex(currentSpaceID)
        let previous = activeID
        mutate { $0.switchSpace(to: id) }
        onSpaceChange?(forward)
        notifyActive(from: previous)
    }

    /// Next/previous space, wrapping around.
    public func switchSpace(by offset: Int) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == currentSpaceID }) else { return }
        switchSpace(to: spaces[(index + offset % spaces.count + spaces.count) % spaces.count].id)
    }

    @discardableResult
    public func addSpace(name: String, symbol: String, color: String, separateLogins: Bool = false, activate: Bool = true) -> Space {
        let space = mutate(sync: false) { $0.addSpace(name: name, symbol: symbol, colorHex: color, separateLogins: separateLogins, activate: false) }
        if separateLogins { factory.setSeparateLogins(true, forSpace: space.id) }
        if activate { switchSpace(to: space.id) } else { onChange?() }
        return space
    }

    public func updateSpace(_ space: Space) {
        guard let old = spaces.first(where: { $0.id == space.id }) else { return }
        let switchedStore = old.hasSeparateLogins != space.hasSeparateLogins
        mutate(sync: false) { $0.updateSpace(space) }
        if switchedStore {
            factory.setSeparateLogins(space.hasSeparateLogins, forSpace: space.id)
            tabs.filter { $0.spaceID == space.id }.forEach { $0.rebuildWebView() }
            if active?.spaceID == space.id { onActiveChange?(active) }
        }
        onChange?()
    }

    /// Deletes a space and closes its tabs; the last space can't be deleted.
    public func deleteSpace(_ id: UUID) {
        guard spaces.count > 1, let index = spaces.firstIndex(where: { $0.id == id }) else { return }
        if id == currentSpaceID { switchSpace(to: spaces[index == 0 ? 1 : index - 1].id) }
        tabs.filter { $0.spaceID == id }.forEach { close($0.id) }
        let separate = spaces.first { $0.id == id }?.hasSeparateLogins ?? false
        mutate { $0.deleteSpace(id) }
        onChange?()
        // Its tabs are gone, so its logins and site data go too.
        if separate { Task { [factory] in await factory.removeSpaceData(id) } }
    }

    public func moveTab(_ id: UUID, toSpace space: UUID) {
        guard let tab = tab(id), tab.spaceID != space, spaces.contains(where: { $0.id == space }) else { return }
        let store = factory.dataStore(forSpace: tab.spaceID)
        let previous = activeID
        mutate { $0.moveTab(id, toSpace: space) }
        // Cookies don't follow a tab into a space with a different store; it reloads there.
        if factory.dataStore(forSpace: space) !== store { tab.rebuildWebView() }
        if previous == id { notifyActive(from: previous) } else { onChange?() }
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard let tab = tab(id), tab.isPinned != pinned else { return }
        mutate(sync: false) { $0.setPinned(id, pinned) }
        onChange?()
    }

    /// Moves within the tab's own section (pinned / unpinned); the index is clamped.
    public func move(_ id: UUID, to requested: Int) {
        guard tab(id) != nil else { return }
        mutate(sync: false) { $0.move(id, to: requested) }
        onChange?()
    }

    public func closeAll() {
        let all = tabs
        mutate { $0.closeAll() }
        removed = []
        all.forEach { $0.tearDown() }
    }

    // MARK: Session

    public var session: SessionStore.Session {
        let saved: [Tab] = tabs.filter { tab in
            guard let url = tab.url else { return false }
            return url.isFileURL ? tab.fileBookmark != nil : (url.scheme == "http" || url.scheme == "https")
        }
        return SessionStore.Session(
            tabs: saved.map { tab in
                .init(url: tab.url!, title: tab.title, pinned: tab.isPinned, bookmark: tab.url!.isFileURL ? tab.fileBookmark : nil, space: tab.spaceID)
            },
            activeIndex: saved.firstIndex { $0.id == activeID },
            spaces: spaces,
            currentSpace: currentSpaceID,
            splits: savedSplits(of: saved))
    }

    /// Split groups by position in the saved tabs. Members that aren't saved (blank tabs, pages
    /// that can't be reopened) drop out, shrinking the layout; groups left with one tab end.
    private func savedSplits(of saved: [Tab]) -> [SessionStore.Session.SavedSplit]? {
        guard !splits.isEmpty else { return nil }
        let position = Dictionary(saved.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept: [SessionStore.Session.SavedSplit] = splits.compactMap { group in
            var group = group
            group.tabIDs.removeAll { position[$0] == nil }
            guard let fitted = group.fitted() else { return nil }
            return .init(layout: fitted.layout, tabs: fitted.tabIDs.compactMap { position[$0] }, scrollLinked: fitted.scrollLinked)
        }
        return kept.isEmpty ? nil : kept
    }

    // MARK: Split view

    /// With the active tab outside a split: starts a new split of it, the requested tabs, then the
    /// following tabs that aren't in another split (wrapping around), opening blank tabs when there
    /// aren't enough. Existing splits are left alone.
    /// With the active tab in a split: requested tabs join that split; without any, the split
    /// changes to `layout`, filling or dropping panes at the end.
    @discardableResult
    public func makeSplit(_ layout: SplitLayout, with requested: [UUID] = []) -> SplitGroup? {
        guard active != nil else { return nil }
        let previous = activeID
        let group = mutate { $0.makeSplit(layout, with: requested) }
        if activeID != previous { notifyActive(from: previous) } else { onChange?() }
        return group
    }

    /// Adds a tab to the active tab's split (moving it out of any other split) and shows it.
    public func addToSplit(_ id: UUID) {
        let previous = activeID
        mutate { $0.addToSplit(id) }
        if activeID != previous { notifyActive(from: previous) }
    }

    public func removeFromSplit(_ id: UUID) { mutate { $0.removeFromSplit(id) } }

    /// Link Scrolling for the split on screen.
    public func setScrollLinked(_ linked: Bool) { mutate { $0.setScrollLinked(linked) } }

    /// Ends the split on screen; other splits stay.
    public func exitSplit() { mutate { $0.exitSplit() } }

    // MARK: Moving tabs between windows

    /// Takes `id` out of this store without tearing it down (no `tearDown`, no recently-closed
    /// entry), to hand to another window's store (`adopt`). It leaves its split.
    @discardableResult
    public func detach(_ id: UUID) -> Tab? {
        guard let tab = tab(id) else { return nil }
        let previous = activeID
        mutate { $0.close(id, remember: false) }
        removed = []
        onTabRemoved?(tab)
        router.forget(tab: tab.id)
        if previous == id { notifyActive(from: previous) } else { onChange?() }
        return tab
    }

    /// A tab from another window joins this one: in the current space, after the active tab,
    /// with this window's routes. Its page keeps running, except that moving into a space with a
    /// different data store (Separate logins) reloads it on that store, as moving between spaces does.
    public func adopt(_ tab: Tab, activate: Bool = true) {
        let store = factory.dataStore(forSpace: tab.spaceID)
        tab.isPinned = false
        tab.rebind(router: router)
        tab.spaceID = currentSpaceID
        if factory.dataStore(forSpace: currentSpaceID) !== store { tab.rebuildWebView() }
        tab.delegate = tabDelegate
        objects[tab.id] = tab
        let previous = activeID
        mutate { $0.create(id: tab.id, url: tab.url, title: tab.title, activate: activate, pinned: false, nextToActive: true) }
        onTabAdded?(tab)
        if activate || previous == nil { notifyActive(from: previous) } else { onChange?() }
    }

    /// Opens a local file the user chose (Open panel, Finder, or a restored bookmark).
    @discardableResult
    public func openFile(_ url: URL, activate: Bool = true, pinned: Bool = false) -> Tab {
        let tab = create(url: nil, activate: activate, pinned: pinned, nextToActive: false)
        tab.holdSecurityScope(url)
        tab.load(url)
        return tab
    }

    public func restore(_ session: SessionStore.Session) {
        if let saved = session.spaces, !saved.isEmpty {
            mutate { $0.replaceSpaces(saved, current: session.currentSpace) }
            for space in saved where space.hasSeparateLogins { factory.setSeparateLogins(true, forSpace: space.id) }
        }
        let known = Set(spaces.map(\.id))
        // The tab made for each entry; nil where a file couldn't be reopened.
        var created: [Tab?] = []
        created.reserveCapacity(session.tabs.count)
        for entry in session.tabs {
            let space = entry.space.flatMap { known.contains($0) ? $0 : nil } ?? spaces[0].id
            if entry.url.isFileURL {
                var stale = false
                guard let bookmark = entry.bookmark,
                      let file = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale) else {
                    created.append(nil)
                    continue
                }
                let tab = createAsleep(url: file, title: "", pinned: entry.pinned, in: space)
                tab.holdSecurityScope(file)
                tab.load(file)
                created.append(tab)
            } else if ["http", "https"].contains(entry.url.scheme?.lowercased()) {
                // Restored tabs load when first opened, not all at launch.
                created.append(createAsleep(url: entry.url, title: entry.title, pinned: entry.pinned, in: space))
            } else {
                created.append(nil) // data:, webkit-extension: and other schemes are never reopened from a saved session
            }
        }
        if let i = session.activeIndex, created.indices.contains(i), let tab = created[i], tab.spaceID == currentSpaceID { activate(tab.id) }
        else if let first = visibleTabs.first { activate(first.id) }
        else { onChange?() }
        let restored = Self.restoredSplits(session.splits ?? [], created: created)
        if !restored.isEmpty { mutate { $0.replaceSplits(restored) } }
    }

    /// Rebuilds saved split groups from the restored tabs. A group that doesn't describe real tabs
    /// (an index out of range, a tab twice or already in another group, pinned tabs, members in
    /// different spaces, more tabs than its layout) is dropped; members whose tab couldn't be
    /// reopened leave it, shrinking the layout. Never opens tabs.
    static func restoredSplits(_ saved: [SessionStore.Session.SavedSplit], created: [Tab?]) -> [SplitGroup] {
        var taken = Set<UUID>()
        var groups: [SplitGroup] = []
        for split in saved {
            guard split.tabs.count <= split.layout.paneCount, Set(split.tabs).count == split.tabs.count,
                  split.tabs.allSatisfy(created.indices.contains) else { continue }
            let members = split.tabs.compactMap { created[$0] }
            guard let space = members.first?.spaceID,
                  members.allSatisfy({ !$0.isPinned && $0.spaceID == space && !taken.contains($0.id) }),
                  let group = SplitGroup(layout: split.layout, tabIDs: members.map(\.id), scrollLinked: split.scrollLinked).fitted()
            else { continue }
            taken.formUnion(group.tabIDs)
            groups.append(group)
        }
        return groups
    }
}

extension AfterClose {
    /// Settings → Tabs → After closing a tab, show.
    static var current: AfterClose { AfterClose(stored: UserDefaults.standard.string(forKey: Preferences.Key.afterClosingTab)) }

    var label: String {
        switch self {
        case .lastUsed: return "Last used tab"
        case .below: return "Tab below"
        case .above: return "Tab above"
        }
    }
}
