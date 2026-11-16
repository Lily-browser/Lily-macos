import Foundation
import Testing
@testable import LilyCore

/// Resource budgets at scale, run by `make perf` with the tab gate: the work done on every sidebar
/// snapshot, session save, history visit and command bar opening with 5,000 tabs and a full history.
/// Budgets are several times the measured debug-build cost, so only a real regression fails them.
@Suite(.serialized) @MainActor struct ResourceUsageTests {
    typealias Perf = TabManagerPerformanceTests
    static let splitCount = 50

    /// 5,000 tabs, 50 two-pane splits among the regular ones.
    func makeStore() throws -> TabStore {
        let store = try TabManagerPerformanceTests().makeStore()
        TabManagerPerformanceTests().fill(store)
        for index in 0..<Self.splitCount {
            store.activate(store.tabs[index * 40].id)
            store.makeSplit(.twoColumns, with: [store.tabs[index * 40 + 1].id])
        }
        return store
    }

    @Test func sidebarSnapshotWithSplitsIsCheap() throws {
        let store = try makeStore()
        #expect(store.splits.count == Self.splitCount)
        let model = WindowModel(isPrivate: false, assistant: AssistantChat(assistant: Assistant(configuration: .init())))
        model.refresh(from: store)
        // A title or progress tick: one tab changed, the snapshot is rebuilt.
        let refresh = Perf.best { model.refresh(from: store) }
        var items: [WindowModel.ListItem] = []
        let rows = Perf.best { items = model.regularItems }
        print("PERF 5000 tabs + \(Self.splitCount) splits: snapshot refresh \(ms(refresh)), sidebar rows \(ms(rows))")
        #expect(items.count == Perf.tabCount - Self.splitCount)
        #expect(Perf.within(refresh, 0.02))
        #expect(Perf.within(rows, 0.02))
    }

    @Test func sessionCaptureAndEncodeAtFiveThousandTabs() throws {
        let store = try makeStore()
        var session: SessionStore.Session?
        let capture = Perf.best { session = store.session }
        var bytes = 0
        let encode = Perf.best { bytes = (try? JSONEncoder().encode(session))?.count ?? 0 }
        let compare = Perf.best { _ = session == store.session }
        print("PERF session 5000 tabs: capture \(ms(capture)), encode \(ms(encode)) (\(bytes / 1024) KB), unchanged check \(ms(compare))")
        #expect(session?.tabs.count == Perf.tabCount && session?.splits?.count == Self.splitCount)
        #expect(Perf.within(capture, 0.05))
        #expect(Perf.within(encode, 0.1))
    }

    @Test func addressCompletionIndexAtFullHistory() {
        let now = Date()
        let visits = (0..<History.maxEntries).map {
            AddressCompletion.Visit(url: URL(string: "https://h\($0 % 4_000).example.com/page/\($0)")!, title: "Page \($0)", date: now.addingTimeInterval(-Double($0) * 60))
        }
        let tabs = (0..<Perf.tabCount).map { URL(string: "https://site\($0).example.com/page/\($0)")! }
        var index = AddressCompletion.Index.empty
        let build = Perf.best(3) { index = AddressCompletion.index(visits: visits, bookmarks: [], tabs: tabs, now: now) }
        let complete = Perf.best { _ = AddressCompletion.complete("h12", in: index) }
        print("PERF completion index (20000 visits, 5000 tabs): build \(ms(build)), complete \(ms(complete))")
        #expect(!index.sites.isEmpty)
        #expect(Perf.within(build, 1.0))
        #expect(Perf.within(complete, 0.01))
    }

    @Test func recordingAVisitWithFullHistoryIsCheap() {
        let history = History(directory: nil)
        let now = Date()
        history.importVisits((0..<History.maxEntries).map { (URL(string: "https://h\($0).example.com/a")!, "History page \($0)", now.addingTimeInterval(-Double($0))) })
        var next = 0
        let record = Perf.best {
            for _ in 0..<20 {
                history.record(url: URL(string: "https://new\(next).example.org/")!, title: "New \(next)")
                next += 1
            }
        }
        print("PERF 20 visits recorded with 20000 in history: \(ms(record))")
        #expect(history.visits.count == History.maxEntries)
        #expect(Perf.within(record, 0.25))
    }

    /// Closed tabs and their web views are freed, not kept by observers or callbacks.
    @Test func closedTabsAreDeallocated() throws {
        let store = try TabManagerPerformanceTests().makeStore()
        var weakTabs: [() -> Tab?] = []
        for index in 0..<1_000 {
            let tab = store.createAsleep(url: URL(string: "https://c\(index).example/")!, title: "C\(index)", pinned: false, in: store.currentSpaceID)
            weakTabs.append { [weak tab] in tab }
        }
        // A few with live web views, the expensive kind.
        for index in stride(from: 0, to: 1_000, by: 100) { store.activate(store.tabs[index].id) }
        #expect(store.tabs.filter(\.hasWebView).count >= 10)
        store.tabs.map(\.id).forEach(store.close)
        store.clearRecentlyClosed()
        #expect(weakTabs.filter { $0() != nil }.count == 0)
    }

    private func ms(_ seconds: TimeInterval) -> String { String(format: "%.1f ms", seconds * 1000) }
}
