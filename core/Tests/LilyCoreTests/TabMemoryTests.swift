import Testing
import WebKit
@testable import LilyCore

@MainActor
struct TabMemoryTests {
    @Test func footprintOfLoadedWebViewIsReal() async throws {
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 100, height: 100))
        _ = try await view.loadHTMLStringAndWait("<p>hi</p>")
        let bytes = try #require(TabMemory.footprint(of: view))
        #expect(bytes > 1_000_000 && bytes < 4_000_000_000)
    }
}

private extension WKWebView {
    func loadHTMLStringAndWait(_ html: String) async throws -> Bool {
        loadHTMLString(html, baseURL: nil)
        for _ in 0..<100 where isLoading || estimatedProgress < 1 { try await Task.sleep(for: .milliseconds(50)) }
        return true
    }
}
