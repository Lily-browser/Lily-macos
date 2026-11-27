import AppKit
import UniformTypeIdentifiers
import WebKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    public private(set) var paths: AppPaths!
    private var registry: ScriptRegistry!
    private var factory: WebViewFactory!
    private var assistant: Assistant!
    private var sessionStore: SessionStore!
    private(set) var history: History!
    private(set) var formDrafts: FormDrafts!
    private(set) var siteSettings: SiteSettings!
    private(set) var adBlocker: AdBlocker!
    /// Installed extensions (every macOS version) and their runtime: `ExtensionManager` on macOS
    /// 15.4+, `ExtensionScriptInjector` (page scripts only) before that.
    private(set) var extensionLibrary: ExtensionLibrary?
    private(set) var extensionRuntime: AnyObject?
    private var memoryPressure: DispatchSourceMemoryPressure?
    /// For the diagnostics log: how long this process has been running when something happens (#160, the gray swipe, went
    /// away after a relaunch, so how long Lily had run is the first thing to know if it returns).
    private let launchedAt = Date()
    private var uptimeText: String {
        let seconds = Int(Date().timeIntervalSince(launchedAt))
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
    }
    private let appIcon = AppIconController()
    private var historyWindow: HistoryWindowController?
    private let historyMenuDelegate = HistoryMenuDelegate()
    private(set) var bookmarks: Bookmarks!
    private let bookmarksMenuDelegate = BookmarksMenuDelegate()
    private var migrationAccess: MigrationAccess?
    private var migrationWindow: MigrationWindowController?
    private var windows: [BrowserWindowController] = []
    /// Links from other apps that arrive while Lily is still starting (a cold launch from a link)
    /// wait here until the windows can be made.
    private var launched = false
    private var pendingLinks: [URL] = []
    /// Pages continued from another device (Handoff) while Lily was still starting.
    private var pendingContinued: [URL] = []
    /// Where the next Little Lily window goes, so several cascade instead of stacking.
    private var littleCascade: NSPoint?
    private var settingsWindow: SettingsWindowController?
    private var saveScheduled = false
    /// The main window's tabs as last loaded or captured for saving. When that window is closed
    /// while Lily keeps running, the next main window starts from it instead of empty (an empty
    /// window would otherwise save over the real session a moment later).
    private var lastSession: SessionStore.Session?
    /// Set once quitting has begun: the quit itself saves the session, and nothing after it may.
    private var terminating = false

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        paths = AppPaths.resolve()
        // Private: the path includes the macOS user name.
        Log.app.info("Resources at \(self.paths.root.path, privacy: .private)")
        Log.app.notice("Launched \(AppInfo.version, privacy: .public) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString, privacy: .public)")
        MainMenu.disableSystemItems()
        NSApp.mainMenu = MainMenu.build()
        MainMenu.updateDevelopMenu()
        AppearanceStyle.applyAppAppearance()
        appIcon.start()
        watchMemoryPressure()
        Task { await launch() }
    }

    /// When macOS runs low on memory, unload every background tab that can sleep.
    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                let level = self?.memoryPressure?.data.contains(.critical) == true ? "critical" : "warning"
                let loaded = self?.windows.reduce(0) { $0 + $1.tabs.tabs.filter(\.hasWebView).count } ?? 0
                Log.app.notice("Memory pressure (\(level, privacy: .public)) after \(self?.uptimeText ?? "?", privacy: .public) up, \(loaded, privacy: .public) tabs with a web view: putting background tabs to sleep")
                self?.windows.forEach { $0.sleepBackgroundTabs() }
            }
        }
        source.resume()
        memoryPressure = source
    }

    private func launch() async {
        // Packaged builds refuse to run modified code or resources (e.g. edited injection scripts).
        if AppInfo.isPackaged, let problem = await CodeIntegrity.verify(bundleAt: Bundle.main.bundleURL) {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Lily has been modified and can't be opened"
            alert.informativeText = "\(problem)\n\nDelete this copy and reinstall Lily from the official release."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        // Before anything saved is read: the optional Touch ID lock (never in the self-test).
        if !ProcessInfo.processInfo.arguments.contains("--self-test"), await AppLock.gate() == .denied {
            NSApp.terminate(nil)
            return
        }
        do {
            registry = try ScriptRegistry(manifestURL: paths.injectionManifest)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Lily could not load its content scripts"
            Log.app.error("Content scripts failed to load from \(self.paths.injections.path, privacy: .private): \(String(describing: error), privacy: .private)")
            // Packaged builds don't reveal paths; development builds explain how to fix the setup.
            alert.informativeText = AppInfo.isPackaged
                ? "The app's resources are missing or damaged. Reinstall Lily."
                : "\(Sanitize.errorMessage(error))\n\nSet LILY_ROOT to the repository root."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        siteSettings = SiteSettings(directory: ProcessInfo.processInfo.arguments.contains("--self-test") ? nil : paths.applicationSupport)
        await siteSettings.load()
        adBlocker = AdBlocker(directory: ProcessInfo.processInfo.arguments.contains("--self-test") ? nil : paths.applicationSupport)
        await adBlocker.prepare()
        factory = WebViewFactory(registry: registry, siteSettings: siteSettings, adBlocker: adBlocker)
        Task { [factory] in await factory?.removePendingSpaceData() }
        if !ProcessInfo.processInfo.arguments.contains("--self-test") {
            let workerShim = try? Data(contentsOf: paths.injections.appendingPathComponent("extension-worker-compat.js"))
            // Without it, Chrome-built extensions whose background uses missing APIs install but never start.
            if workerShim == nil { Log.extensions.error("Extension worker shim missing from the app's resources") }
            let library = ExtensionLibrary(directory: paths.applicationSupport, workerShim: workerShim)
            extensionLibrary = library
            startExtensionRuntime(library)
            Task { await library.loadAll() }
        }
        assistant = Assistant(configuration: .fromPreferences())
        sessionStore = SessionStore(directory: paths.applicationSupport)
        // The self-test must not leave its fixture pages in the user's real history.
        let isSelfTest = ProcessInfo.processInfo.arguments.contains("--self-test")
        history = History(directory: isSelfTest ? nil : paths.applicationSupport)
        // Kept site icons follow history: whatever history forgets, its icons go too.
        await FaviconLoader.shared.load(directory: isSelfTest ? nil : paths.applicationSupport)
        history.onForget = { FaviconLoader.shared.forget($0) }
        await history.load()
        formDrafts = FormDrafts(directory: isSelfTest ? nil : paths.applicationSupport)
        await formDrafts.load()
        historyMenuDelegate.history = history
        NSApp.mainMenu?.item(withTitle: "History")?.submenu?.delegate = historyMenuDelegate
        bookmarks = Bookmarks(directory: isSelfTest ? nil : paths.applicationSupport)
        await bookmarks.load()
        bookmarksMenuDelegate.bookmarks = bookmarks
        NSApp.mainMenu?.item(withTitle: "Bookmarks")?.submenu?.delegate = bookmarksMenuDelegate
        migrationAccess = MigrationAccess(directory: isSelfTest ? nil : paths.applicationSupport)

        let controller = makeWindow()
        if ProcessInfo.processInfo.arguments.contains("--self-test") {
            controller.showWindowCentered()
            launched = true
            SelfTest.run(window: controller, assistant: assistant)
            return
        }
        let args = ProcessInfo.processInfo.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if Preferences.restoresSession, let session = await sessionStore.load(), !session.tabs.isEmpty {
            lastSession = session
            controller.tabs.restore(session)
        }
        for arg in args {
            if let url = Preferences.urlResolver.resolve(arg) { controller.tabs.create(url: url) }
        }
        if controller.tabs.tabs.isEmpty {
            controller.tabs.create(url: Preferences.homepage)
        }
        controller.showWindowCentered()
        NSApp.activate()
        launched = true
        let waiting = pendingLinks
        pendingLinks = []
        if !waiting.isEmpty { open(waiting) }
        let continued = pendingContinued
        pendingContinued = []
        continued.forEach(continueBrowsing)
    }

    /// The encrypted session save is async, so quitting waits for it.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if !terminating, !confirmQuit() { return .terminateCancel }
        assistant?.cancelAll()
        guard let sessionStore else { return .terminateNow }
        // The main window's tabs now; with it closed, what it last held (saved again only if the
        // close-time save hasn't landed yet: an unchanged session isn't rewritten).
        let session = primaryWindow.map(captureSession) ?? lastSession
        terminating = true
        Task {
            if let session { await sessionStore.save(session) }
            if Preferences.flag(Preferences.Key.clearHistoryOnQuit, default: false) {
                history?.clear()
                formDrafts?.removeAll()
            }
            await history?.flush()
            await formDrafts?.flush()
            await bookmarks?.flush()
            if Preferences.flag(Preferences.Key.clearWebsiteDataOnQuit, default: false) {
                // Cookies, storage and caches are written by WebKit unencrypted; don't leave them behind
                // (every space's own store included).
                await factory.removeAllWebsiteData()
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Settings → General → Confirm before quitting: asks when ⌘Q would close several windows or
    /// many tabs. Quits that macOS asks for (log out, restart, an update) never wait on a dialog.
    private func confirmQuit() -> Bool {
        let regular = windows.filter { !$0.isLittle }
        let tabCount = regular.reduce(0) { $0 + $1.tabs.tabs.count }
        guard QuitConfirmation.shouldAsk(enabled: Preferences.confirmsBeforeQuitting, windows: regular.count, tabs: tabCount),
              NSAppleEventManager.shared().currentAppleEvent == nil,
              !ProcessInfo.processInfo.arguments.contains("--self-test") else { return true }
        let alert = NSAlert()
        alert.messageText = "Quit Lily?"
        let windowsText = regular.count == 1 ? "1 window" : "\(regular.count) windows"
        let tabsText = tabCount == 1 ? "1 tab" : "\(tabCount) tabs"
        alert.informativeText = "You have \(windowsText) with \(tabsText) open."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        let quit = alert.runModal() == .alertFirstButtonReturn
        if quit, alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(false, forKey: Preferences.Key.confirmBeforeQuitting)
        }
        return quit
    }

    @objc public func clearBrowsingData(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Clear all browsing data?"
        alert.informativeText = "This removes your browsing history (and the site icons kept from it), cookies, caches, site storage, the saved session, saved typed text, the downloads list and the assistant's context. Open tabs stay open, and you'll be signed out of websites. Downloaded files stay in your Downloads folder."
        // Site settings are kept per site, so they're also a list of sites you've been to.
        let forgetSites = NSButton(checkboxWithTitle: "Also forget site settings (zoom, permissions, dark mode)", target: nil, action: nil)
        forgetSites.state = .on
        alert.accessoryView = forgetSites
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let alsoSites = forgetSites.state == .on
        // At once: a main window opened before the Task runs must not bring the cleared session back.
        lastSession = nil
        Task {
            await sessionStore.clear()
            await factory.removeAllWebsiteData()
            DownloadManager.shared.clearFinished()
            if alsoSites {
                siteSettings.removeAll()
                await siteSettings.flush()
            }
            history.clear()
            await history.flush()
            formDrafts.removeAll()
            await formDrafts.flush()
            assistant.context.reset()
            windows.forEach { $0.tabs.clearRecentlyClosed() }
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { newWindow(nil) }
        return true
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Edit → Copy / Cut run the normal responder-chain action, then, for a page in a private window,
    /// mark the pasteboard Concealed/Transient so clipboard managers skip it. (WebKit's own context-menu
    /// Copy doesn't pass through here.) The marking follows WebKit's asynchronous write, so it waits for
    /// the pasteboard to change, for at most a second.
    @objc func copyFromPage(_ sender: Any?) { sendEdit(#selector(NSText.copy(_:)), sender) }
    @objc func cutFromPage(_ sender: Any?) { sendEdit(#selector(NSText.cut(_:)), sender) }

    private func sendEdit(_ action: Selector, _ sender: Any?) {
        let board = NSPasteboard.general
        let before = board.changeCount
        let responder = NSApp.keyWindow?.firstResponder as? NSView
        let fromPrivatePage = (NSApp.keyWindow?.windowController as? BrowserWindowController)?.isPrivate == true
            && responder.map { view in sequence(first: view, next: \.superview).contains { $0 is BrowserWebView } } == true
        NSApp.sendAction(action, to: nil, from: sender)
        guard fromPrivatePage else { return }
        Task { @MainActor in
            for _ in 0..<50 {
                if board.changeCount != before { Clipboard.conceal(board); return }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copyFromPage(_:)) { return NSApp.target(forAction: #selector(NSText.copy(_:)), to: nil, from: item) != nil }
        if item.action == #selector(cutFromPage(_:)) { return NSApp.target(forAction: #selector(NSText.cut(_:)), to: nil, from: item) != nil }
        guard item.action == #selector(makeDefaultBrowser(_:)) else { return true }
        return DefaultBrowser.isAvailable && !DefaultBrowser.isDefault
    }

    // MARK: Handoff (receiving)

    /// A page continued from another device. Info.plist declares NSUserActivityTypeBrowsingWeb,
    /// so macOS offers Lily for it; this is where the page arrives. Receiving shares nothing, so it
    /// works whatever Settings → Privacy → Handoff (which is about sending) says.
    public func application(_ application: NSApplication, willContinueUserActivityWithType type: String) -> Bool {
        Log.app.notice("Handoff: will continue \(type, privacy: .public)")
        return type == NSUserActivityTypeBrowsingWeb
    }

    public func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                            restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        // Whether a page arrived, never which one: the address stays private in the log.
        Log.app.notice("""
            Handoff: continue \(userActivity.activityType, privacy: .public): webpageURL \(userActivity.webpageURL?.scheme ?? "none", privacy: .public), \
            referrerURL \(userActivity.referrerURL?.scheme ?? "none", privacy: .public), userInfo keys \(userActivity.userInfo?.count ?? 0, privacy: .public), \
            launched \(self.launched, privacy: .public), url \(userActivity.webpageURL?.absoluteString ?? "", privacy: .private)
            """)
        // The address normally comes as webpageURL; fall back to the referrer before giving up.
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = Self.continuable(userActivity.webpageURL) ?? Self.continuable(userActivity.referrerURL) else {
            Log.app.error("Handoff: no web page in the continued activity")
            return false
        }
        guard launched else {
            pendingContinued.append(url)
            return true
        }
        continueBrowsing(url)
        return true
    }

    public func application(_ application: NSApplication, didFailToContinueUserActivityWithType type: String, error: any Error) {
        Log.app.error("Couldn't continue a page from another device: \(error.localizedDescription, privacy: .private)")
    }

    /// Only web pages: an activity from another device never opens a file or runs a script.
    nonisolated static func continuable(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host?.isEmpty == false else { return nil }
        return url
    }

    /// Like Safari: the page opens as a new, active tab in the main window, which comes forward.
    func continueBrowsing(_ url: URL) {
        let main = primaryWindow ?? makePrimaryWindow().controller
        main.tabs.create(url: url)
        main.showWindow(nil)
        main.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { return pendingLinks += urls }
        open(urls)
    }

    /// Links from other apps: web pages in Little Lily (when that's on), files and everything else
    /// as tabs in the main window.
    private func open(_ urls: [URL]) {
        let little = Preferences.flag(Preferences.Key.linksOpenInLittleLily, default: true)
        var target: BrowserWindowController?
        for url in urls {
            if little, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                openLittle(url)
                continue
            }
            let main = target ?? primaryWindow ?? makePrimaryWindow().controller
            target = main
            if url.isFileURL { main.tabs.openFile(url) } else { main.tabs.create(url: url) }
        }
        target?.showWindow(nil)
    }

    /// The saved session belongs to the first regular window (not private, not Little Lily).
    private var primaryWindow: BrowserWindowController? { windows.first { !$0.isPrivate && !$0.isLittle } }

    /// The main window for Little Lily to hand pages to; made (with the last session) if there isn't one.
    private func mainWindowForLittle() -> BrowserWindowController {
        if let primary = primaryWindow { return primary }
        let controller = makePrimaryWindow().controller
        controller.showWindowCentered()
        return controller
    }

    /// A new regular window. When it becomes the main window after the previous one was closed
    /// (Lily kept running), it gets that window's tabs, spaces and splits back before it's shown and
    /// before anything can save, rather than starting empty and overwriting the saved session.
    /// `restored` is false when it starts empty.
    private func makePrimaryWindow() -> (controller: BrowserWindowController, restored: Bool) {
        let session = launched && !terminating && primaryWindow == nil && Preferences.restoresSession ? lastSession : nil
        let controller = makeWindow()
        guard let session, !session.tabs.isEmpty else { return (controller, false) }
        controller.tabs.restore(session)
        return (controller, !controller.tabs.tabs.isEmpty)
    }

    /// A Little Lily window for `url`, or the one already showing it, brought forward.
    func openLittle(_ url: URL) {
        if let open = windows.first(where: { $0.isLittle && $0.tabs.active?.url == url }) {
            open.showWindow(nil)
            open.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = makeWindow(style: .little)
        controller.tabs.create(url: url)
        showLittle(controller)
    }

    /// File → New Little Lily Window (⌥⌘N): an empty one, with the address bar open.
    @objc public func newLittleLilyWindow(_ sender: Any?) {
        let controller = makeWindow(style: .little)
        showLittle(controller)
        controller.model.presentCommandBar(newTab: true)
    }

    private func showLittle(_ controller: BrowserWindowController) {
        guard let window = controller.window else { return }
        if let point = littleCascade {
            littleCascade = window.cascadeTopLeft(from: point)
        } else {
            window.center()
            littleCascade = window.cascadeTopLeft(from: NSPoint(x: window.frame.minX, y: window.frame.maxY))
        }
        controller.showWindow(nil)
        NSApp.activate()
    }

    func openInNewWindow(_ url: URL, isPrivate: Bool) {
        let controller = isPrivate ? makeWindow(isPrivate: true) : makePrimaryWindow().controller
        controller.tabs.create(url: url)
        controller.showWindowCentered()
    }

    @objc public func newPrivateWindow(_ sender: Any?) {
        let controller = makeWindow(isPrivate: true)
        controller.tabs.create(url: nil)
        controller.showWindowCentered()
        controller.newTab(nil)
    }

    /// File > Open File…: the panel grants sandbox access to exactly the chosen files.
    @objc public func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html, UTType("public.xhtml") ?? .html, .webArchive, .pdf, .plainText, .svg, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files to open in Lily"
        guard panel.runModal() == .OK else { return }
        let target = (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? primaryWindow ?? makePrimaryWindow().controller
        panel.urls.forEach { target.tabs.openFile($0) }
        target.showWindow(nil)
    }

    /// ⌘N, and clicking the Dock icon with no window open. With the main window closed, this one
    /// is the main window again, with its tabs back.
    @objc public func newWindow(_ sender: Any?) {
        let (controller, restored) = makePrimaryWindow()
        if restored {
            controller.showWindowCentered()
            return
        }
        controller.tabs.create(url: nil)
        controller.showWindowCentered()
        controller.newTab(nil)
    }

    private func startExtensionRuntime(_ library: ExtensionLibrary) {
        if #available(macOS 15.4, *) {
            let manager = ExtensionManager(library: library)
            manager.windows = { [weak self] in self?.windows.filter { !$0.isPrivate } ?? [] }
            manager.focusedWindow = { [weak self] in
                (NSApp.keyWindow?.windowController as? BrowserWindowController).flatMap { $0.isPrivate ? nil : $0 } ?? self?.primaryWindow
            }
            manager.openTab = { [weak self] url, active in
                // chrome.tabs.create from a Little Lily window opens in the main window.
                guard let focused = manager.focusedWindow() ?? self?.primaryWindow,
                      let target = focused.isLittle ? self?.mainWindowForLittle() : focused else { return nil }
                return target.tabs.create(url: url, activate: active)
            }
            manager.siteSettings = siteSettings
            extensionRuntime = manager
            factory.extensionController = manager.controller
            factory.extensionPageConfiguration = { [weak manager] url in manager?.controller.extensionContext(for: url)?.webViewConfiguration }
        } else {
            do {
                let injector = try ExtensionScriptInjector(library: library, shimURL: paths.injections.appendingPathComponent("extension-compat.js"))
                extensionRuntime = injector
                factory.extensionScripts = injector
            } catch {
                Log.extensions.error("Extension compatibility shim missing; extensions won't run")
            }
        }
    }

    @objc public func showExtensionsSettings(_ sender: Any?) {
        showSettings(sender)
        settingsWindow?.select(pane: "Extensions")
    }

    @objc public func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(siteSettings: siteSettings, adBlocker: adBlocker, extensionLibrary: extensionLibrary, extensionRuntime: extensionRuntime,
                                                      clearBrowsingData: { [weak self] in self?.clearBrowsingData(nil) },
                                                      onAgentSettingsChanged: { [weak self] in self?.assistant.reconfigure(.fromPreferences()) })
        }
        settingsWindow?.present()
    }

    @objc public func makeDefaultBrowser(_ sender: Any?) {
        DefaultBrowser.makeDefault { error in
            if let error { NSApp.presentError(error) }
        }
    }

    @objc public func showHistory(_ sender: Any?) {
        if historyWindow == nil {
            historyWindow = HistoryWindowController(history: history) { [weak self] url, newTab in self?.openFromHistory(url, newTab: newTab) }
        }
        historyWindow?.present()
    }

    /// History opens pages in the frontmost regular window (never a private one).
    func openFromHistory(_ url: URL, newTab: Bool) {
        let target = primaryWindow ?? makePrimaryWindow().controller
        target.open(url, newTab: newTab || target.tabs.active == nil)
        target.showWindow(nil)
    }

    /// File → Import from Another Browser…
    @objc public func showMigration(_ sender: Any?) {
        guard let migrationAccess else { return }
        if migrationWindow == nil {
            let model = MigrationModel(access: migrationAccess, destination: .init(bookmarks: bookmarks, history: history) { [weak self] in
                (self?.primaryWindow ?? self?.makePrimaryWindow().controller)?.tabs
            })
            migrationWindow = MigrationWindowController(model: model)
        }
        migrationWindow?.present()
    }

    @objc func removeAllBookmarks(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Remove all \(bookmarks.linkCount.formatted()) bookmarks?"
        alert.informativeText = "This can't be undone. Your other browsers' bookmarks aren't affected."
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { bookmarks.removeAll() }
    }

    @objc func openHistoryItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openFromHistory(url, newTab: true)
    }

    /// Settings → General → web developer features: the Develop menu, and every open page and
    /// extension page, follow at once.
    /// Settings → Privacy → Handoff switched: stop (or start) advertising pages at once.
    func handoffChanged() { windows.forEach { $0.updateHandoff() } }

    /// Settings → Privacy → fraudulent-site warnings switched: open pages follow at once.
    func fraudWarningsChanged() {
        let on = Preferences.warnsAboutFraudulentSites
        for tab in windows.flatMap(\.tabs.tabs) where tab.hasWebView { tab.webView.configuration.preferences.isFraudulentWebsiteWarningEnabled = on }
    }

    func webDeveloperFeaturesChanged() {
        MainMenu.updateDevelopMenu()
        windows.forEach { $0.applyWebInspector() }
        if #available(macOS 15.4, *) { (extensionRuntime as? ExtensionManager)?.applyInspectable() }
    }

    @objc public func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(AppInfo.helpURL)
    }

    private func makeWindow(isPrivate: Bool = false, style: BrowserWindowController.Style = .regular) -> BrowserWindowController {
        // Each private window gets its own in-memory data store: no cookies or caches touch disk,
        // and private windows can't see each other's sessions.
        let factory = isPrivate
            ? WebViewFactory(registry: registry, dataStore: .nonPersistent(), siteSettings: siteSettings, savesSiteChanges: false, adBlocker: adBlocker)
            : self.factory!
        let controller = BrowserWindowController(factory: factory, assistant: assistant, history: isPrivate ? nil : history,
                                                 isPrivate: isPrivate, style: style)
        controller.bookmarks = bookmarks
        controller.mainWindow = { [weak self] in self?.mainWindowForLittle() }
        controller.openLittle = { [weak self] url in self?.openLittle(url) }
        controller.formDrafts = isPrivate ? nil : formDrafts
        controller.onClose = { [weak self] closed in
            guard let self else { return }
            // Quitting closes windows after its own save; nothing is saved behind it.
            if self.primaryWindow === closed, !self.terminating {
                let session = self.captureSession(closed)
                Task { await self.sessionStore.save(session) }
            }
            self.windows.removeAll { $0 === closed }
            // The last private window: nothing it downloaded stays listed.
            if closed.isPrivate, !self.windows.contains(where: \.isPrivate) { DownloadManager.shared.forgetPrivate() }
        }
        controller.onSessionChange = { [weak self] in self?.scheduleSave() }
        windows.append(controller)
        return controller
    }

    /// The first window's tabs are the persisted session (matching Arc's single-sidebar model).
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.saveScheduled = false
            // Once quitting has begun its save is the last word; a later one could hold torn-down tabs.
            guard !self.terminating, let primary = self.primaryWindow, let sessionStore = self.sessionStore else { return }
            await sessionStore.save(self.captureSession(primary))
        }
    }

    /// The main window's session, remembered for a main window opened after this one closes.
    private func captureSession(_ primary: BrowserWindowController) -> SessionStore.Session {
        let session = primary.tabs.session
        lastSession = session
        return session
    }
}

/// Fills the History menu with recently visited pages each time it opens.
@MainActor
final class HistoryMenuDelegate: NSObject, NSMenuDelegate {
    weak var history: History?
    private static let tag = 4_200

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.filter { $0.tag == Self.tag }.forEach(menu.removeItem)
        guard let recent = history?.recent(12), !recent.isEmpty else { return }
        let header = NSMenuItem.sectionHeader(title: "Recently Visited")
        header.tag = Self.tag
        menu.addItem(header)
        for visit in recent {
            let title = visit.title.isEmpty ? (visit.url.host ?? visit.url.absoluteString) : visit.title
            let item = NSMenuItem(title: String(title.prefix(60)), action: #selector(AppDelegate.openHistoryItem(_:)), keyEquivalent: "")
            item.representedObject = visit.url
            item.toolTip = visit.url.absoluteString
            item.tag = Self.tag
            menu.addItem(item)
        }
    }
}

/// Fills the Bookmarks menu with folders (as submenus) and links when it opens.
@MainActor
final class BookmarksMenuDelegate: NSObject, NSMenuDelegate {
    weak var bookmarks: Bookmarks?
    private static let tag = 4_300
    private static let maxItemsPerMenu = 300

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.filter { $0.tag == Self.tag }.forEach(menu.removeItem)
        guard let root = bookmarks?.root, !root.isEmpty else { return }
        let separator = NSMenuItem.separator()
        separator.tag = Self.tag
        menu.addItem(separator)
        for item in Self.items(root, depth: 0) {
            item.tag = Self.tag
            menu.addItem(item)
        }
    }

    static func items(_ nodes: [Bookmarks.Node], depth: Int) -> [NSMenuItem] {
        nodes.prefix(maxItemsPerMenu).map { node in
            let title = String((node.title.isEmpty ? (node.url?.host ?? "Untitled") : node.title).prefix(60))
            if let children = node.children {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                let submenu = NSMenu(title: title)
                if depth < 8 { Self.items(children, depth: depth + 1).forEach(submenu.addItem) }
                item.submenu = submenu
                return item
            }
            let item = NSMenuItem(title: title, action: #selector(AppDelegate.openHistoryItem(_:)), keyEquivalent: "")
            item.representedObject = node.url
            item.toolTip = node.url?.absoluteString
            return item
        }
    }
}
