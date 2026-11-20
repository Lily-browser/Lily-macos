import AppKit
import WebKit

/// Keeps WebKit's inspector in its own window.
///
/// WebKit docks the inspector by adding its view next to the web view in the same container and
/// resizing the web view to make room. Lily pins every web view to its pane with Auto Layout, so
/// the two fight on every layout pass: the page flashes and the inspector is covered (grey).
/// Detaching it gives the inspector a window of its own and leaves the pane alone. WebKit attaches
/// a moment after it is asked to open, and `detach` only works once it has, so this waits for the
/// inspector view to appear (one frame at a time, at most about two seconds) and then detaches.
///
/// `_inspector` and `detach` are non-public WebKit; each is used only after checking it exists, so
/// without them the inspector simply stays docked.
@MainActor
enum InspectorWindow {
    private static let attachTimeout = 120 // frames

    /// Call right after the inspector was asked to open (Inspect Element, Show Web Inspector).
    static func keepDetached(for webView: WKWebView) {
        guard let container = webView.superview else { return }
        Task { @MainActor [weak webView, weak container] in
            for _ in 0..<attachTimeout {
                try? await Task.sleep(for: .milliseconds(16))
                guard let webView, let container else { return }
                if hasDockedInspector(in: container) { detach(webView); return }
            }
        }
    }

    static func hasDockedInspector(in container: NSView) -> Bool {
        container.subviews.contains { String(describing: type(of: $0)).contains("Inspector") }
    }

    private static func detach(_ webView: WKWebView) {
        let detach = NSSelectorFromString("detach")
        guard webView.responds(to: NSSelectorFromString("_inspector")),
              let inspector = webView.value(forKey: "_inspector") as? NSObject,
              inspector.responds(to: detach) else { return }
        _ = inspector.perform(detach)
    }
}
