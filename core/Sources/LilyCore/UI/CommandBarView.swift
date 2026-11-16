import SwiftUI

/// State for the centered command bar: open or search (⌘T / ⌘L), or the command palette (⌘K),
/// which also runs browser commands, switches spaces and opens extensions. In the palette, a
/// leading ">" shows commands only.
@MainActor @Observable
final class CommandBarModel: Identifiable {
    enum Suggestion: Identifiable, Equatable {
        case open(URL)
        case search(String, engine: String)
        case tab(id: UUID, title: String, url: URL?)
        case history(title: String, url: URL)
        case bookmark(title: String, url: URL)
        case command(PaletteCommand)

        var id: String {
            switch self {
            case .open(let url): return "open:\(url.absoluteString)"
            case .search(let q, _): return "search:\(q)"
            case .tab(let id, _, _): return "tab:\(id.uuidString)"
            case .history(_, let url): return "history:\(url.absoluteString)"
            case .bookmark(_, let url): return "bookmark:\(url.absoluteString)"
            case .command(let command): return command.id
            }
        }
    }

    let id = UUID()
    let newTab: Bool
    let isPalette: Bool
    /// What the user typed (without an inline completion).
    var query: String {
        didSet {
            completion = nil
            selection = defaultSelection
        }
    }
    var selection = 0
    /// The inline completion showing in the field (typed text + selected rest), if any.
    private(set) var completion: AddressCompletion.Completion?
    /// The last engine suggestions received, and the text they were for.
    private(set) var engineResults: (query: String, items: [String])?
    /// History, bookmarks and open tabs by frecency; built off the main actor when the bar opens.
    private(set) var localIndex: AddressCompletion.Index?
    @ObservationIgnored private weak var window: WindowModel?
    /// Read once when the palette opens (menu validation isn't free), not per keystroke.
    @ObservationIgnored private let commands: [PaletteCommand]
    /// SwiftUI reads `suggestions` several times per keystroke; history and bookmark search run once.
    @ObservationIgnored private var cached: (key: CacheKey, suggestions: [Suggestion])?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    /// The pending engine request (debounce + fetch); nil when nothing is to be sent.
    @ObservationIgnored private(set) var engineTask: Task<Void, Never>?
    /// Recent engine answers by engine and query, so retyping or deleting doesn't ask again. Gone with the bar.
    @ObservationIgnored private var engineCache: [String: [String]] = [:]
    @ObservationIgnored private var engineCacheOrder: [String] = []
    /// Made on the first request, closed with the bar (a fresh connection per opening).
    @ObservationIgnored var suggestionFetcher: (any SearchSuggestionFetching)?
    /// Settings → Privacy → Search engine suggestions and the engine, read when the bar opens.
    @ObservationIgnored var suggestionsEnabled: Bool
    @ObservationIgnored var searchEngine: Preferences.SearchEngine
    /// Waits this long after a keystroke before asking the engine (typing on cancels the request).
    @ObservationIgnored var suggestionDelay: Duration = .milliseconds(120)
    static let engineCacheSize = 24
    static let maxRows = 10

    private struct CacheKey: Equatable {
        let query: String
        let completion: String?
        let engine: String?
        let indexed: Bool
    }

    /// `commands`: the palette's commands (read from the live menus when nil).
    init(newTab: Bool, query: String, window: WindowModel, palette: Bool = false, commands: [PaletteCommand]? = nil) {
        self.newTab = newTab
        self.query = query
        self.window = window
        isPalette = palette
        self.commands = palette ? (commands ?? PaletteCommands.all(in: window)) : []
        suggestionsEnabled = Preferences.searchSuggestionsEnabled
        searchEngine = Preferences.searchEngine
        selection = defaultSelection
        buildIndex()
    }

    /// Nothing is selected in the empty bar's list of top sites: Return with nothing typed
    /// shouldn't open a site you didn't pick.
    private var defaultSelection: Int { query.isEmpty && !isPalette ? -1 : 0 }

    /// What the field shows.
    var displayText: String { completion?.text ?? query }

    var suggestions: [Suggestion] {
        let key = CacheKey(query: query, completion: completion?.text, engine: engineResults?.query, indexed: localIndex != nil)
        if let cached, cached.key == key { return cached.suggestions }
        let result = computeSuggestions()
        cached = (key, result)
        return result
    }

    /// Stops background work; the bar is going away.
    func close() {
        indexTask?.cancel()
        engineTask?.cancel()
        engineTask = nil
        engineCache.removeAll()
        engineCacheOrder.removeAll()
        suggestionFetcher?.close()
        suggestionFetcher = nil
    }

