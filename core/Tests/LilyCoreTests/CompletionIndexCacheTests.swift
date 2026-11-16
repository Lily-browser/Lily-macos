import Foundation
import Testing
@testable import LilyCore

@Suite struct CompletionIndexCacheTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let a = URL(string: "https://a.example/")!
    let b = URL(string: "https://b.example/")!

    func key(_ history: Int?, _ bookmarks: Int?, _ tabs: [URL], at offset: TimeInterval = 0) -> CompletionIndexKey {
        CompletionIndexKey(history: history, bookmarks: bookmarks, tabs: tabs, built: t0.addingTimeInterval(offset))
    }

    @Test func reusedWhileNothingChanged() {
        #expect(key(3, 1, [a]).canReuse(for: key(3, 1, [a], at: 60)))
    }

    @Test func rebuiltWhenHistoryBookmarksOrTabsChange() {
        let built = key(3, 1, [a])
        #expect(!built.canReuse(for: key(4, 1, [a])))
        #expect(!built.canReuse(for: key(3, 2, [a])))
        #expect(!built.canReuse(for: key(3, 1, [a, b])))
        #expect(!built.canReuse(for: key(3, nil, [a]))) // e.g. private window: no bookmarks
    }

    @Test func rebuiltWhenStale() {
        #expect(!key(3, 1, [a]).canReuse(for: key(3, 1, [a], at: CompletionIndexKey.maxAge)))
    }

    @MainActor @Test func historyAndBookmarksCountChanges() {
        let history = History(directory: nil)
        let before = history.generation
        history.record(url: a, title: "A")
        #expect(history.generation != before)
    }
}
