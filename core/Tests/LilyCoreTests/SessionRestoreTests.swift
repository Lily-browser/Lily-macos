import Foundation
import Testing
@testable import LilyCore

/// Split groups and spaces survive quitting, and a damaged saved session never breaks a launch.
@Suite @MainActor struct SessionRestoreTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private typealias Session = SessionStore.Session

    func makeStore() throws -> TabStore {
        let registry = try ScriptRegistry(manifestURL: Self.root.appendingPathComponent("injections/manifest.json"))
        return TabStore(factory: WebViewFactory(registry: registry, dataStore: .nonPersistent()), router: IPCRouter())
    }

    private func entry(_ n: Int, space: UUID? = nil, pinned: Bool = false) -> Session.Entry {
        .init(url: URL(string: "https://site\(n).example/")!, title: "Site \(n)", pinned: pinned, space: space)
    }

    private func restored(_ session: Session) throws -> TabStore {
        let store = try makeStore()
        store.restore(session)
        return store
    }

    @Test func onlyWebAddressesAreReopenedFromASavedSession() throws {
        let bad = [URL(string: "data:text/html,<b>x</b>")!, URL(string: "webkit-extension://abc/page.html")!, URL(string: "javascript:alert(1)")!]
        let session = Session(tabs: bad.map { Session.Entry(url: $0, title: "x", pinned: false, space: nil) } + [entry(1)], activeIndex: 0)
        let store = try restored(session)
        #expect(store.tabs.map(\.url?.absoluteString) == ["https://site1.example/"])
    }

    @Test func aSplitAndSpacesRoundTrip() throws {
        let home = Space(name: "Home", symbol: "house.fill")
        let work = Space(name: "Work", symbol: "briefcase.fill")
        let session = Session(tabs: [entry(0, space: home.id, pinned: true), entry(1, space: home.id), entry(2, space: home.id),
                                     entry(3, space: home.id), entry(4, space: work.id), entry(5, space: work.id)],
                              activeIndex: 2, spaces: [home, work], currentSpace: home.id,
                              splits: [.init(layout: .threeRows, tabs: [3, 1, 2], scrollLinked: true),
                                       .init(layout: .twoColumns, tabs: [5, 4])])
        let decoded = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session))
        #expect(decoded == session)

        let store = try restored(decoded)
        let t = store.tabs
        #expect(store.spaces == [home, work] && store.currentSpaceID == home.id)
        #expect(store.splits == [SplitGroup(layout: .threeRows, tabIDs: [t[3].id, t[1].id, t[2].id], scrollLinked: true),
                                 SplitGroup(layout: .twoColumns, tabIDs: [t[5].id, t[4].id])])
        // The active tab is in the first split, so that split is the one on screen.
        #expect(store.activeID == t[2].id && store.split == store.splits[0])
        // Saved again, it's the same session.
        #expect(store.session == session)
    }

    @Test func membersThatArentSavedLeaveTheSplit() throws {
        let store = try restored(Session(tabs: (0..<4).map { entry($0) }, activeIndex: 0,
                                         splits: [.init(layout: .threeColumns, tabs: [0, 1, 2])]))
        // A blank tab joins the split (it becomes a grid) but isn't saved: the saved split shrinks back.
        let blank = store.create(url: nil, activate: false)
        store.addToSplit(blank.id)
        #expect(store.split?.layout == .grid)
        #expect(store.session.splits == [.init(layout: .threeColumns, tabs: [0, 1, 2])])

        // A split of a saved tab and a blank one isn't saved at all.
        let other = try makeStore()
        other.restore(Session(tabs: [entry(0)], activeIndex: 0))
        other.create(url: nil)
        other.makeSplit(.twoColumns, with: [other.tabs[0].id])
        #expect(other.splits.count == 1)
        #expect(other.session.splits == nil)
    }

    @Test func aFileTabThatCantReopenShrinksItsSplit() throws {
        let file = Session.Entry(url: URL(fileURLWithPath: "/nonexistent/page.html"), title: "File", pinned: false)
        let store = try restored(Session(tabs: [file, entry(1), entry(2)], activeIndex: 1,
                                         splits: [.init(layout: .threeColumns, tabs: [0, 1, 2])]))
        #expect(store.tabs.count == 2)
        #expect(store.splits == [SplitGroup(layout: .twoColumns, tabIDs: store.tabs.map(\.id))])
        // The active index still means entry 1, even though entry 0 made no tab.
        #expect(store.activeID == store.tabs[0].id && store.tabs[0].url == URL(string: "https://site1.example/"))

        // The active entry is the file that couldn't reopen: the first visible tab is active instead.
        let fallback = try restored(Session(tabs: [file, entry(1), entry(2)], activeIndex: 0))
        #expect(fallback.tabs.count == 2 && fallback.activeID == fallback.visibleTabs.first?.id)
    }

    @Test func aTwoTabSplitLosingItsFileTabEnds() throws {
        let file = Session.Entry(url: URL(fileURLWithPath: "/nonexistent/page.html"), title: "File", pinned: false)
        let store = try restored(Session(tabs: [entry(0), file, entry(2)], activeIndex: 0,
                                         splits: [.init(layout: .twoColumns, tabs: [0, 1])]))
        #expect(store.splits.isEmpty)
        #expect(store.tabs.count == 2) // nothing opened in the file's place
    }

    @Test func corruptSplitsAreDiscarded() throws {
        let home = Space(name: "Home")
        let work = Space(name: "Work")
        let tabs = [entry(0, space: home.id, pinned: true), entry(1, space: home.id), entry(2, space: home.id),
                    entry(3, space: home.id), entry(4, space: work.id)]
        let bad: [Session.SavedSplit] = [
            .init(layout: .twoColumns, tabs: [1, 99]),       // out of range
            .init(layout: .twoColumns, tabs: [1, -1]),       // negative
            .init(layout: .twoColumns, tabs: [2, 2]),        // the same tab twice
            .init(layout: .twoColumns, tabs: [3, 4]),        // different spaces
            .init(layout: .twoColumns, tabs: [0, 1]),        // a pinned tab
            .init(layout: .twoColumns, tabs: [1, 2, 3]),     // more tabs than panes
            .init(layout: .twoColumns, tabs: [1]),           // one tab
            .init(layout: .twoColumns, tabs: []),
        ]
        for split in bad {
            let store = try restored(Session(tabs: tabs, activeIndex: 1, spaces: [home, work], currentSpace: home.id, splits: [split]))
            #expect(store.splits.isEmpty, "\(split.tabs)")
            #expect(store.tabs.count == tabs.count) // restoring never opens or drops tabs
        }
        // A tab already in an earlier split can't be in a second one; the first stays.
        let store = try restored(Session(tabs: tabs, activeIndex: 1, spaces: [home, work], currentSpace: home.id,
                                         splits: [.init(layout: .twoRows, tabs: [1, 2]), .init(layout: .twoRows, tabs: [2, 3])]))
        #expect(store.splits.map(\.tabIDs) == [[store.tabs[1].id, store.tabs[2].id]])
    }

    @Test func olderSessionsAndUnknownLayoutsDecode() throws {
        let legacy = #"{"tabs":[{"url":"https://a.example/","title":"A","pinned":false}],"activeIndex":0}"#
        let old = try JSONDecoder().decode(Session.self, from: Data(legacy.utf8))
        #expect(old.splits == nil && old.tabs.count == 1)
        #expect(try restored(old).splits.isEmpty)

        // A layout from a newer Lily falls back to one that fits instead of failing the session.
        let newer = #"{"tabs":[],"splits":[{"layout":"hexagon","tabs":[0,1,2]}]}"#
        let split = try #require(try JSONDecoder().decode(Session.self, from: Data(newer.utf8)).splits?.first)
        #expect(split.layout == .threeColumns && split.tabs == [0, 1, 2] && !split.scrollLinked)
    }

    @Test func aMalformedSplitIsDroppedNotTheSession() throws {
        let tabs = #"[{"url":"https://a.example/","title":"A","pinned":false},{"url":"https://b.example/","title":"B","pinned":false}]"#
        let json = #"{"tabs":\#(tabs),"activeIndex":1,"splits":[{"layout":"twoRows","tabs":[0,1]},{"layout":"twoColumns"},{"layout":"grid","tabs":"x"}]}"#
        let session = try JSONDecoder().decode(Session.self, from: Data(json.utf8))
        #expect(session.tabs.count == 2 && session.activeIndex == 1)
        #expect(session.splits == [.init(layout: .twoRows, tabs: [0, 1])])

        // A splits value of the wrong type is ignored too.
        let wrongType = try JSONDecoder().decode(Session.self, from: Data(#"{"tabs":\#(tabs),"splits":"x"}"#.utf8))
        #expect(wrongType.splits == nil && wrongType.tabs.count == 2)
    }

    @Test func sessionStoreKeepsSplits() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lily-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let space = Space(name: "Home")
        let session = Session(tabs: (0..<4).map { entry($0, space: space.id) }, activeIndex: 3, spaces: [space], currentSpace: space.id,
                              splits: [.init(layout: .grid, tabs: [3, 2, 1, 0], scrollLinked: true)])
        let keys = InMemoryKeyStore()
        await SessionStore(directory: dir, keys: keys).save(session)
        let loaded = await SessionStore(directory: dir, keys: keys).load()
        #expect(loaded == session)
    }
}

@Suite struct SidebarTextSizeTests {
    @Test func defaultIsMediumAndSizesGrow() {
        #expect(SidebarTextSize.default == .medium)
        #expect(SidebarTextSize(stored: "") == .medium && SidebarTextSize(stored: "huge") == .medium)
        #expect(SidebarTextSize(stored: "large") == .large)
        let all = SidebarTextSize.allCases
        #expect(all == [.small, .medium, .large])
        for (a, b) in zip(all, all.dropFirst()) {
            #expect(a.titleSize < b.titleSize && a.rowHeight < b.rowHeight && a.favicon < b.favicon)
        }
        // Small is the size the sidebar had before the setting existed.
        #expect(SidebarTextSize.small.titleSize == 13 && SidebarTextSize.small.rowHeight == 26 && SidebarTextSize.small.favicon == 16)
        #expect(all.allSatisfy { $0.rowHeight > $0.titleSize + 8 })
    }
}
