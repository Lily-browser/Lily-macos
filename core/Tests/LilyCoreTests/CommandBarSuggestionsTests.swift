import Foundation
import Testing
@testable import LilyCore

/// Inline completion, frecency ranking and search-engine suggestions for the command bar.
@Suite(.serialized) @MainActor struct CommandBarSuggestionsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func visit(_ url: String, daysAgo: Double = 0, title: String = "") -> AddressCompletion.Visit {
        AddressCompletion.Visit(url: URL(string: url)!, title: title, date: now.addingTimeInterval(-daysAgo * 86_400))
    }

    private func index(_ visits: [AddressCompletion.Visit], bookmarks: [String] = [], tabs: [String] = []) -> AddressCompletion.Index {
        AddressCompletion.index(visits: visits, bookmarks: bookmarks.map { URL(string: $0)! }, tabs: tabs.map { URL(string: $0)! }, now: now)
    }

    // MARK: Inline completion

    @Test func completesToTheHostOfAFrequentSite() throws {
        let idx = index([visit("https://github.com/a"), visit("https://github.com/b", daysAgo: 1), visit("https://gitlab.com/x")])
        let completion = try #require(AddressCompletion.complete("git", in: idx))
        #expect(completion.text == "github.com")
        #expect(completion.url.absoluteString == "https://github.com/")
        #expect(completion.selectedRange == NSRange(location: 3, length: 7))
        // Case as typed is kept; the rest comes from the site.
        #expect(AddressCompletion.complete("GiT", in: idx)?.text == "GiThub.com")
    }

    @Test func keepsATypedSchemeAndWWW() {
        let idx = index([visit("https://www.youtube.com/watch"), visit("https://www.youtube.com/")])
        #expect(AddressCompletion.complete("you", in: idx)?.text == "youtube.com")
        #expect(AddressCompletion.complete("https://you", in: idx)?.text == "https://youtube.com")
        #expect(AddressCompletion.complete("www.you", in: idx)?.text == "www.youtube.com")
        #expect(AddressCompletion.complete("you", in: idx)?.url.absoluteString == "https://www.youtube.com/") // opens the origin visited
        #expect(AddressCompletion.complete("https://", in: idx) == nil)
        #expect(AddressCompletion.complete("www.", in: idx) == nil)
    }

    @Test func neverCompletesSearchesOrOneOffVisits() {
        let idx = index([visit("https://github.com/"), visit("https://github.com/x"), visit("https://once.example/")])
        #expect(AddressCompletion.complete("git hub", in: idx) == nil) // a space: a search
        #expect(AddressCompletion.complete("git ", in: idx) == nil)
        #expect(AddressCompletion.complete("", in: idx) == nil)
        #expect(AddressCompletion.complete("onc", in: idx) == nil) // visited once
        #expect(AddressCompletion.complete("github.com", in: idx) == nil) // nothing left to add
        #expect(AddressCompletion.complete("hub", in: idx) == nil) // only from the start of the host
    }

    @Test func bookmarksAndOpenTabsQualifyAfterOneVisit() {
        let idx = index([visit("https://news.example/")], bookmarks: ["https://bookmarked.example/page"], tabs: ["https://tabbed.example/"])
        #expect(AddressCompletion.complete("boo", in: idx)?.text == "bookmarked.example")
        #expect(AddressCompletion.complete("tab", in: idx)?.text == "tabbed.example")
        #expect(AddressCompletion.complete("new", in: idx) == nil)
    }

    @Test func completesPathsAfterASlash() {
        let idx = index([
            visit("https://github.com/pwngoblin/Lily"), visit("https://github.com/pwngoblin/Lily", daysAgo: 2),
            visit("https://github.com/pwngoblin/other"),
            visit("https://github.com/search?q=x"), visit("https://github.com/search?q=x", daysAgo: 1),
        ])
        #expect(AddressCompletion.complete("github.com/pw", in: idx)?.text == "github.com/pwngoblin/Lily")
        #expect(AddressCompletion.complete("github.com/pw", in: idx)?.url.absoluteString == "https://github.com/pwngoblin/Lily")
        #expect(AddressCompletion.complete("github.com/se", in: idx) == nil) // pages with a query aren't completed to
    }

    @Test func completionOpensTheSchemeTypedOrHTTPS() {
        // Visited mostly over http, once over https: https is preferred.
        let idx = index([visit("http://example.com/a"), visit("http://example.com/b"), visit("http://example.com/c"),
                         visit("https://example.com/d"), visit("http://plain.example/"), visit("http://plain.example/x")])
        #expect(AddressCompletion.complete("exa", in: idx)?.url.absoluteString == "https://example.com/")
        #expect(AddressCompletion.complete("https://exa", in: idx)?.url.absoluteString == "https://example.com/")
        #expect(AddressCompletion.complete("HTTPS://exa", in: idx)?.text == "HTTPS://example.com")
        #expect(AddressCompletion.complete("HTTPS://exa", in: idx)?.url.scheme == "https")
        #expect(AddressCompletion.complete("http://exa", in: idx)?.url.absoluteString == "http://example.com/")
        // Only ever visited over http: shown and opened as http unless https is typed.
        #expect(AddressCompletion.complete("pla", in: idx)?.url.absoluteString == "http://plain.example/")
        #expect(AddressCompletion.complete("https://pla", in: idx)?.url.absoluteString == "https://plain.example/")
    }

    @Test func completionEdgeCases() {
        let idx = index([visit("https://github.com/"), visit("https://github.com/"), visit("http://localhost:8080/app"),
                         visit("http://localhost:8080/app")])
        #expect(AddressCompletion.complete("github.com/", in: idx) == nil) // the site root: nothing left to add
        #expect(AddressCompletion.complete("loc", in: idx)?.text == "localhost") // hosts complete without the port
        #expect(AddressCompletion.complete("localhost:80", in: idx) == nil)
    }

    @Test func prefersTheSiteWithHigherFrecency() {
        // Recent visits outweigh old ones.
        let idx = index([visit("https://youtube.com/", daysAgo: 1), visit("https://youtube.com/a", daysAgo: 2),
                         visit("https://yourbank.example/", daysAgo: 200), visit("https://yourbank.example/b", daysAgo: 200),
                         visit("https://yourbank.example/c", daysAgo: 200)])
        #expect(AddressCompletion.complete("you", in: idx)?.text == "youtube.com")
        #expect(AddressCompletion.complete("your", in: idx)?.text == "yourbank.example")
        #expect(AddressCompletion.weight(age: 0) > AddressCompletion.weight(age: 10 * 86_400))
        #expect(AddressCompletion.weight(age: 10 * 86_400) > AddressCompletion.weight(age: 400 * 86_400))
    }

    @Test func ranksHostPrefixMatchesFirstThenByFrecency() {
        let urls = ["https://example.com/about-you", "https://www.youtube.com/watch", "https://blog.example/you"].map { URL(string: $0)! }
        let scores: [URL: Double] = [urls[0]: 500, urls[1]: 10, urls[2]: 100]
        let ranked = AddressCompletion.rank(urls, url: { $0 }, query: "you", score: { scores[$0] ?? 0 })
        #expect(ranked.map(\.absoluteString) == ["https://www.youtube.com/watch", "https://example.com/about-you", "https://blog.example/you"])
    }

    @Test func topSitesSkipTheCurrentSite() {
        let idx = index([visit("https://a.example/", title: "A"), visit("https://a.example/x"), visit("https://b.example/"),
                         visit("https://c.example/")])
        let top = AddressCompletion.topSites(idx, excluding: URL(string: "https://a.example/y"), limit: 6)
        #expect(!top.contains { $0.key == "a.example" })
        #expect(Set(top.map(\.key)) == ["b.example", "c.example"])
        #expect(AddressCompletion.topSites(idx, excluding: nil, limit: 1).first?.title == "A")
    }

    @Test func indexesAFullHistoryQuickly() {
        let visits = (0..<History.maxEntries).map { visit("https://h\($0 % 2_000).example.com/p\($0)", daysAgo: Double($0 % 120)) }
        let started = Date()
        let idx = index(visits, tabs: (0..<5_000).map { "https://t\($0).example.org/" })
        let built = Date().timeIntervalSince(started)
        let completeStarted = Date()
        for prefix in ["h1", "h19", "t4", "h1999.example.com/p"] { _ = AddressCompletion.complete(prefix, in: idx) }
        let completing = Date().timeIntervalSince(completeStarted)
        #expect(idx.sites.count == 7_000)
        #expect(built < 1.0, "built in \(built)s") // off the main actor, once per command bar
        #expect(completing < 0.05, "\(completing)s for 4 keystrokes")
    }

    // MARK: Engine suggestions: decoding

    @Test func decodesOpenSearchResponses() {
        #expect(SearchSuggestions.decode(Data(#"["lily", ["lily flower", "lily allen"]]"#.utf8)) == ["lily flower", "lily allen"])
        // Google adds more elements; they're ignored.
        #expect(SearchSuggestions.decode(Data(#"["q", ["a"], [], {"google:suggesttype": []}]"#.utf8)) == ["a"])
        #expect(SearchSuggestions.decode(Data(#"["q", []]"#.utf8)) == [])
    }

    @Test func rejectsMalformedAndOversizedResponses() {
        #expect(SearchSuggestions.decode(Data("not json".utf8)) == nil)
        #expect(SearchSuggestions.decode(Data(#"{"q": ["a"]}"#.utf8)) == nil)
        #expect(SearchSuggestions.decode(Data(#"["q"]"#.utf8)) == nil)
        #expect(SearchSuggestions.decode(Data(#"["q", "a"]"#.utf8)) == nil)
        #expect(SearchSuggestions.decode(Data(#"[1, ["a"]]"#.utf8)) == nil)
        let big = #"["q", [""# + String(repeating: "a", count: 70_000) + #""]]"#
        #expect(SearchSuggestions.decode(Data(big.utf8)) == nil)
    }

    @Test func keepsFiveCleanDistinctStrings() {
        let json = #"["q", [1, null, {"x": 1}, "one", "One", "  two\u0000\nlines  ", "three‮", "", "four", "five", "six", "seven"]]"#
        let decoded = SearchSuggestions.decode(Data(json.utf8))
        #expect(decoded == ["one", "two lines", "three", "four", "five"])
        let long = String(repeating: "x", count: 201)
        #expect(SearchSuggestions.decode(Data(#"["q", ["\#(long)", "ok"]]"#.utf8)) == ["ok"])
        #expect(SearchSuggestions.sanitize("a\u{200B}b\u{7}c") == "ab c")
        // Hangul fillers and the combining grapheme joiner look blank: dropped.
        #expect(SearchSuggestions.sanitize("a\u{3164}\u{115F}\u{FFA0}\u{034F}b") == "ab")
        #expect(SearchSuggestions.sanitize("\u{3164}") == nil)
        // Exactly 200 characters is kept, 201 isn't; a combining-mark flood is capped by scalars.
        #expect(SearchSuggestions.sanitize(String(repeating: "a", count: 200))?.count == 200)
        #expect(SearchSuggestions.sanitize(String(repeating: "a", count: 201)) == nil)
        #expect(SearchSuggestions.sanitize("a" + String(repeating: "\u{0301}", count: 500)) == nil)
    }

    // MARK: Engine suggestions: requests

    @Test func buildsEachEnginesEndpointWithAnEncodedQuery() throws {
        let query = "a&b=c+d é#?/"
        for engine in Preferences.SearchEngine.allCases where engine != .kagi {
            let url = try #require(SearchSuggestions.endpoint(for: engine, query: query))
            #expect(url.scheme == "https")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let name = engine == .bing ? "query" : "q"
            #expect(items.first { $0.name == name }?.value == query, "\(engine)")
            #expect(items.filter { $0.name == name }.count == 1)
            #expect(url.absoluteString.contains("%2B") && url.absoluteString.contains("%26") && !url.absoluteString.contains("#"))
        }
        #expect(SearchSuggestions.endpoint(for: .duckDuckGo, query: "x")?.host == "duckduckgo.com")
        #expect(SearchSuggestions.endpoint(for: .google, query: "x")?.host == "suggestqueries.google.com")
        #expect(SearchSuggestions.endpoint(for: .bing, query: "x")?.host == "api.bing.com")
        #expect(SearchSuggestions.endpoint(for: .ecosia, query: "x")?.host == "ac.ecosia.org")
        #expect(SearchSuggestions.endpoint(for: .kagi, query: "x") == nil) // never sent to another company
    }

    @Test func onlyFetchesForSearchesInRegularWindows() {
        let resolver = URLResolver()
        func fetches(_ q: String, engine: Preferences.SearchEngine = .duckDuckGo, enabled: Bool = true, isPrivate: Bool = false) -> Bool {
            SearchSuggestions.shouldFetch(q, engine: engine, enabled: enabled, isPrivate: isPrivate, resolver: resolver)
        }
        #expect(fetches("swift concurrency"))
        #expect(fetches("lily"))
        #expect(fetches("note: buy milk"))
        #expect(!fetches(""))
        #expect(!fetches("   "))
        #expect(!fetches(String(repeating: "a", count: 201)))
        #expect(!fetches("lily", isPrivate: true))
        #expect(!fetches("lily", enabled: false))
        #expect(!fetches("lily", engine: .kagi))
        #expect(!fetches("github.com"))
        #expect(!fetches("github.com/pwngoblin"))
        #expect(!fetches("https://ex"))
        #expect(!fetches("http:"))
        #expect(!fetches("javascript:alert(1)"))
        #expect(!fetches("localhost:3000"))
        #expect(!fetches("me@example.com"))
        #expect(!fetches("/Users/me/secret.txt"))
        #expect(!fetches("~/Documents"))
        #expect(!fetches("../etc"))
        #expect(fetches(String(repeating: "a", count: 200)))
        #expect(!fetches(String(repeating: "a", count: 201)))
        #expect(!fetches("192.168.1.1"))
        #expect(!fetches("[::1]"))
        #expect(!fetches("fe80::1"))
        #expect(!fetches("about:blank"))
        #expect(!fetches("file:///etc/passwd"))
        #expect(!fetches("data:text/html,hi"))
        #expect(!fetches("two\nlines"))
        #expect(!fetches("a\ttab"))
        #expect(!fetches("foo https://site/x?token=1"))
        #expect(!fetches("open github.com please"))
        #expect(!fetches("mail me at me@example.com"))
        #expect(!fetches("key sk9f8a7d6s5f4g3h2j1k0l9z8x"))
        #expect(fetches("iphone 15 pro max 256gb"))
    }

    @Test func theSettingIsOnByDefault() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: Preferences.Key.searchSuggestions)
        defer { if let saved { defaults.set(saved, forKey: Preferences.Key.searchSuggestions) } else { defaults.removeObject(forKey: Preferences.Key.searchSuggestions) } }
        defaults.removeObject(forKey: Preferences.Key.searchSuggestions)
        #expect(Preferences.searchSuggestionsEnabled)
        defaults.set(false, forKey: Preferences.Key.searchSuggestions)
        #expect(!Preferences.searchSuggestionsEnabled)
    }

    @Test func suggestionSessionKeepsNoState() {
        let config = SearchSuggestionClient.configuration
        #expect(config.httpCookieStorage == nil && config.urlCache == nil && config.urlCredentialStorage == nil)
        #expect(!config.httpShouldSetCookies && config.httpCookieAcceptPolicy == .never)
        #expect(config.timeoutIntervalForRequest <= 2 && config.timeoutIntervalForResource <= 2)
        #expect((config.httpAdditionalHeaders?["User-Agent"] as? String)?.contains("Lily") == false)
    }

    // MARK: The client, offline (stub URL protocol)

    @Test func clientAcceptsOnlyAPlainAnswerFromTheEngine() async throws {
        let ok = Data(#"["q", ["one", "two"]]"#.utf8)
        func fetch(_ reply: SuggestionStub.Reply) async -> [String] {
            let client = SuggestionStub.client(reply)
            defer { client.close() }
            return (try? await client.suggestions(for: "q", engine: .duckDuckGo)) ?? ["error"]
        }
        #expect(await fetch(.init(body: ok)) == ["one", "two"])
        #expect(await fetch(.init(status: 500, body: ok)) == [])
        #expect(await fetch(.init(body: ok, url: URL(string: "https://evil.example/ac/"))) == []) // another host
        #expect(await fetch(.init(body: ok, url: URL(string: "http://duckduckgo.com/ac/"))) == []) // not https
        #expect(await fetch(.init(headers: ["Content-Length": "70000"], body: ok)) == [])
        // Streamed past 64 KB without a length: cut off. Exactly 64 KB: read.
        let padding = { (count: Int) in #"["q", ["ok"], ""# + String(repeating: "a", count: count) + #""]"# }
        let exact = Data(padding(SearchSuggestions.maxResponseBytes - padding(0).utf8.count).utf8)
        #expect(exact.count == SearchSuggestions.maxResponseBytes)
        #expect(await fetch(.init(body: exact, chunk: 4_096)) == ["ok"])
        #expect(await fetch(.init(body: exact + Data("x".utf8), chunk: 4_096)) == [])
        #expect(await fetch(.init(body: Data([0x5B, 0x22, 0x71, 0x22, 0x2C, 0x5B, 0x22, 0xFF, 0xFE, 0xC3, 0x22, 0x5D, 0x5D]))) == [])
    }

    @Test func clientRefusesRedirects() async throws {
        let client = SuggestionStub.client(.init(body: Data(#"["q", ["redirected"]]"#.utf8),
                                                 redirect: URL(string: "https://duckduckgo.com/elsewhere")))
        defer { client.close() }
        #expect(try await client.suggestions(for: "q", engine: .duckDuckGo) == [])
        #expect(SuggestionStub.requests.compactMap { $0.url?.path(percentEncoded: true) } == ["/ac/"]) // never followed
        #expect(SuggestionStub.requests.first?.value(forHTTPHeaderField: "Cookie") == nil)
    }

    // MARK: The model

    actor FakeFetcher: SearchSuggestionFetching {
        var calls: [String] = []
        let answers: [String: [String]]
        /// Answers for these come only after the next request starts (a slow, late answer).
        let late: Set<String>
        private var waiting: [CheckedContinuation<Void, Never>] = []

        init(_ answers: [String: [String]], late: Set<String> = []) {
            self.answers = answers
            self.late = late
        }

        func suggestions(for query: String, engine: Preferences.SearchEngine) async throws -> [String] {
            calls.append(query)
            for continuation in waiting { continuation.resume() }
            waiting.removeAll()
            if late.contains(query) { await withCheckedContinuation { waiting.append($0) } }
            return answers[query] ?? []
        }

        nonisolated func close() {}
    }

    private func window(isPrivate: Bool = false) -> WindowModel {
        WindowModel(isPrivate: isPrivate, assistant: AssistantChat(assistant: Assistant(configuration: .init())))
    }

    /// A bar wired to `fetcher`, with suggestions on (unless `enabled` is false) and no debounce.
    private func bar(_ model: WindowModel, _ fetcher: FakeFetcher, enabled: Bool = true, query: String = "",
                     newTab: Bool = true, palette: Bool = false) -> CommandBarModel {
        let bar = CommandBarModel(newTab: newTab, query: query, window: model, palette: palette, commands: [])
        bar.suggestionFetcher = fetcher
        bar.suggestionDelay = .zero
        bar.suggestionsEnabled = enabled
        bar.searchEngine = .duckDuckGo
        return bar
    }

    /// Polls (no fixed waits) for up to five seconds.
    private func until(_ condition: () async -> Bool) async {
        for _ in 0..<500 { if await condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func searchRows(_ bar: CommandBarModel) -> [String] {
        bar.suggestions.compactMap { if case .search(let q, _) = $0 { q } else { nil } }
    }

    @Test func showsEngineSuggestionsAfterTheTypedTextWithoutSelectingThem() async {
        let fetcher = FakeFetcher(["swift": ["swift", "swift concurrency", "Swift UI"]])
        let model = window() // the bar holds its window weakly
        let bar = bar(model, fetcher)
        bar.userEdited("swift", typing: true)
        await bar.engineTask?.value
        #expect(searchRows(bar) == ["swift", "swift concurrency", "Swift UI"]) // the typed text isn't repeated
        #expect(bar.selection == 0)
        // Retyping the same text uses the bar's cache.
        bar.userEdited("swif", typing: false)
        bar.userEdited("swift", typing: true)
        #expect(bar.engineTask == nil)
        #expect(searchRows(bar).count == 3)
        #expect(await fetcher.calls.filter { $0 == "swift" }.count == 1)
    }

    @Test func dropsLateAnswersForOldText() async {
        let fetcher = FakeFetcher(["a": ["a old"], "ab": ["ab new"]], late: ["a"])
        let model = window()
        let bar = bar(model, fetcher)
        bar.userEdited("a", typing: true)
        let first = bar.engineTask
        await until { await fetcher.calls == ["a"] }
        bar.userEdited("ab", typing: true) // cancels "a"; its answer comes after "ab" is asked
        await bar.engineTask?.value
        await first?.value
        #expect(await fetcher.calls == ["a", "ab"])
        #expect(searchRows(bar) == ["ab", "ab new"])
    }

    @Test func aLateAnswerKeepsTheSelectedRow() async {
        let fetcher = FakeFetcher(["swift": ["swift ui", "swift testing"]], late: ["swift"])
        let model = window()
        model.tabs = [WindowModel.TabItem(id: UUID(), title: "Swift forums", url: URL(string: "https://forums.swift.org/"), favicon: nil,
                                          isLoading: false, isPinned: false, isYouTubeVideo: false, inSplit: false)]
        let bar = bar(model, fetcher)
        bar.userEdited("swift", typing: true)
        let pending = bar.engineTask
        await until { await fetcher.calls == ["swift"] }
        bar.moveSelection(1) // the tab row
        let picked = bar.suggestions[bar.selection]
        #expect({ if case .tab = picked { true } else { false } }())
        _ = try? await fetcher.suggestions(for: "release", engine: .duckDuckGo) // lets "swift" answer
        await pending?.value
        #expect(searchRows(bar).count == 3)
        #expect(bar.suggestions[bar.selection] == picked)
    }

    @Test func sendsNothingWhenOffInPrivateOrForAddresses() {
        for (on, isPrivate, text) in [(false, false, "swift"), (true, true, "swift"), (true, false, "github.com"), (true, false, "me@x.org"),
                                      (true, false, "foo https://site/x?token=1")] {
            let fetcher = FakeFetcher(["swift": ["swift ui"]])
            let model = window(isPrivate: isPrivate)
            let bar = bar(model, fetcher, enabled: on)
            bar.userEdited(text, typing: true)
            #expect(bar.engineTask == nil, "\(text)") // nothing scheduled, so nothing can be sent
        }
    }

    @Test func aPrefilledAddressSendsNothing() async {
        let fetcher = FakeFetcher([:])
        let model = window()
        // ⌘L: the bar opens with the page's address.
        let bar = bar(model, fetcher, query: "https://site.example/x?token=1", newTab: false)
        #expect(bar.engineTask == nil)
        #expect(!bar.suggestions.isEmpty)
        bar.userEdited("foo https://site.example/x?token=1", typing: true)
        #expect(bar.engineTask == nil)
        bar.userEdited("https://site.example/x?token=12", typing: true)
        #expect(bar.engineTask == nil)
        #expect(await fetcher.calls.isEmpty)
    }

    @Test func thePaletteNeitherCompletesNorFetches() async {
        let fetcher = FakeFetcher(["git": ["git rebase"]])
        let model = window()
        model.tabs = [WindowModel.TabItem(id: UUID(), title: "GitHub", url: URL(string: "https://github.com/"), favicon: nil,
                                          isLoading: false, isPinned: false, isYouTubeVideo: false, inSplit: false)]
        let bar = bar(model, fetcher, newTab: false, palette: true)
        await until { bar.localIndex != nil }
        bar.userEdited("git", typing: true)
        #expect(bar.completion == nil)
        #expect(bar.engineTask == nil)
        #expect(await fetcher.calls.isEmpty)
    }

    @Test func completionLeadsTheListAndBackspaceRemovesIt() async throws {
        let model = window()
        model.tabs = [WindowModel.TabItem(id: UUID(), title: "GitHub", url: URL(string: "https://github.com/pwngoblin"), favicon: nil,
                                          isLoading: false, isPinned: false, isYouTubeVideo: false, inSplit: false)]
        let bar = bar(model, FakeFetcher([:]), enabled: false)
        await until { bar.localIndex != nil }
        bar.userEdited("gi", typing: true)
        let completion = try #require(bar.completion)
        #expect(bar.displayText == "github.com")
        #expect(bar.suggestions.first == .open(completion.url))
        #expect(bar.selection == 0)
        bar.removeCompletion() // Delete or Esc
        #expect(bar.displayText == "gi")
        bar.userEdited("gi", typing: false)
        #expect(bar.completion == nil)
        bar.userEdited("git", typing: true)
        #expect(bar.displayText == "github.com")
        bar.acceptCompletion() // → or End
        #expect(bar.query == "github.com" && bar.completion == nil)
        // Never completes a search phrase.
        bar.userEdited("git hub", typing: true)
        #expect(bar.completion == nil)
    }

    @Test func emptyBarSelectsNothing() {
        let model = window() // the bar holds its window weakly
        let bar = bar(model, FakeFetcher([:]))
        #expect(bar.selection == -1) // Return with nothing typed opens nothing
        bar.query = "x"
        #expect(bar.selection == 0)
    }
}

/// Answers the suggestion client's requests in-process (no network). Used by one serialized suite.
final class SuggestionStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// The response's URL (default: the request's).
        var url: URL?
        var redirect: URL?
        /// Deliver the body in pieces of this size (0: at once).
        var chunk = 0
    }

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var reply = Reply()
        var requests: [URLRequest] = []
    }
    private static let box = Box()

    static var requests: [URLRequest] { box.lock.withLock { box.requests } }

    static func client(_ reply: Reply) -> SearchSuggestionClient {
        box.lock.withLock {
            box.reply = reply
            box.requests = []
        }
        let config = SearchSuggestionClient.configuration
        config.protocolClasses = [SuggestionStub.self]
        return SearchSuggestionClient(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.box.lock.withLock {
            Self.box.requests.append(request)
            return Self.box.reply
        }
        guard let requested = request.url else { return }
        if let redirect = reply.redirect, redirect != requested,
           let response = HTTPURLResponse(url: requested, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": redirect.absoluteString]) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard let response = HTTPURLResponse(url: reply.url ?? requested, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                             headerFields: reply.headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if reply.chunk > 0 {
            var offset = 0
            while offset < reply.body.count {
                client?.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<min(offset + reply.chunk, reply.body.count)))
                offset += reply.chunk
            }
        } else {
            client?.urlProtocol(self, didLoad: reply.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
