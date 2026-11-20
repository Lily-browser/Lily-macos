import AppKit
import SwiftUI

/// A choice stored in UserDefaults as its raw string. Anything unknown (or unset) reads as
/// `default`, which is always how Lily looked and behaved before the setting existed.
protocol StoredChoice: RawRepresentable, CaseIterable, Sendable where RawValue == String {
    static var `default`: Self { get }
}

extension StoredChoice {
    init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .default }

    /// The current choice in the standard defaults.
    static func current(_ key: String, in defaults: UserDefaults = .standard) -> Self {
        Self(stored: defaults.string(forKey: key))
    }
}

// MARK: - Look (Settings → Appearance)

/// Which side of the window the sidebar sits on.
enum SidebarPosition: String, StoredChoice {
    case left, right
    static let `default` = SidebarPosition.left
    var label: String { rawValue.capitalized }
}

/// The typeface family for the sidebar and the command bar.
enum InterfaceFont: String, StoredChoice {
    case system, rounded, serif, monospaced
    static let `default` = InterfaceFont.system
    var label: String { rawValue.capitalized }

    var design: Font.Design {
        switch self {
        case .system: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }
}

/// Vertical room per tab row, on top of the sidebar text size.
enum TabDensity: String, StoredChoice {
    case compact, standard, spacious
    static let `default` = TabDensity.standard
    var label: String { rawValue.capitalized }

    var extraHeight: CGFloat {
        switch self {
        case .compact: return -4
        case .standard: return 0
        case .spacious: return 6
        }
    }
}

/// When a tab row shows its close button.
enum CloseButtonVisibility: String, StoredChoice {
    case hover, always, never
    static let `default` = CloseButtonVisibility.hover

    var label: String {
        switch self {
        case .hover: return "On Hover"
        case .always: return "Always"
        case .never: return "Never"
        }
    }

    func shows(hovering: Bool) -> Bool {
        switch self {
        case .hover: return hovering
        case .always: return true
        case .never: return false
        }
    }
}

/// How much the page behind the open command bar is blurred.
enum CommandBarBlur: String, StoredChoice {
    case off, light, strong
    static let `default` = CommandBarBlur.light
    var label: String { rawValue.capitalized }
}

enum CommandBarPosition: String, StoredChoice {
    case top, center
    static let `default` = CommandBarPosition.top
    var label: String { rawValue.capitalized }
    /// The bar's distance from the top of the window in the Top position.
    static let topInset: CGFloat = 96
}

enum CommandBarWidth: String, StoredChoice {
    case narrow, standard, wide
    static let `default` = CommandBarWidth.standard
    var label: String { rawValue.capitalized }

    var points: CGFloat {
        switch self {
        case .narrow: return 560
        case .standard: return 680
        case .wide: return 820
        }
    }
}

/// Everything a tab row needs to draw itself, read once by the tab list and handed down as a
/// value: thousands of rows never each observe UserDefaults.
struct SidebarRowStyle: Equatable {
    var textSize: SidebarTextSize = .default
    var density: TabDensity = .default
    var closeButton: CloseButtonVisibility = .default
    var dimsSleepingTabs = true

    var rowHeight: CGFloat { textSize.rowHeight + density.extraHeight }
    var titleSize: CGFloat { textSize.titleSize }
    var favicon: CGFloat { textSize.favicon }
}

/// The rounded cards web pages are shown in, and the margin around them.
struct PageStyle: Equatable {
    static let defaultCornerRadius: Double = 10
    static let defaultPadding: Double = 8
    static let cornerRadiusRange: ClosedRange<Double> = 0...16
    static let paddingRange: ClosedRange<Double> = 0...12

    var cornerRadius: CGFloat
    var padding: CGFloat
    var sidebarOnRight: Bool

    /// The margin on the side next to the sidebar, which already has its divider: a quarter of
    /// the outer padding (2 pt at the default 8).
    var sidebarSidePadding: CGFloat { (padding / 4).rounded() }
    var leading: CGFloat { sidebarOnRight ? padding : sidebarSidePadding }
    var trailing: CGFloat { sidebarOnRight ? sidebarSidePadding : padding }