    // MARK: Typing

    /// The field's text changed. `typing`: characters were added at the end (not deleted), so an
    /// inline completion may be offered.
    func userEdited(_ text: String, typing: Bool) {
        query = text
        if typing, !isPalette, let localIndex { completion = AddressCompletion.complete(text, in: localIndex) }
        fetchEngineSuggestions()
    }

    func removeCompletion() { completion = nil }

    /// → / End: the completed text becomes the typed text.
    func acceptCompletion() {
        guard let completion else { return }
        query = completion.text
        fetchEngineSuggestions()
    }

    // MARK: Local index

    private func buildIndex() {
        guard let window else { return }
        let tabs = window.tabs.compactMap(\.url)
        let history = window.controller?.history
        let bookmarks = window.controller?.bookmarks
        let visits = history?.visits ?? []
        let bookmarked = window.isPrivate ? [] : (bookmarks?.links.compactMap(\.url) ?? [])
        guard !visits.isEmpty || !bookmarked.isEmpty || !tabs.isEmpty else { return }
        indexTask = Task { [weak self] in
            let index = await Task.detached(priority: .userInitiated) {
                AddressCompletion.index(visits: visits.map { AddressCompletion.Visit(url: $0.url, title: $0.title, date: $0.visitedAt) },
                                        bookmarks: bookmarked, tabs: tabs, now: Date())
            }.value
            guard !Task.isCancelled, let self else { return }
            self.localIndex = index
        }
    }

    // MARK: Engine suggestions

    private func fetchEngineSuggestions() {
        engineTask?.cancel()
        engineTask = nil
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let engine = searchEngine
        guard !isPalette, let window,
              SearchSuggestions.shouldFetch(q, engine: engine, enabled: suggestionsEnabled,
                                            isPrivate: window.isPrivate, resolver: Preferences.urlResolver) else { return }
        let key = engine.rawValue + "\n" + q.lowercased()
        if let hit = engineCache[key] {
            engineResults = (q, hit)
            return
        }
        let fetcher: any SearchSuggestionFetching = suggestionFetcher ?? SearchSuggestionClient()
        suggestionFetcher = fetcher
        let delay = suggestionDelay
        engineTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let items: [String]
            do {
                items = try await fetcher.suggestions(for: q, engine: engine)
            } catch {
                if !Task.isCancelled { Log.app.debug("Search suggestions unavailable: \((error as? URLError)?.code.rawValue ?? -1, privacy: .public)") }
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.rememberEngineResults(items, for: key)
            // A late answer for text that's since changed is dropped.
            guard self.query.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
            self.showEngineResults(q, items)
        }
    }

    /// New rows arrive under what you typed; a row you moved to stays selected (or row 0 if it's
    /// gone), so a late answer never changes what Return opens.
    private func showEngineResults(_ q: String, _ items: [String]) {
        let selected = selection > 0 ? suggestions[safe: selection]?.id : nil
        engineResults = (q, items)
        if let selected { selection = suggestions.firstIndex { $0.id == selected } ?? 0 }
    }

    private func rememberEngineResults(_ items: [String], for key: String) {
        if engineCache.updateValue(items, forKey: key) == nil { engineCacheOrder.append(key) }
        if engineCacheOrder.count > Self.engineCacheSize { engineCache[engineCacheOrder.removeFirst()] = nil }
    }

    /// Engine suggestions to show for `q`: the answer for this text, or, while the next one is on
    /// its way, those from the last answer that still start with what's typed (no flicker).
    private func engineSuggestions(for q: String) -> [String] {
        guard let engineResults, let window,
              SearchSuggestions.shouldFetch(q, engine: searchEngine, enabled: suggestionsEnabled, isPrivate: window.isPrivate,
                                            resolver: Preferences.urlResolver) else { return [] }
        let lower = q.lowercased()
        let items = engineResults.query.lowercased() == lower ? engineResults.items
            : engineResults.items.filter { $0.lowercased().hasPrefix(lower) }
        return items.filter { $0.lowercased() != lower }
    }

    // MARK: Suggestions

