import AppKit

extension AppIconVariant: StoredChoice {
    static let `default` = AppIconVariant.iris
}

/// Settings → Appearance → Icon: shows the chosen icon in the Dock and ⌘-Tab while Lily runs, in
/// its dark rendering when the app's appearance is dark (the system's, or Lily's own Theme).
/// macOS keeps the bundle's icon for Finder and for the Dock while Lily is closed; changing that
/// would mean modifying the signed app. The default icon in light appearance draws nothing at
/// all: the bundle's own icon is used, so a default install pays nothing at launch.
@MainActor
final class AppIconController {
    enum Key {
        static let variant = "AppIconVariant"
        static let matchesDarkMode = "AppIconMatchesDarkMode"
    }

    struct Choice: Equatable {
        let variant: AppIconVariant
        let dark: Bool
    }

    /// What the running app's icon should be; nil means the bundle's own icon.
    static func choice(variant: AppIconVariant, matchesDarkMode: Bool, systemIsDark: Bool) -> Choice? {
        let dark = matchesDarkMode && systemIsDark
        return variant == .default && !dark ? nil : Choice(variant: variant, dark: dark)
    }

    private(set) var applied: Choice?
    private var appearanceObservation: NSKeyValueObservation?
    private var defaultsObserver: NSObjectProtocol?
    private static var previews: [String: NSImage] = [:]

    /// Applies the saved choice, then follows the appearance and the setting. Both are events, so
    /// nothing runs while the icon isn't changing.
    func start() {
        apply()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.apply() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.apply() }
        }
    }

    func apply(defaults: UserDefaults = .standard) {
        let systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let wanted = Self.choice(variant: AppIconVariant.current(Key.variant, in: defaults),
                                 matchesDarkMode: defaults.object(forKey: Key.matchesDarkMode) as? Bool ?? true,
                                 systemIsDark: systemIsDark)
        guard wanted != applied else { return } // any other setting changing also lands here
        applied = wanted
        NSApp.applicationIconImage = wanted.map { AppIconArt.image(variant: $0.variant, dark: $0.dark, points: 256) }
    }

    /// Small previews for the Settings tiles, drawn once each.
    static func preview(_ variant: AppIconVariant, dark: Bool) -> NSImage {
        let key = "\(variant.rawValue)-\(dark)"
        if let cached = previews[key] { return cached }
        let image = AppIconArt.image(variant: variant, dark: dark, points: 64)
        previews[key] = image
        return image
    }
}
