import Foundation
import Testing
@testable import LilyCore

@Suite @MainActor struct InstallDialogTests {
    @Test func everyWayOfSayingAllSitesIsRecognised() {
        for pattern in ["<all_urls>", "*://*/*", "https://*/*", "http://*/*"] { #expect(ExtensionLibrary.coversAllSites(pattern), "\(pattern)") }
        for pattern in ["https://example.com/*", "*://*.example.com/*", "https://*.example.com/*"] { #expect(!ExtensionLibrary.coversAllSites(pattern), "\(pattern)") }
    }

    @Test func aLongHostListIsCountedNotCut() {
        let hosts = (1...9).map { "https://site\($0).example/*" }
        let summary = ExtensionLibrary.hostAccessSummary(hosts)!
        #expect(summary.contains("9 site patterns") && summary.contains("and 3 more"))
        #expect(ExtensionLibrary.hostAccessSummary(["https://*/*"]) == "• Read and change all your data on all websites")
        #expect(ExtensionLibrary.hostAccessSummary([]) == nil)
    }

    @Test func anUpdateListsOnlyWhatIsNew() {
        let added = ExtensionLibrary.addedAccess(old: (["storage"], ["https://a.example/*"]),
                                                 new: (["storage", "cookies"], ["https://a.example/*", "https://b.example/*"]))
        #expect(added.count == 2 && added[0].contains("cookies") && added[1].contains("b.example"))
        #expect(ExtensionLibrary.addedAccess(old: (["storage"], ["https://a.example/*"]), new: (["storage"], ["https://a.example/*"])).isEmpty)
        let widened = ExtensionLibrary.addedAccess(old: ([], ["https://a.example/*"]), new: ([], ["<all_urls>"]))
        #expect(widened == ["Read and change all your data on all websites"])
    }
}
