import Foundation
import Testing
@testable import LilyCore

/// Settings → Appearance / Tabs / General customization: defaults match how Lily behaved before
/// the settings existed, zoom steps, tab-close selection and the reset.
@Suite(.serialized) @MainActor struct CustomizationTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func makeStore() throws -> TabStore {
        let registry = try ScriptRegistry(manifestURL: Self.root.appendingPathComponent("injections/manifest.json"))
        return TabStore(factory: WebViewFactory(registry: registry, dataStore: .nonPersistent()), router: IPCRouter())
    }

    /// A throwaway defaults domain, so nothing here touches the real settings.
    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "dev.lily.tests.customization.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    // MARK: Defaults

    @Test func unsetChoicesReadAsTodaysBehaviour() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(SidebarPosition.current(AppearanceStyle.Key.sidebarPosition, in: defaults) == .left)
        #expect(InterfaceFont.current(AppearanceStyle.Key.interfaceFont, in: defaults) == .system)
        #expect(TabDensity.current(AppearanceStyle.Key.tabDensity, in: defaults) == .standard)
        #expect(CloseButtonVisibility.current(AppearanceStyle.Key.closeButton, in: defaults) == .hover)
        #expect(CommandBarBlur.current(AppearanceStyle.Key.commandBarBlur, in: defaults) == .light)
        #expect(CommandBarPosition.current(AppearanceStyle.Key.commandBarPosition, in: defaults) == .top)
        #expect(CommandBarWidth.current(AppearanceStyle.Key.commandBarWidth, in: defaults).points == 680)
        #expect(CommandBarPosition.topInset == 96)
        #expect(NewTabAction.current(Preferences.Key.newTabAction, in: defaults) == .commandBar)
        #expect(SidebarTextSize.current(AppearanceStyle.Key.sidebarTextSize, in: defaults) == .medium)
        #expect(TabStore.AfterClose(stored: nil) == .lastUsed)
        #expect(PinnedColumns.clamped(defaults.integer(forKey: AppearanceStyle.Key.pinnedColumns)) == PinnedColumns.automatic)

        // Today's page cards: 10 pt corners, 8 pt margin, 2 pt next to the sidebar on the left.
        let page = PageStyle.current(defaults)
        #expect(page.cornerRadius == 10 && page.padding == 8 && !page.sidebarOnRight)
        #expect(page.leading == 2 && page.trailing == 8)

        // A row is exactly as tall as before the density setting.
        let row = SidebarRowStyle()
        #expect(row.rowHeight == SidebarTextSize.medium.rowHeight && row.dimsSleepingTabs && row.closeButton == .hover)
    }

    @Test func unknownStoredValuesFallBackToDefaults() {
        #expect(SidebarPosition(stored: "upside-down") == .left)
        #expect(CommandBarWidth(stored: "") == .standard)
        #expect(PinnedColumns.clamped(7) == PinnedColumns.automatic && PinnedColumns.clamped(3) == 3)
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(99.0, forKey: AppearanceStyle.Key.pageCornerRadius)
        defaults.set(-4.0, forKey: AppearanceStyle.Key.pagePadding)
        defaults.set(SidebarPosition.right.rawValue, forKey: AppearanceStyle.Key.sidebarPosition)
        let page = PageStyle.current(defaults)
        #expect(page.cornerRadius == 16 && page.padding == 0) // clamped to the sliders' ranges
        #expect(page.sidebarOnRight && page.leading == 0 && page.trailing == 0)
    }

    @Test func behaviourPreferencesDefaultToTodaysBehaviour() {
        let keys = [Preferences.Key.searchSuggestionRows, Preferences.Key.linksOpenInBackground,
                    Preferences.Key.swipeBetweenSpaces, Preferences.Key.confirmBeforeQuitting]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        #expect(Preferences.searchSuggestionRows == 5)
        #expect(Preferences.linksOpenInBackground) // Safari's (and Lily's) ⌘-click
        #expect(Preferences.swipesBetweenSpaces)
        #expect(!Preferences.confirmsBeforeQuitting)
        UserDefaults.standard.set(12, forKey: Preferences.Key.searchSuggestionRows)
        #expect(Preferences.searchSuggestionRows == 5)
        UserDefaults.standard.set(0, forKey: Preferences.Key.searchSuggestionRows)
        #expect(Preferences.searchSuggestionRows == 0)
    }

    @Test func closeButtonVisibility() {
        #expect(CloseButtonVisibility.hover.shows(hovering: true) && !CloseButtonVisibility.hover.shows(hovering: false))
        #expect(CloseButtonVisibility.always.shows(hovering: false))
        #expect(!CloseButtonVisibility.never.shows(hovering: true))
    }

    @Test func densityChangesRowHeightOnTopOfTextSize() {
        let compact = SidebarRowStyle(textSize: .small, density: .compact)
        let spacious = SidebarRowStyle(textSize: .large, density: .spacious)
        #expect(compact.rowHeight < SidebarTextSize.small.rowHeight)
        #expect(spacious.rowHeight > SidebarTextSize.large.rowHeight)
    }

    @Test func pinnedColumnsFollowTheChoice() {
        #expect(PinnedTabsView.columns(width: 240) == PinnedTabsView.columns(width: 240, fixedColumns: PinnedColumns.automatic))
        #expect(PinnedTabsView.columns(width: 240, fixedColumns: 2) == 2)
        // 7 tiles in 3 columns: 3 rows.
        #expect(PinnedTabsView.height(count: 7, width: 240, fixedColumns: 3) == 3 * PinnedTabsView.tileHeight + 2 * PinnedTabsView.spacing)
    }

    // MARK: Zoom

    @Test func zoomLevelsAreOneSortedSafariLikeList() {
        let levels = SiteSettings.zoomLevels
        #expect(levels == [0.5, 0.67, 0.75, 0.85, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0])
        #expect(levels == levels.sorted() && Set(levels).count == levels.count && levels.contains(1.0))
    }

    @Test func zoomStepsFromLevelsAndBetweenThem() {
        // On the list: one level each way.
        #expect(SiteSettings.zoomLevel(after: 1.0, zoomingIn: true) == 1.1)
        #expect(SiteSettings.zoomLevel(after: 1.0, zoomingIn: false) == 0.9)
        #expect(SiteSettings.zoomLevel(after: 0.75, zoomingIn: false) == 0.67)
        #expect(SiteSettings.zoomLevel(after: 0.67, zoomingIn: false) == 0.5)
        // WebKit reports a level back with float noise.
        #expect(SiteSettings.zoomLevel(after: 0.6700001, zoomingIn: true) == 0.75)
        // Off the list (the old ±10% steps, a stored site zoom): the next level in that direction.
        #expect(SiteSettings.zoomLevel(after: 1.2, zoomingIn: true) == 1.25)
        #expect(SiteSettings.zoomLevel(after: 1.2, zoomingIn: false) == 1.1)
        #expect(SiteSettings.zoomLevel(after: 0.6, zoomingIn: false) == 0.5)
        #expect(SiteSettings.zoomLevel(after: 0.6, zoomingIn: true) == 0.67)
    }

    @Test func zoomClampsAtTheEnds() {
        #expect(SiteSettings.zoomLevel(after: 0.5, zoomingIn: false) == 0.5)
        #expect(SiteSettings.zoomLevel(after: 3.0, zoomingIn: true) == 3.0)
        #expect(SiteSettings.zoomLevel(after: 2.5, zoomingIn: true) == 3.0)
        // Beyond the list (an older 30% zoom): never jumps the wrong way.
        #expect(SiteSettings.zoomLevel(after: 0.3, zoomingIn: false) == 0.3)
        #expect(SiteSettings.zoomLevel(after: 0.3, zoomingIn: true) == 0.5)
        #expect(SiteSettings.isZoomLimit(0.5) && SiteSettings.isZoomLimit(3.0) && !SiteSettings.isZoomLimit(1.0))
    }

    // MARK: Closing tabs

    @Test func closingTheActiveTabFollowsTheChosenMode() throws {
        let store = try makeStore()
        let a = store.create(url: nil, nextToActive: false)
        let b = store.create(url: nil, nextToActive: false)
        let c = store.create(url: nil, nextToActive: false)
        let d = store.create(url: nil, nextToActive: false)

        // Last used: a was used after d, so closing c (active) goes to a.
        store.activate(d.id)
        store.activate(a.id)
        store.activate(c.id)
        store.close(c.id, then: .lastUsed)
        #expect(store.activeID == a.id)

        // Below: b → d (c is gone).
        store.activate(b.id)
        store.close(b.id, then: .below)
        #expect(store.activeID == d.id)

        // Below from the last tab: the one above.
        store.close(d.id, then: .below)
        #expect(store.activeID == a.id)
    }

    @Test func closingAboveAndAtTheTop() throws {
        let store = try makeStore()
        let a = store.create(url: nil, nextToActive: false)
        let b = store.create(url: nil, nextToActive: false)
        let c = store.create(url: nil, nextToActive: false)
        store.activate(c.id)
        store.close(c.id, then: .above)
        #expect(store.activeID == b.id)
        store.activate(a.id)
        store.close(a.id, then: .above) // nothing above: the one below
        #expect(store.activeID == b.id)
        store.close(b.id, then: .above)
        #expect(store.activeID == nil)
    }

    @Test func closeSelectionStaysInTheSpace() throws {
        let store = try makeStore()
        let home = store.currentSpaceID
        let a = store.create(url: nil, nextToActive: false)
        let work = store.addSpace(name: "Work", symbol: "briefcase.fill", color: "#0A84FF")
        let w1 = store.create(url: nil, nextToActive: false)
        store.switchSpace(to: home)
        // Interleaved: a home tab after the work tab in the overall list.
        let b = store.create(url: nil, nextToActive: false)
        let c = store.create(url: nil, nextToActive: false)
        #expect(store.tabs.map(\.id) == [a.id, w1.id, b.id, c.id])

        store.activate(b.id)
        store.close(b.id, then: .above) // w1 sits between them but belongs to Work
        #expect(store.activeID == a.id && store.currentSpaceID == home)

        store.switchSpace(to: work.id)
        store.close(w1.id, then: .below) // the last Work tab: nothing to show, home tabs stay out
        #expect(store.activeID == nil && store.currentSpaceID == work.id)
        #expect(store.tab(c.id) != nil)
    }

    @Test func closingABackgroundTabKeepsTheActiveOne() throws {
        let store = try makeStore()
        let a = store.create(url: nil, nextToActive: false)
        let b = store.create(url: nil, nextToActive: false)
        store.activate(a.id)
        store.close(b.id, then: .below)
        #expect(store.activeID == a.id)
    }

    // MARK: ⌘T, quitting

    @Test func newTabActionMapping() {
        let home = URL(string: "https://example.com")!
        #expect(NewTabAction.commandBar.effect(homepage: home) == .showCommandBar)
        #expect(NewTabAction.homepage.effect(homepage: home) == .openTab(home))
        #expect(NewTabAction.homepage.effect(homepage: nil) == .openTab(nil)) // no homepage: blank
        #expect(NewTabAction.blank.effect(homepage: home) == .openTab(nil))
        #expect(NewTabAction(stored: "homepage") == .homepage && NewTabAction(stored: "bogus") == .commandBar)
    }

    @Test func quitConfirmationAsksOnlyWhenOnAndThereIsMuchOpen() {
        #expect(!QuitConfirmation.shouldAsk(enabled: false, windows: 5, tabs: 500))
        #expect(!QuitConfirmation.shouldAsk(enabled: true, windows: 1, tabs: 3))
        #expect(QuitConfirmation.shouldAsk(enabled: true, windows: 2, tabs: 2))
        #expect(QuitConfirmation.shouldAsk(enabled: true, windows: 1, tabs: QuitConfirmation.tabThreshold))
    }

    // MARK: Reset

    @Test func resetRemovesOnlyLookAndBehaviourSettings() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        for key in Customization.allKeys { defaults.set("changed", forKey: key) }
        // Data and privacy choices that must survive.
        let kept: [String: Any] = [
            Preferences.Key.searchEngine: "google", Preferences.Key.homepage: "https://example.com",
            Preferences.Key.historyRetentionDays: 7, Preferences.Key.clearHistoryOnQuit: true,
            Preferences.Key.clearWebsiteDataOnQuit: true, Preferences.Key.adBlock: false,
            Preferences.Key.httpsFirst: false, Preferences.Key.removeLinkTracking: false,
            Preferences.Key.handoff: true, Preferences.Key.fraudulentSiteWarnings: false,
            Preferences.Key.searchSuggestions: false, Preferences.Key.searchSuggestionRows: 0, Preferences.Key.filterLists: ["easylist"],
            Preferences.Key.restoreSession: false, Preferences.Key.webDeveloperFeatures: true,
            Preferences.Key.ollamaHost: "http://127.0.0.1:11434", Preferences.Key.ollamaPins: "pin",
            ExtensionLibrary.storageKey: "x",
        ]
        for (key, value) in kept { defaults.set(value, forKey: key) }

        Customization.reset(in: defaults)

        for key in Customization.allKeys { #expect(defaults.object(forKey: key) == nil, "\(key) wasn't reset") }
        for key in kept.keys { #expect(defaults.object(forKey: key) != nil, "\(key) was reset") }
        #expect(Set(Customization.allKeys).isDisjoint(with: kept.keys))
    }

    @Test func resetCoversEveryNewSetting() {
        let all = Set(Customization.allKeys)
        let expected: [String] = [
            AppearanceStyle.Key.sidebarPosition, AppearanceStyle.Key.interfaceFont, AppearanceStyle.Key.tabDensity,
            AppearanceStyle.Key.closeButton, AppearanceStyle.Key.dimSleepingTabs, AppearanceStyle.Key.showsAddressField,
            AppearanceStyle.Key.footerAssistant, AppearanceStyle.Key.footerHistory, AppearanceStyle.Key.footerDownloads,
            AppearanceStyle.Key.footerNewTab, AppearanceStyle.Key.pageCornerRadius, AppearanceStyle.Key.pagePadding,
            AppearanceStyle.Key.commandBarBlur, AppearanceStyle.Key.commandBarPosition, AppearanceStyle.Key.commandBarWidth,
            AppearanceStyle.Key.pinnedColumns, Preferences.Key.newTabAction, Preferences.Key.afterClosingTab,
            Preferences.Key.linksOpenInBackground, Preferences.Key.confirmBeforeQuitting, Preferences.Key.swipeBetweenSpaces,
        ]
        for key in expected { #expect(all.contains(key), "\(key) isn't reset") }
        #expect(all.count == Customization.allKeys.count) // no key listed twice
    }
}