    /// Commands matching `query`, best first (all of them, in menu order, for an empty query).
    private func matchingCommands(_ query: String, limit: Int) -> [Suggestion] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return commands.prefix(limit).map(Suggestion.command) }
        return commands.enumerated()
            .compactMap { index, command in command.score(words).map { (score: $0, index: index, command: command) } }
            .sorted { ($0.score, $0.index) < ($1.score, $1.index) }
            .prefix(limit).map { .command($0.command) }
    }

    /// The empty bar: most visited sites (open tabs only in private windows).
    private func emptySuggestions(_ window: WindowModel) -> [Suggestion] {
        let current = window.activeTab?.url
        if window.isPrivate || window.controller?.history == nil {
            return window.tabs.filter { $0.id != window.activeID }.prefix(6).map { .tab(id: $0.id, title: $0.title, url: $0.url) }
        }
        guard let localIndex else { return [] }
        return AddressCompletion.topSites(localIndex, excluding: current, limit: 6)
            .map { .history(title: $0.title.isEmpty ? $0.display : $0.title, url: $0.url) }
    }

    private func computeSuggestions() -> [Suggestion] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if isPalette, q.hasPrefix(">") || q.isEmpty {
            return matchingCommands(String(q.dropFirst(q.hasPrefix(">") ? 1 : 0)).trimmingCharacters(in: .whitespaces), limit: 60)
        }
        guard let window else { return [] }
        guard !q.isEmpty else { return isPalette ? [] : emptySuggestions(window) }
        var out: [Suggestion] = []
        let resolver = Preferences.urlResolver
        if let completion {
            out.append(.open(completion.url))
        } else if let url = resolver.resolve(q), url.absoluteString != resolver.searchURL(for: q)?.absoluteString {
            out.append(.open(url))
        }
        out.append(.search(q, engine: Preferences.searchEngine.displayName))
        let fixed = out.count
        var local: [Suggestion] = []
        let needle = q.lowercased()
        let scores = localIndex?.pageScores ?? [:]
        let score = { (url: URL) in scores[url] ?? 0 }
        let tabs = window.tabs.filter { $0.id != window.activeID || newTab }
            .filter { $0.title.lowercased().contains(needle) || ($0.url?.absoluteString.lowercased().contains(needle) ?? false) }
        local += AddressCompletion.rank(tabs, url: \.url, query: q, score: score)
            .prefix(4).map { .tab(id: $0.id, title: $0.title, url: $0.url) }
        var shown = Set(local.compactMap { if case .tab(_, _, let url) = $0 { url } else { nil } })
        if let completion { shown.insert(completion.url) }
        if let bookmarks = window.controller?.bookmarks {
            let links = bookmarks.search(q, limit: 12).filter { $0.url.map { !shown.contains($0) } ?? false }
            for link in AddressCompletion.rank(links, url: \.url, query: q, score: score).prefix(3) {
                local.append(.bookmark(title: link.title.isEmpty ? link.url!.absoluteString : link.title, url: link.url!))
                shown.insert(link.url!)
            }
        }
        if let history = window.controller?.history {
            let visits = history.search(q, limit: 60).filter { !shown.contains($0.url) }
            for visit in AddressCompletion.rank(visits, url: \.url, query: q, score: score).prefix(Self.maxRows) {
                local.append(.history(title: visit.title.isEmpty ? visit.url.absoluteString : visit.title, url: visit.url))
            }
        }
        // Engine suggestions after what was typed, before pages, leaving room for a few pages.
        let engine = engineSuggestions(for: q).filter { $0.lowercased() != needle }
        let engineRoom = max(0, Self.maxRows - fixed - min(local.count, 3))
        out += engine.prefix(min(SearchSuggestions.maxSuggestions, engineRoom)).map { .search($0, engine: Preferences.searchEngine.displayName) }
        out += local.prefix(max(0, Self.maxRows - out.count))
        // Commands that match go right after "open" and "search", ahead of pages.
        if isPalette { out.insert(contentsOf: matchingCommands(q, limit: 3), at: min(out.count, fixed)) }
        return out
    }

    func moveSelection(_ delta: Int) {
        let count = suggestions.count
        guard count > 0 else { return }
        selection = selection < 0 ? (delta > 0 ? 0 : count - 1) : (selection + delta + count) % count
    }

    func commit(_ suggestion: Suggestion? = nil) {
        guard let window, let controller = window.controller else { return }
        let pick = suggestion ?? suggestions[safe: selection]
        switch pick {
        case .tab(let id, _, _):
            controller.tabs.activate(id)
        case .open(let url), .history(_, let url), .bookmark(_, let url):
            controller.open(url, newTab: newTab)
        case .search(let q, _):
            if let url = Preferences.urlResolver.searchURL(for: q) { controller.open(url, newTab: newTab) }
        case .command(let command):
            Haptics.tap()
            window.dismissCommandBar()
            command.perform(in: window)
            return
        case nil:
            return
        }
        Haptics.tap()
        window.dismissCommandBar()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Large, centered "open anything" bar over the whole window, like Spotlight.
struct CommandBarOverlay: View {
    @Bindable var window: WindowModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .top) {
            if let bar = window.commandBar {
                backdrop
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { window.dismissCommandBar() }
                    .transition(.opacity)
                CommandBarCard(bar: bar, dismiss: { window.dismissCommandBar() })
                    .padding(.top, 96)
                    .transition(.asymmetric(insertion: .scale(scale: 0.94, anchor: .top).combined(with: .opacity),
                                            removal: .scale(scale: 0.97, anchor: .top).combined(with: .opacity)))
                    .id(bar.id)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: window.commandBar?.id)
        .appAccent()
    }

    /// The page and sidebar behind the bar, softly blurred and a little dimmed; just dimmed with
    /// Reduce Transparency (where a material would turn opaque and hide the page).
    @ViewBuilder private var backdrop: some View {
        if reduceTransparency {
            Color.black.opacity(0.18)
        } else {
            ZStack {
                WindowBackdropBlur()
                Color.black.opacity(0.10)
            }
        }
    }
}

