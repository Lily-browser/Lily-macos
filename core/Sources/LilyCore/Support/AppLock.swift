import Foundation
import LocalAuthentication

/// Optional lock on opening Lily (Settings → Privacy → "Require authentication to open Lily"): before any saved data
/// (session, history, bookmarks) is read, the Mac's owner has to authenticate with Touch ID, or the login password
/// where there is no Touch ID. Off by default. It guards what Lily seals itself; WebKit's own website data
/// (cookies, site storage) is not covered by it.
enum AppLock {
    static let key = "RequireAuthToOpen"
    static var isEnabled: Bool { Preferences.flag(key, default: false) }

    enum Outcome: Equatable { case unlocked, denied }

    /// Whether Lily may open. `authenticate` returns nil when the Mac can't authenticate at all (no password set), so
    /// the lock never locks you out of your own data; true or false is the person's answer.
    static func gate(enabled: Bool = isEnabled, authenticate: () async -> Bool? = { await systemAuthenticate(reason: "Unlock Lily to open your tabs, history and bookmarks.", cancelTitle: "Quit") }) async -> Outcome {
        guard enabled else { return .unlocked }
        guard let answer = await authenticate() else {
            Log.app.error("Lock requested but this Mac can't authenticate; opening without it")
            return .unlocked
        }
        return answer ? .unlocked : .denied
    }

    /// Touch ID, with the account password as the fallback. Nil when the policy can't be evaluated.
    static func systemAuthenticate(reason: String, cancelTitle: String? = nil) async -> Bool? {
        let context = LAContext()
        if let cancelTitle { context.localizedCancelTitle = cancelTitle }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return nil }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