    static func current(_ defaults: UserDefaults = .standard) -> PageStyle {
        func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> CGFloat {
            let value = defaults.object(forKey: key) as? Double ?? fallback
            return CGFloat(min(range.upperBound, max(range.lowerBound, value)))
        }
        return PageStyle(cornerRadius: number(AppearanceStyle.Key.pageCornerRadius, defaultCornerRadius, cornerRadiusRange),
                         padding: number(AppearanceStyle.Key.pagePadding, defaultPadding, paddingRange),
                         sidebarOnRight: SidebarPosition.current(AppearanceStyle.Key.sidebarPosition, in: defaults) == .right)
    }
}

/// Settings → Appearance → Pinned tabs: columns in the pinned grid; 0 fits as many as the width allows.
enum PinnedColumns {
    static let automatic = 0
    static let choices = [automatic, 2, 3, 4]

    static func clamped(_ stored: Int) -> Int { choices.contains(stored) ? stored : automatic }
}

// MARK: - Behaviour

/// What ⌘T (and the New Tab buttons) do.
enum NewTabAction: String, StoredChoice {
    /// The command bar, to type where to go; the tab opens when you pick something.
    case commandBar
    /// A new tab showing the homepage (blank when no homepage is set).
    case homepage
    /// An empty new tab.
    case blank
    static let `default` = NewTabAction.commandBar

    var label: String {
        switch self {
        case .commandBar: return "Command bar"
        case .homepage: return "New tab with homepage"
        case .blank: return "Blank new tab"
        }
    }

    /// What to do: open the command bar, or create a tab with this URL (nil: blank).
    enum Effect: Equatable {
        case showCommandBar
        case openTab(URL?)
    }

    func effect(homepage: URL?) -> Effect {
        switch self {
        case .commandBar: return .showCommandBar
        case .homepage: return .openTab(homepage)
        case .blank: return .openTab(nil)
        }
    }
}

/// Settings → General → Confirm before quitting.
enum QuitConfirmation {
    static let tabThreshold = 10

    /// Asks only when there's something to lose at a glance: two or more windows, or many tabs.
    static func shouldAsk(enabled: Bool, windows: Int, tabs: Int) -> Bool {
        enabled && (windows >= 2 || tabs >= tabThreshold)
    }
}

// MARK: - Reset

/// Settings → General → Reset All Settings to Defaults…: how Lily looks and works. Never your
/// data or your privacy choices: history, extensions, site settings, search engine, homepage,
/// the privacy switches and the assistant's host are left alone.
enum Customization {
    static let lookKeys: [String] = [
        AppearanceStyle.Key.accent, AppearanceStyle.Key.sidebarTint, AppearanceStyle.Key.tintStrength,
        AppearanceStyle.Key.grain, AppearanceStyle.Key.appAppearance, AppearanceStyle.Key.sidebarTextSize,
        AppearanceStyle.Key.sidebarPosition, AppearanceStyle.Key.interfaceFont, AppearanceStyle.Key.tabDensity,
        AppearanceStyle.Key.closeButton, AppearanceStyle.Key.dimSleepingTabs, AppearanceStyle.Key.showsAddressField,
        AppearanceStyle.Key.footerAssistant, AppearanceStyle.Key.footerHistory, AppearanceStyle.Key.footerDownloads,
        AppearanceStyle.Key.footerNewTab, AppearanceStyle.Key.pageCornerRadius, AppearanceStyle.Key.pagePadding,
        AppearanceStyle.Key.commandBarBlur, AppearanceStyle.Key.commandBarPosition, AppearanceStyle.Key.commandBarWidth,
        AppearanceStyle.Key.pinnedColumns,
    ]

    static let behaviourKeys: [String] = [
        Preferences.Key.newTabsNextToCurrent, Preferences.Key.sleepTabsAfter, Preferences.Key.pauseIdlePanesAfter,
        Preferences.Key.haptics, Preferences.Key.linksOpenInLittleLily, Preferences.Key.defaultZoom,
        Preferences.Key.defaultDarkMode, Preferences.Key.newTabAction, Preferences.Key.afterClosingTab,
        Preferences.Key.linksOpenInBackground, Preferences.Key.confirmBeforeQuitting, Preferences.Key.swipeBetweenSpaces,
    ]

    static var allKeys: [String] { lookKeys + behaviourKeys }

    static func reset(_ keys: [String] = allKeys, in defaults: UserDefaults = .standard) {
        keys.forEach(defaults.removeObject(forKey:))
    }

    /// Asks first, then resets and applies the app-wide parts (windows follow on their own).
    @MainActor
    static func confirmAndResetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings to their defaults?"
        alert.informativeText = "How Lily looks and works goes back to how it came: appearance, sidebar, tabs, command bar and website defaults. Your history, bookmarks, extensions, site settings, search engine, homepage and privacy choices are kept."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        reset()
        AppearanceStyle.applyAppAppearance()
        Haptics.step()
    }
}
