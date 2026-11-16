import AppKit
import SwiftUI

/// Settings… (⌘,): a toolbar-style preferences window with SwiftUI panes, like the system apps.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(siteSettings: SiteSettings, adBlocker: AdBlocker, extensionLibrary: ExtensionLibrary?, extensionRuntime: AnyObject?, clearBrowsingData: @escaping @MainActor () -> Void,
         onAgentSettingsChanged: @escaping @MainActor () -> Void) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(Self.pane("General", symbol: "gearshape", GeneralSettingsView()))
        tabs.addTabViewItem(Self.pane("Tabs", symbol: "square.on.square", TabsSettingsView()))
        tabs.addTabViewItem(Self.pane("Appearance", symbol: "paintpalette", AppearanceSettingsView()))
        tabs.addTabViewItem(Self.pane("Websites", symbol: "globe", WebsitesSettingsView(settings: siteSettings)))
        tabs.addTabViewItem(Self.pane("Privacy", symbol: "hand.raised", PrivacySettingsView(adBlocker: adBlocker, clearBrowsingData: clearBrowsingData)))
        if let extensionLibrary {
            tabs.addTabViewItem(Self.pane("Extensions", symbol: "puzzlepiece.extension", ExtensionsSettingsView(library: extensionLibrary, runtime: extensionRuntime)))
        }
        tabs.addTabViewItem(Self.pane("Assistant", symbol: "sparkles", AssistantSettingsView(onApply: onAgentSettingsChanged)))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.setFrameAutosaveName("LilySettings")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func pane<V: View>(_ title: String, symbol: String, _ view: V) -> NSTabViewItem {
        let host = PaneHostingController(rootView: AnyView(view.frame(width: 520).fixedSize().appAccent()))
        host.sizingOptions = .preferredContentSize
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    func select(pane label: String) {
        guard let tabs = contentViewController as? NSTabViewController,
              let index = tabs.tabViewItems.firstIndex(where: { $0.label == label }) else { return }
        tabs.selectedTabViewItemIndex = index
    }

    func present() {
        if window?.isVisible == false { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// A settings pane whose height can change while it's showing (Appearance's sections): the
/// window follows, keeping its top edge where it is.
private final class PaneHostingController: NSHostingController<AnyView> {
    override var preferredContentSize: NSSize {
        didSet {
            guard preferredContentSize != oldValue, preferredContentSize.height > 0, let window = view.window,
                  (parent as? NSTabViewController)?.tabView.selectedTabViewItem?.viewController === self else { return }
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: preferredContentSize))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true, animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
    }
}

struct GeneralSettingsView: View {
    @AppStorage(Preferences.Key.searchEngine) private var searchEngine = Preferences.defaultSearchEngine.rawValue
    @AppStorage(Preferences.Key.homepage) private var homepage = Preferences.defaultHomepage
    @AppStorage(Preferences.Key.restoreSession) private var restoreSession = true
    @AppStorage(Preferences.Key.haptics) private var haptics = true
    @AppStorage(Preferences.Key.webDeveloperFeatures) private var webDeveloper = false
    @AppStorage(Preferences.Key.linksOpenInLittleLily) private var linksInLittle = true
    @AppStorage(Preferences.Key.confirmBeforeQuitting) private var confirmQuit = false
    @State private var isDefaultBrowser = DefaultBrowser.isDefault
    @State private var defaultBrowserError: String?

    var body: some View {
        Form {
            Picker("Search engine:", selection: $searchEngine) {
                ForEach(Preferences.SearchEngine.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            TextField("Homepage:", text: $homepage, prompt: Text(Preferences.defaultHomepage))
            Toggle("Open links from other apps in Little Lily", isOn: $linksInLittle)
            LabeledContent("") {
                Text("A small window for one page. Open in Lily (⇧⌘O) moves it into your main window as it is; closing it leaves it in History.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Haptic feedback on the trackpad", isOn: $haptics)
            Toggle("Show features for web developers", isOn: $webDeveloper)
                .onChange(of: webDeveloper) { (NSApp.delegate as? AppDelegate)?.webDeveloperFeaturesChanged() }
            LabeledContent("") {
                Text("Adds Inspect Element to the page menu, Develop → Show Web Inspector (⌥⌘I), and lets Safari's Develop menu inspect Lily's pages. Inspected pages can read and change what's on them, so leave it off unless you need it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("On launch, open:", selection: $restoreSession) {
                Text("Tabs from last time").tag(true)
                Text("The homepage").tag(false)
            }
            Toggle("Confirm before quitting with ⌘Q", isOn: $confirmQuit)
            LabeledContent("") {
                Text("Asks when two or more windows, or \(QuitConfirmation.tabThreshold) or more tabs, are open.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Default browser:") {
                if isDefaultBrowser {
                    Label("Lily is your default browser", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Button("Make Lily Default") {
                            DefaultBrowser.makeDefault { error in
                                defaultBrowserError = error.map(Sanitize.errorMessage)
                                isDefaultBrowser = DefaultBrowser.isDefault
                            }
                        }
                        .disabled(!DefaultBrowser.isAvailable)
                        if !DefaultBrowser.isAvailable {
                            Text("Available in the packaged app.").font(.caption).foregroundStyle(.secondary)
                        } else if let defaultBrowserError {
                            Text(defaultBrowserError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            LabeledContent("Keyboard shortcuts:") {
                Text("Every command is in Lily's menus, so you can change any shortcut in System Settings → Keyboard → Keyboard Shortcuts → App Shortcuts: add Lily and type the menu item's exact name.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("") {
                VStack(alignment: .leading, spacing: 4) {
                    Button("Reset All Settings to Defaults…") { Customization.confirmAndResetAll() }
                    Text("How Lily looks and works. Your history, bookmarks, extensions, site settings and privacy choices stay.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isDefaultBrowser = DefaultBrowser.isDefault
        }
    }
}

struct TabsSettingsView: View {
    @AppStorage(Preferences.Key.newTabsNextToCurrent) private var nextToCurrent = true
    @AppStorage(Preferences.Key.sleepTabsAfter) private var sleepAfter = TabSleeper.defaultMinutes
    @AppStorage(Preferences.Key.pauseIdlePanesAfter) private var pausePanesAfter = PaneFreezer.defaultMinutes
    @AppStorage(Preferences.Key.newTabAction) private var newTabAction = NewTabAction.default.rawValue
    @AppStorage(Preferences.Key.afterClosingTab) private var afterClose = TabStore.AfterClose.default.rawValue
    @AppStorage(Preferences.Key.linksOpenInBackground) private var linksInBackground = true
    @AppStorage(Preferences.Key.swipeBetweenSpaces) private var swipeSpaces = true

    var body: some View {
        Form {
            Picker("⌘T opens:", selection: $newTabAction) {
                ForEach(NewTabAction.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            .frame(width: 300)
            Picker("Open new tabs:", selection: $nextToCurrent) {
                Text("Next to the current tab").tag(true)
                Text("At the end of the list").tag(false)
            }
            .pickerStyle(.radioGroup)
            Picker("After closing a tab, show:", selection: $afterClose) {
                ForEach(TabStore.AfterClose.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            .frame(width: 300)
            Picker("⌘-click or middle-click a link:", selection: $linksInBackground) {
                Text("Opens it in the background").tag(true)
                Text("Opens it and switches to it").tag(false)
            }
            .frame(width: 360)
            LabeledContent("") {
                Text("Hold ⇧ as well to do the opposite.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Swipe with two fingers on the sidebar to switch spaces", isOn: $swipeSpaces)
            Picker("Sleep unused tabs after:", selection: $sleepAfter) {
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("Never").tag(0)
            }
            .frame(width: 260)
            LabeledContent("") {
                Text("Sleeping tabs release their memory and use no CPU; they reload where you left off when you open them. Tabs playing media or using the camera stay awake, and Low Power Mode sleeps tabs after 5 minutes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("Pause idle split panes after:", selection: $pausePanesAfter) {
                Text("1 minute").tag(1)
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("Never").tag(0)
            }
            .frame(width: 260)
            LabeledContent("") {
                Text("A pane of a split you haven't clicked into shows a still picture while its page is paused: no scripts, animations or rendering. Click or scroll it to resume. Panes playing media, loading, or with Link Scrolling on keep running.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Shortcuts:") {
                Text("⌘T new tab · ⌘W close · ⇧⌘T reopen · ⌘D pin · ⌘1–⌘9 jump · ⌃Tab cycle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.columns)
        .padding(20)
    }
}

struct AppearanceSettingsView: View {
    /// The pane's sections, one at a time so the window stays a sensible size.
    enum Section: String, CaseIterable {
        case theme = "Theme", sidebar = "Sidebar", page = "Page", commandBar = "Command Bar"
    }

    @State private var section = Section.theme
    // Theme
    @AppStorage(AppearanceStyle.Key.appAppearance) private var mode = AppearanceStyle.Mode.system.rawValue
    @AppStorage(AppearanceStyle.Key.accent) private var accent = AppearanceStyle.defaultAccent
    @AppStorage(AppearanceStyle.Key.sidebarTint) private var tint = AppearanceStyle.defaultAccent
    @AppStorage(AppearanceStyle.Key.tintStrength) private var strength = 0.12
    @AppStorage(AppearanceStyle.Key.grain) private var grain = 0.0
    // Sidebar
    @AppStorage(AppearanceStyle.Key.sidebarPosition) private var position = SidebarPosition.default.rawValue
    @AppStorage(AppearanceStyle.Key.interfaceFont) private var font = InterfaceFont.default.rawValue
    @AppStorage(AppearanceStyle.Key.sidebarTextSize) private var textSize = SidebarTextSize.default.rawValue
    @AppStorage(AppearanceStyle.Key.tabDensity) private var density = TabDensity.default.rawValue
    @AppStorage(AppearanceStyle.Key.closeButton) private var closeButton = CloseButtonVisibility.default.rawValue
    @AppStorage(AppearanceStyle.Key.dimSleepingTabs) private var dimSleeping = true
    @AppStorage(AppearanceStyle.Key.showsAddressField) private var showsAddress = true
    @AppStorage(AppearanceStyle.Key.pinnedColumns) private var pinnedColumns = PinnedColumns.automatic
    @AppStorage(AppearanceStyle.Key.footerAssistant) private var footerAssistant = true
    @AppStorage(AppearanceStyle.Key.footerHistory) private var footerHistory = true
    @AppStorage(AppearanceStyle.Key.footerDownloads) private var footerDownloads = true
    @AppStorage(AppearanceStyle.Key.footerNewTab) private var footerNewTab = true
    // Page
    @AppStorage(AppearanceStyle.Key.pageCornerRadius) private var cornerRadius = PageStyle.defaultCornerRadius
    @AppStorage(AppearanceStyle.Key.pagePadding) private var padding = PageStyle.defaultPadding
    // Command bar
    @AppStorage(AppearanceStyle.Key.commandBarBlur) private var blur = CommandBarBlur.default.rawValue
    @AppStorage(AppearanceStyle.Key.commandBarPosition) private var barPosition = CommandBarPosition.default.rawValue
    @AppStorage(AppearanceStyle.Key.commandBarWidth) private var barWidth = CommandBarWidth.default.rawValue

    var body: some View {
        VStack(spacing: 16) {
            Picker("", selection: $section) {
                ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 400)
            Form {
                switch section {
                case .theme: theme
                case .sidebar: sidebar
                case .page: page
                case .commandBar: commandBar
                }
                LabeledContent("") {
                    Button("Restore \(section.rawValue) Defaults") { restoreDefaults() }
                }
            }
            .formStyle(.columns)
        }
        .padding(20)
    }

    // MARK: Sections

    @ViewBuilder private var theme: some View {
        Picker("Appearance:", selection: $mode) {
            ForEach(AppearanceStyle.Mode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .frame(width: 260)
        .onChange(of: mode) { _, _ in AppearanceStyle.applyAppAppearance() }
        LabeledContent("Accent color:") { swatches($accent) }
        LabeledContent("Sidebar color:") { swatches($tint) }
        LabeledContent("Color strength:") {
            Slider(value: $strength, in: 0...0.5) { EmptyView() } minimumValueLabel: { Image(systemName: "circle") } maximumValueLabel: { Image(systemName: "circle.fill") }
                .frame(width: 260)
        }
        LabeledContent("Grain:") {
            VStack(alignment: .leading, spacing: 4) {
                Slider(value: $grain, in: 0...0.6) { EmptyView() } minimumValueLabel: { Text("Smooth").font(.caption) } maximumValueLabel: { Text("Paper").font(.caption) }
                    .frame(width: 260)
                Text("Adds a subtle paper-like texture to the sidebar.").font(.caption).foregroundStyle(.secondary)
            }
        }
        LabeledContent("Preview:") { preview }
    }

    @ViewBuilder private var sidebar: some View {
        segmented("Position:", $position, SidebarPosition.self, \.label)
        segmented("Font:", $font, InterfaceFont.self, \.label)
        LabeledContent("") {
            Text("For the sidebar and the command bar.").font(.caption).foregroundStyle(.secondary)
        }
        segmented("Text size:", $textSize, SidebarTextSize.self, \.label)
        segmented("Tab spacing:", $density, TabDensity.self, \.label)
        segmented("Close button:", $closeButton, CloseButtonVisibility.self, \.label)
        Picker("Pinned tab columns:", selection: $pinnedColumns) {
            ForEach(PinnedColumns.choices, id: \.self) { Text($0 == PinnedColumns.automatic ? "Automatic" : "\($0)").tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 300)
        LabeledContent("Show:") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Address field", isOn: $showsAddress)
                Toggle("Sleeping tabs dimmed", isOn: $dimSleeping)
            }
        }
        LabeledContent("Footer buttons:") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Assistant", isOn: $footerAssistant)
                Toggle("History", isOn: $footerHistory)
                Toggle("Downloads", isOn: $footerDownloads)
                Toggle("New Tab", isOn: $footerNewTab)
                Text("The space switcher always shows. Everything stays in the menus and the command palette (⌘K).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        LabeledContent("Preview:") { preview }
    }

    @ViewBuilder private var page: some View {
        LabeledContent("Corner radius:") {
            HStack {
                Slider(value: $cornerRadius, in: PageStyle.cornerRadiusRange, step: 1) { EmptyView() }
                    minimumValueLabel: { Image(systemName: "square") } maximumValueLabel: { Image(systemName: "app") }
                    .frame(width: 260)
                Text("\(Int(cornerRadius)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
            }
        }
        LabeledContent("Margin:") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Slider(value: $padding, in: PageStyle.paddingRange, step: 1) { EmptyView() }
                        minimumValueLabel: { Text("None").font(.caption) } maximumValueLabel: { Text("Roomy").font(.caption) }
                        .frame(width: 260)
                    Text("\(Int(padding)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
                Text("Space around web pages and split panes. With no margin and no rounding, pages fill the window edge to edge.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        LabeledContent("Preview:") {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                RoundedRectangle(cornerRadius: cornerRadius / 2, style: .continuous).fill(.background)
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius / 2, style: .continuous).strokeBorder(.separator))
                    .padding(padding / 2)
            }
            .frame(width: 260, height: 80)
        }
    }

    @ViewBuilder private var commandBar: some View {
        segmented("Background blur:", $blur, CommandBarBlur.self, \.label)
        LabeledContent("") {
            Text("With Reduce Transparency on, the page behind is only dimmed.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        segmented("Position:", $barPosition, CommandBarPosition.self, \.label)
        segmented("Width:", $barWidth, CommandBarWidth.self, \.label)
    }

    // MARK: Pieces

    private func segmented<Choice: StoredChoice>(_ title: String, _ value: Binding<String>, _ type: Choice.Type,
                                                 _ label: KeyPath<Choice, String>) -> some View {
        Picker(title, selection: value) {
            ForEach(Array(Choice.allCases), id: \.rawValue) { Text($0[keyPath: label]).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .frame(width: 300)
    }

    private var preview: some View {
        let row = SidebarRowStyle(textSize: SidebarTextSize(stored: textSize), density: TabDensity(stored: density))
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(.background)
            SidebarBackground().clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: accent).opacity(0.22)).frame(height: row.rowHeight)
                    .overlay(alignment: .leading) { Text("Active tab").font(.system(size: row.titleSize)).padding(.leading, 8) }
                Text("Another tab").font(.system(size: row.titleSize)).padding(.leading, 8).frame(height: row.rowHeight)
            }
            .padding(10)
        }
        .fontDesign(InterfaceFont(stored: font).design)
        .frame(width: 260, height: 40 + row.rowHeight * 2)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }

    private func restoreDefaults() {
        let keys: [String]
        switch section {
        case .theme:
            keys = [AppearanceStyle.Key.appAppearance, AppearanceStyle.Key.accent, AppearanceStyle.Key.sidebarTint,
                    AppearanceStyle.Key.tintStrength, AppearanceStyle.Key.grain]
        case .sidebar:
            keys = [AppearanceStyle.Key.sidebarPosition, AppearanceStyle.Key.interfaceFont, AppearanceStyle.Key.sidebarTextSize,
                    AppearanceStyle.Key.tabDensity, AppearanceStyle.Key.closeButton, AppearanceStyle.Key.dimSleepingTabs,
                    AppearanceStyle.Key.showsAddressField, AppearanceStyle.Key.pinnedColumns, AppearanceStyle.Key.footerAssistant,
                    AppearanceStyle.Key.footerHistory, AppearanceStyle.Key.footerDownloads, AppearanceStyle.Key.footerNewTab]
        case .page:
            keys = [AppearanceStyle.Key.pageCornerRadius, AppearanceStyle.Key.pagePadding]
        case .commandBar:
            keys = [AppearanceStyle.Key.commandBarBlur, AppearanceStyle.Key.commandBarPosition, AppearanceStyle.Key.commandBarWidth]
        }
        Customization.reset(keys)
        if section == .theme { AppearanceStyle.applyAppAppearance() }
    }

    private func swatches(_ value: Binding<String>) -> some View {
        HStack(spacing: 8) {
            ForEach(AppearanceStyle.presets, id: \.self) { hex in
                Circle().fill(Color(hex: hex)).frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(.primary.opacity(value.wrappedValue == hex ? 0.8 : 0), lineWidth: 2).padding(-3))
                    .onTapGesture { value.wrappedValue = hex }
                    .help(hex)
            }
            ColorPicker("", selection: Binding(get: { Color(hex: value.wrappedValue) }, set: { value.wrappedValue = $0.hexString }),
                        supportsOpacity: false)
                .labelsHidden()
        }
    }
}

struct WebsitesSettingsView: View {
    @Bindable var settings: SiteSettings
    @AppStorage(Preferences.Key.defaultZoom) private var defaultZoom = 1.0
    @AppStorage(Preferences.Key.defaultDarkMode) private var defaultDarkMode = SiteSettings.DarkMode.standard.rawValue

    var body: some View {
        Form {
            Picker("Default zoom:", selection: $defaultZoom) {
                // The levels ⌘− / ⌘+ step through.
                ForEach(SiteSettings.zoomLevels, id: \.self) { Text("\(Int(($0 * 100).rounded()))%").tag($0) }
            }
            .frame(width: 220)
            Picker("Website appearance:", selection: $defaultDarkMode) {
                ForEach(SiteSettings.DarkMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            .frame(width: 260)
            LabeledContent("") {
                Text("“Force Dark” uses a site's own dark theme when it has one and inverts it otherwise.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("Customized sites:") {
                VStack(alignment: .leading, spacing: 6) {
                    if settings.sites.isEmpty {
                        Text("None yet. Use the toolbar's Site Settings button on any site.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        List {
                            ForEach(settings.sites.keys.sorted(), id: \.self) { host in
                                HStack {
                                    Text(host)
                                    Spacer()
                                    Text(summary(settings.sites[host] ?? .init())).font(.caption).foregroundStyle(.secondary)
                                    Button { settings.reset(host) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(width: 330, height: 150)
                        .listStyle(.bordered)
                        Button("Remove All") { settings.removeAll() }
                    }
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
    }

    private func summary(_ site: SiteSettings.Site) -> String {
        var parts: [String] = []
        if let zoom = site.zoom { parts.append("\(Int(zoom * 100))%") }
        if let dark = site.darkMode { parts.append(dark.title) }
        if site.javaScript == false { parts.append("No JS") }
        if let camera = site.camera { parts.append("Camera: \(camera.title)") }
        if let mic = site.microphone { parts.append("Mic: \(mic.title)") }
        return parts.joined(separator: " · ")
    }
}

struct PrivacySettingsView: View {
    @Bindable var adBlocker: AdBlocker
    let clearBrowsingData: @MainActor () -> Void
    @AppStorage(Preferences.Key.adBlock) private var blockAds = true
    @AppStorage(Preferences.Key.httpsFirst) private var httpsFirst = true
    @AppStorage(Preferences.Key.removeLinkTracking) private var removeLinkTracking = true
    @AppStorage(Preferences.Key.handoff) private var handoff = false
    @AppStorage(Preferences.Key.fraudulentSiteWarnings) private var fraudWarnings = true
    @AppStorage(Preferences.Key.historyRetentionDays) private var retention = History.defaultRetentionDays
    @AppStorage(Preferences.Key.clearHistoryOnQuit) private var clearHistoryOnQuit = false
    @AppStorage(Preferences.Key.clearWebsiteDataOnQuit) private var clearDataOnQuit = false
    @AppStorage(Preferences.Key.searchSuggestions) private var searchSuggestions = true
    @AppStorage(Preferences.Key.searchSuggestionRows) private var suggestionRows = SearchSuggestions.maxSuggestions
    @AppStorage(Preferences.Key.searchEngine) private var searchEngine = Preferences.defaultSearchEngine.rawValue

    private var engine: Preferences.SearchEngine { Preferences.SearchEngine(rawValue: searchEngine) ?? Preferences.defaultSearchEngine }

    var body: some View {
        Form {
            LabeledContent("") {
                HStack(spacing: 16) {
                    Toggle("Search engine suggestions", isOn: $searchSuggestions)
                    Stepper(value: $suggestionRows, in: 0...SearchSuggestions.maxSuggestions) {
                        Text(suggestionRows == 1 ? "1 row" : "\(suggestionRows) rows").monospacedDigit()
                    }
                    .disabled(!searchSuggestions)
                    .help("How many suggestions from your search engine the command bar shows. 0 shows none and sends nothing.")
                }
            }
            LabeledContent("") {
                Text(engine == .kagi
                     ? "Kagi offers no suggestions without signing in, so with Kagi nothing you type is sent until you search; the command bar suggests from your tabs, bookmarks and history only."
                     : "What you type in the command bar is sent to \(engine.displayName) as you type, without cookies, to suggest searches. Never in private windows.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Block ads and trackers", isOn: $blockAds)
                .onChange(of: blockAds) { _, _ in adBlocker.settingsChanged() }
            LabeledContent("Filter lists:") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(FilterLists.all) { list in
                        Toggle(isOn: Binding(get: { adBlocker.isListEnabled(list.id) },
                                             set: { adBlocker.setList(list.id, enabled: $0) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(list.name)
                                Text(list.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Downloaded from each list's maintainer and updated weekly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!blockAds)
            }
            LabeledContent("") {
                HStack {
                    if adBlocker.isUpdating { ProgressView().controlSize(.small) }
                    Text(adBlocker.status).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if blockAds && !adBlocker.enabledLists.isEmpty {
                        Button("Update Now") { Task { await adBlocker.updateFilterLists() } }
                            .controlSize(.small).disabled(adBlocker.isUpdating)
                    }
                }
            }
            Toggle("Upgrade connections to HTTPS (HTTPS-First)", isOn: $httpsFirst)
            Toggle("Remove trackers from links", isOn: $removeLinkTracking)
                .help("Strips click and campaign identifiers (utm_…, fbclid, gclid and similar) from links you open, click or copy")
            Toggle("Continue pages on other devices (Handoff)", isOn: $handoff)
                .onChange(of: handoff) { (NSApp.delegate as? AppDelegate)?.handoffChanged() }
                .help("Shares the address and title of the page you're on with every device signed in to your Apple account")
            Toggle("Warn about fraudulent websites", isOn: $fraudWarnings)
                .onChange(of: fraudWarnings) { (NSApp.delegate as? AppDelegate)?.fraudWarningsChanged() }
                .help("Checks pages against lists of known phishing and malware sites, as Safari does. Lily sends only part of a hash of each address, relayed by Apple, never the address itself.")
            Picker("Keep history:", selection: $retention) {
                Text("One day").tag(1)
                Text("One week").tag(7)
                Text("One month").tag(30)
                Text("Three months").tag(90)
                Text("One year").tag(365)
                Text("Forever").tag(0)
            }
            .frame(width: 220)
            Toggle("Clear history when Lily quits", isOn: $clearHistoryOnQuit)
            Toggle("Clear cookies and website data when Lily quits", isOn: $clearDataOnQuit)
            LabeledContent("") {
                Text("Website data (cookies, storage, caches) is written by WebKit unencrypted inside Lily's container. Clearing it on quit signs you out of websites each time.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent("") {
                Button("Clear Browsing Data…", action: clearBrowsingData)
            }
            LabeledContent("Protected:") {
                Text("Your session, history and site settings are encrypted on disk with a key in your Keychain. Private windows leave none of them behind.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.columns)
        .padding(20)
    }
}

struct AssistantSettingsView: View {
    @AppStorage(Preferences.Key.ollamaHost) private var ollamaHost = ""
    @AppStorage(Preferences.Key.agentModel) private var agentModel = ""
    @AppStorage(Preferences.Key.ollamaPins) private var pins = ""
    @State private var pinStatus: String?
    let onApply: @MainActor () -> Void

    var body: some View {
        Form {
            TextField("Ollama host:", text: $ollamaHost, prompt: Text("http://127.0.0.1:11434"))
            TextField("Model:", text: $agentModel, prompt: Text("First installed"))
            LabeledContent("Certificate pins:") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("", text: $pins, prompt: Text("Optional, for a remote HTTPS host"))
                        .font(.system(.body, design: .monospaced))
                    HStack {
                        Button("Pin Current Certificate") { pinCurrentCertificate() }
                            .disabled(!AssistantConfiguration.normalizedHost(ollamaHost).absoluteString.hasPrefix("https://"))
                        if !pins.isEmpty { Button("Clear") { pins = ""; pinStatus = nil } }
                    }
                    Text(pinStatus ?? "Pinned SPKI SHA-256 hashes. Lily refuses the host if its certificate key changes.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent("") {
                VStack(alignment: .leading, spacing: 4) {
                    Button("Apply", action: onApply)
                    Text("The assistant talks to Ollama on your Mac (or a host you trust). Remote hosts must use HTTPS.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.columns)
        .padding(20)
    }

    /// Trust on first use, by explicit user action: records the key of the host's current,
    /// system-validated certificate plus its issuer's key as a backup pin.
    private func pinCurrentCertificate() {
        let url = AssistantConfiguration.normalizedHost(ollamaHost)
        pinStatus = "Checking \(url.host ?? "")…"
        Task {
            do {
                let found = try await CertificatePinning.currentPins(for: url)
                pins = found.prefix(2).joined(separator: ", ")
                pinStatus = "Pinned \(min(found.count, 2)) key(s) for \(url.host ?? ""). Click Apply."
            } catch {
                pinStatus = "Couldn't read the certificate: \(Sanitize.errorMessage(error))"
            }
        }
    }
}
