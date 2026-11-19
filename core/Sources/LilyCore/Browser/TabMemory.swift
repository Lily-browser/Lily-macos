import Darwin
import Foundation
import WebKit

/// Real memory use of a tab: the physical footprint of its web content process, read once when the
/// hover preview opens (never polled). Reading never creates or wakes a web view.
enum TabMemory {
    /// Bytes, or nil when WebKit doesn't expose the process or macOS refuses the read.
    @MainActor static func footprint(of webView: WKWebView) -> UInt64? {
        // Non-public WebKit property, used only after checking it exists (like WebInspector).
        guard webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
              let number = webView.value(forKey: "_webProcessIdentifier") as? NSNumber else { return nil }
        let pid = number.int32Value
        guard pid > 0 else { return nil }
        // proc_pid_rusage writes a `rusage_info_v0` through a `rusage_info_t *`; an array of
        // pointer-sized slots (64 × 8 bytes, more than the struct) receives it without unsafe types.
        var slots = [rusage_info_t?](repeating: nil, count: 64)
        guard proc_pid_rusage(pid, RUSAGE_INFO_V0, &slots) == 0 else { return nil }
        // ri_phys_footprint follows uuid(16) and seven 8-byte counters.
        return slots.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 72, as: UInt64.self) }
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .memory)
    }
}
