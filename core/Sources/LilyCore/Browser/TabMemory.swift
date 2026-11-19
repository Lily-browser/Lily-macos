import Darwin
import Foundation
import WebKit

/// Real memory use of a tab: the resident memory of its web content process, read once when the
/// hover preview opens (never polled). Reading never creates or wakes a web view.
enum TabMemory {
    /// Bytes, or nil when WebKit doesn't expose the process or macOS refuses the read.
    @MainActor static func footprint(of webView: WKWebView) -> UInt64? {
        // Non-public WebKit property, used only after checking it exists (like WebInspector).
        guard webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let number = webView.value(forKey: "_webProcessIdentifier") as? NSNumber else { return nil }
        let pid = number.int32Value
        guard pid > 0 else { return nil }
        // The sandbox refuses proc_pid_rusage on other processes (EPERM) but allows proc_pidinfo, so
        // report the resident size of the web content process.
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info.pti_resident_size
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .memory)
    }
}
