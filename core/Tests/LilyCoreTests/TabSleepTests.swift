import Foundation
import Testing
@testable import LilyCore

@Suite @MainActor struct TabSleepTests {
    let now = Date()

    func eligible(minutesIdle: Double, threshold: TimeInterval? = 900, active: Bool = false, split: Bool = false,
                  sleeping: Bool = false, scheme: String? = "https", force: Bool = false) -> Bool {
        TabSleeper.isEligible(lastActivated: now.addingTimeInterval(-minutesIdle * 60), now: now, threshold: threshold,
                              isActive: active, inSplit: split, isSleeping: sleeping, scheme: scheme, force: force)
    }

    @Test func onlyIdleBackgroundWebPagesSleep() {
        #expect(eligible(minutesIdle: 20))
        #expect(!eligible(minutesIdle: 5))
        #expect(!eligible(minutesIdle: 60, active: true))
        #expect(!eligible(minutesIdle: 60, split: true))
        #expect(!eligible(minutesIdle: 60, sleeping: true))
        #expect(!eligible(minutesIdle: 60, scheme: "file"))
        #expect(!eligible(minutesIdle: 60, threshold: nil)) // "Never"
    }

    @Test func memoryPressureIgnoresIdleTimeButNotVisibility() {
        #expect(eligible(minutesIdle: 0, force: true))
        #expect(eligible(minutesIdle: 0, threshold: nil, force: true))
        #expect(!eligible(minutesIdle: 0, active: true, force: true))
    }

    /// The busy check awaits WebKit; a tab shown during that await must not be put to sleep.
    @Test func aTabShownWhileCheckingIsNotPutToSleep() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let registry = try ScriptRegistry(manifestURL: root.appendingPathComponent("injections/manifest.json"))
        let store = TabStore(factory: WebViewFactory(registry: registry, dataStore: .nonPersistent()), router: IPCRouter())
        let background = store.create(url: URL(string: "https://background.invalid/")!)
        let shownMeanwhile = store.create(url: URL(string: "https://shown.invalid/")!)
        store.create(url: URL(string: "https://front.invalid/")!)
        let sleeper = TabSleeper(store: store)
        defer { sleeper.stop() }
        sleeper.isBusy = { tab in
            if tab === shownMeanwhile { store.activate(tab.id) }
            return false
        }
        await sleeper.sweep(force: true)
        #expect(background.isSleeping)
        #expect(!shownMeanwhile.isSleeping && store.activeID == shownMeanwhile.id)
    }

    @Test func sleepingKeepsTheTabsIdentityAndActivationWakesIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let registry = try ScriptRegistry(manifestURL: root.appendingPathComponent("injections/manifest.json"))
        let store = TabStore(factory: WebViewFactory(registry: registry, dataStore: .nonPersistent()), router: IPCRouter())
        let first = store.create(url: URL(string: "https://sleep.invalid/page")!)
        let second = store.create(url: URL(string: "https://other.invalid/")!)
        #expect(store.activeID == second.id)
        first.sleep()
        #expect(first.isSleeping && first.url?.host == "sleep.invalid")
        store.activate(first.id)
        #expect(!first.isSleeping)
    }

    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "lily-sleep-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func sleepSettingsDefaultToTodaysBehaviour() {
        let (defaults, name) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(TabSleeper.sleepsOnMemoryPressure(defaults) && !TabSleeper.keepsPinnedAwake(defaults))
        defaults.set(false, forKey: TabSleeper.Key.onMemoryPressure)
        defaults.set(true, forKey: TabSleeper.Key.keepPinnedAwake)
        #expect(!TabSleeper.sleepsOnMemoryPressure(defaults) && TabSleeper.keepsPinnedAwake(defaults))
    }

    @Test func pinnedTabsStayAwakeWhenAsked() async throws {
        UserDefaults.standard.set(true, forKey: TabSleeper.Key.keepPinnedAwake)
        defer { UserDefaults.standard.removeObject(forKey: TabSleeper.Key.keepPinnedAwake) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let registry = try ScriptRegistry(manifestURL: root.appendingPathComponent("injections/manifest.json"))
        let store = TabStore(factory: WebViewFactory(registry: registry, dataStore: .nonPersistent()), router: IPCRouter())
        let pinned = store.create(url: URL(string: "https://pinned.invalid/")!)
        let plain = store.create(url: URL(string: "https://plain.invalid/")!)
        store.setPinned(pinned.id, true)
        store.create(url: URL(string: "https://front.invalid/")!)
        let sleeper = TabSleeper(store: store)
        defer { sleeper.stop() }
        sleeper.isBusy = { _ in false }
        await sleeper.sweep(force: true)
        #expect(plain.isSleeping && !pinned.isSleeping)
    }
}
