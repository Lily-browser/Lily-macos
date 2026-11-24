import Foundation
import Testing
import WebKit
@testable import LilyCore

@Suite @MainActor struct SensitiveSiteExtensionTests {
    @Test func listsSensitiveHostsFromStoredKeys() {
        let sites: [String: SiteSettings.Site] = [
            "bank.example": .init(sensitive: true), "http://old.example": .init(sensitive: true),
            "shop.example:8443": .init(sensitive: true), "news.example": .init(zoom: 1.2), "off.example": .init(sensitive: false),
        ]
        if #available(macOS 15.4, *) {
            #expect(ExtensionManager.sensitiveHosts(in: sites) == ["bank.example", "old.example", "shop.example"])
        }
    }

    /// A denied site wins over a broad grant, for the site and its subdomains only, and releasing it restores access.
    @Test func denialBeatsAnAllUrlsGrant() async throws {
        guard #available(macOS 15.4, *) else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lily-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "All Sites", "version": "1", "host_permissions": ["<all_urls>"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: dir))
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        try controller.load(context)
        defer { try? controller.unload(context) }
        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "<all_urls>"))
        let bank = URL(string: "https://online.bank.example/login")!, other = URL(string: "https://news.example/")!
        #expect(context.permissionStatus(for: bank).rawValue > 0)
        let patterns = try ["*://bank.example/*", "*://*.bank.example/*"].map { try WKWebExtension.MatchPattern(string: $0) }
        for p in patterns { context.setPermissionStatus(.deniedExplicitly, for: p) }
        #expect(context.permissionStatus(for: bank) == .deniedExplicitly)
        #expect(context.permissionStatus(for: URL(string: "https://bank.example/")!) == .deniedExplicitly)
        #expect(context.permissionStatus(for: other).rawValue > 0)
        for p in patterns { context.setPermissionStatus(.unknown, for: p) }
        #expect(context.permissionStatus(for: bank).rawValue > 0)
    }
}