/// Blurs whatever the window draws below it (the web page, the sidebar). An AppKit visual effect
/// view blending *within the window* is used rather than a SwiftUI material: it blurs the
/// window's own layers, web views included, wherever this hosting view sits above them.
/// It never takes clicks, so the dim layer above it can close the bar.
private struct WindowBackdropBlur: NSViewRepresentable {
    final class BlurView: NSVisualEffectView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> BlurView {
        let view = BlurView()
        view.blendingMode = .withinWindow
        view.material = .fullScreenUI
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: BlurView, context: Context) {}
}

private struct CommandBarCard: View {
    @Bindable var bar: CommandBarModel
    let dismiss: () -> Void

    private var placeholder: String {
        bar.isPalette ? "Search tabs, history and bookmarks, or type > for commands"
            : bar.newTab ? "Search or enter address" : "Search or enter address to open here"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: bar.isPalette ? "command" : bar.newTab ? "plus.magnifyingglass" : "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)
                CommandBarTextField(bar: bar, placeholder: placeholder, dismiss: dismiss)
                    .frame(maxWidth: .infinity)
                if !bar.query.isEmpty {
                    Button { bar.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 64)

            let suggestions = bar.suggestions
            if !suggestions.isEmpty {
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                                SuggestionRow(suggestion: suggestion, selected: index == bar.selection)
                                    .contentShape(Rectangle())
                                    .onTapGesture { bar.commit(suggestion) }
                                    .onHover { if $0 { bar.selection = index } }
                                    .id(index)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 460)
                    .scrollBounceBehavior(.basedOnSize)
                    .onChange(of: bar.selection) { _, index in if index >= 0 { proxy.scrollTo(index) } }
                }
            }
        }
        .frame(width: 680)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.28), radius: 40, y: 18)
    }
}

private struct SuggestionRow: View {
    let suggestion: CommandBarModel.Suggestion
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).font(.system(size: 14, weight: .medium))
                if let subtitle { Text(subtitle).lineLimit(1).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let badge { Text(badge).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            if selected { Image(systemName: "return").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(selected ? AnyShapeStyle(.selection.opacity(0.55)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var icon: some View {
        switch suggestion {
        case .open: Image(systemName: "globe").foregroundStyle(.secondary)
        case .search: Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        case .tab(_, _, let url): FaviconView(page: url, size: 18) // may be asleep: kept icons only
        case .history: Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
        case .bookmark: Image(systemName: "bookmark.fill").foregroundStyle(.tint)
        case .command(let command): Image(systemName: command.symbol).foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch suggestion {
        case .open(let url): return url.absoluteString
        case .search(let q, _): return q
        case .tab(_, let title, _), .history(let title, _), .bookmark(let title, _): return title
        case .command(let command): return command.title
        }
    }

    private var subtitle: String? {
        switch suggestion {
        case .tab(_, _, let url): return url?.host
        case .history(_, let url), .bookmark(_, let url): return url.absoluteString
        case .command(let command): return command.path.isEmpty ? nil : command.path
        default: return nil
        }
    }

    private var badge: String? {
        switch suggestion {
        case .open: return "Open"
        case .search(_, let engine): return "Search \(engine)"
        case .tab: return "Switch to Tab"
        case .history: return "History"
        case .bookmark: return "Bookmark"
        case .command(let command): return command.shortcut ?? "Command"
        }
    }
}

extension URL {
    /// `/favicon.ico` on the same origin, for places that have no page-reported icon.
    var faviconGuess: URL? {
        guard let scheme, scheme.hasPrefix("http"), let host else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }
}
