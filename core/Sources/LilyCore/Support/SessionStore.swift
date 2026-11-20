import Foundation

/// Persists the window session (open tabs, spaces and split groups) encrypted at rest; see `SealedFile`. Tab URLs can carry
/// tokens in their query strings, so they never touch disk in plaintext.
public actor SessionStore {
    public struct Session: Codable, Sendable, Equatable {
        public struct Entry: Codable, Sendable, Equatable {
            public var url: URL
            public var title: String
            public var pinned: Bool
            /// Security-scoped bookmark for file:// tabs; without it the sandbox can't reopen them.
            public var bookmark: Data?
            public var space: UUID?

            public init(url: URL, title: String, pinned: Bool, bookmark: Data? = nil, space: UUID? = nil) {
                self.url = url
                self.title = title
                self.pinned = pinned
                self.bookmark = bookmark
                self.space = space
            }
        }

        /// A split group, by position in `tabs`.
        public struct SavedSplit: Codable, Sendable, Equatable {
            public var layout: SplitLayout
            /// Indices into `Session.tabs`, in pane order.
            public var tabs: [Int]
            public var scrollLinked: Bool

            public init(layout: SplitLayout, tabs: [Int], scrollLinked: Bool = false) {
                self.layout = layout
                self.tabs = tabs
                self.scrollLinked = scrollLinked
            }

            private enum CodingKeys: String, CodingKey { case layout, tabs, scrollLinked }

            /// A layout this version doesn't know (saved by a newer Lily) falls back to one that fits
            /// the members, instead of failing the whole session's decoding.
            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                tabs = try container.decode([Int].self, forKey: .tabs)
                scrollLinked = try container.decodeIfPresent(Bool.self, forKey: .scrollLinked) ?? false
                let raw = try container.decodeIfPresent(String.self, forKey: .layout) ?? ""
                layout = SplitLayout(rawValue: raw) ?? (tabs.count >= 4 ? .grid : tabs.count == 3 ? .threeColumns : .twoColumns)
            }
        }

        public var tabs: [Entry]
        public var activeIndex: Int?
        public var spaces: [Space]?
        public var currentSpace: UUID?
        /// Optional so sessions saved before split groups were kept still decode.
        public var splits: [SavedSplit]?

        public init(tabs: [Entry], activeIndex: Int? = nil, spaces: [Space]? = nil, currentSpace: UUID? = nil, splits: [SavedSplit]? = nil) {
            self.tabs = tabs
            self.activeIndex = activeIndex
            self.spaces = spaces
            self.currentSpace = currentSpace
            self.splits = splits
        }

        private enum CodingKeys: String, CodingKey { case tabs, activeIndex, spaces, currentSpace, splits }

        /// Split groups decode one by one: a malformed group is dropped (as is a malformed list of
        /// them), never the whole session, since a session that fails to decode is deleted.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            tabs = try container.decode([Entry].self, forKey: .tabs)
            activeIndex = try container.decodeIfPresent(Int.self, forKey: .activeIndex)
            spaces = try container.decodeIfPresent([Space].self, forKey: .spaces)
            currentSpace = try container.decodeIfPresent(UUID.self, forKey: .currentSpace)
            let lossy = try? container.decodeIfPresent([Lossy<SavedSplit>].self, forKey: .splits)
            splits = lossy.map { $0.compactMap(\.value) }
        }

        /// One element that decodes to nil instead of failing its array.
        private struct Lossy<Value: Decodable>: Decodable {
            let value: Value?
            init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
        }
    }

    private let file: SealedFile
    /// Plaintext session.json written by 0.1.0; migrated on first load, then deleted.
    private let legacyURL: URL
    /// What the sealed file holds now. Titles and loading states change the window every few
    /// hundred milliseconds while pages load; the saved session usually doesn't, so an unchanged
    /// session isn't encrypted and rewritten again.
    /// Bumped by clear(), so a save that was writing during it doesn't mark its session saved.
    private var clears = 0
    private var saved: Session?

    public init(directory: URL, keys: KeyStore = KeychainKeyStore()) {
        file = SealedFile(url: directory.appendingPathComponent("session.sealed"), keyName: "session",
                          purpose: "dev.lily.session.v1", keys: keys)
        legacyURL = directory.appendingPathComponent("session.json")
    }

    public func load() async -> Session? {
        saved = nil
        do {
            if let data = try await file.read() {
                let session = try JSONDecoder().decode(Session.self, from: data)
                saved = session
                return session
            }
        } catch {
            // Unreadable (tampered, or the key was removed): start fresh rather than fail launch. The old
            // plaintext file is not a fallback: it has no authentication, so it would bypass the seal.
            Log.app.error("Session could not be decrypted; discarding it: \(String(describing: error), privacy: .public)")
            file.deleteCorrupt()
            try? FileManager.default.removeItem(at: legacyURL)
            return nil
        }
        guard let legacy = try? Data(contentsOf: legacyURL), let session = try? JSONDecoder().decode(Session.self, from: legacy) else { return nil }
        await save(session)
        try? FileManager.default.removeItem(at: legacyURL)
        return session
    }

    public func save(_ session: Session) async {
        guard session != saved else { return }
        let ticket = file.reserve() // a clear() during the write wins
        let generation = clears
        do {
            try await file.write(JSONEncoder().encode(session), ticket: ticket)
            if clears == generation { saved = session }
        } catch {
            Log.app.error("Session save failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func clear() {
        clears += 1
        saved = nil
        file.delete()
        try? FileManager.default.removeItem(at: legacyURL)
    }
}
