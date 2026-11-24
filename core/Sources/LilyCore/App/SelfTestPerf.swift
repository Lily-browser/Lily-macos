import AppKit
import Darwin

/// Opt-in (`LILY_SELFTEST_PERF=1`, or a tab count such as `=50`) part of the self-test that measures the real sidebar (SwiftUI `List` over AppKit's
/// outline view) with 5,000 unopened tabs: how long it takes to appear, what a scroll costs per frame, and what an idle
/// window costs in CPU and context switches. `make perf` covers the model; this covers the views (#148). It reports
/// numbers, not a pass/fail: the question it answers is whether moving a piece to AppKit could measurably help.
@MainActor
enum PerfHarness {
    private struct Usage {
        var cpuSeconds: Double
        var contextSwitches: Int
        var peakMB: Double
        init() {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            cpuSeconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
            contextSwitches = usage.ru_nvcsw + usage.ru_nivcsw
            peakMB = Double(usage.ru_maxrss) / 1_048_576
        }
    }

    private static func ms(_ since: Date) -> Double { (Date().timeIntervalSince(since) * 1000 * 10).rounded() / 10 }

    static func run(window: BrowserWindowController, tabCount: Int = 5000) async -> [String: JSONValue] {
        var detail: [String: JSONValue] = ["tabs": .number(Double(tabCount))]
        window.window?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        let baseline = Usage()
        detail["baselinePeakMB"] = .number(baseline.peakMB.rounded())

        var started = Date()
        // The way a session comes back at launch: every tab asleep, none with a web view.
        let entries = (0..<tabCount).map { SessionStore.Session.Entry(url: URL(string: "https://perf.selftest.lily.test/\($0)")!, title: "Perf tab \($0)", pinned: false) }
        window.tabs.restore(SessionStore.Session(tabs: entries, activeIndex: 0, spaces: nil, currentSpace: nil))
        detail["restoreMs"] = .number(ms(started))

        // Until the list has its rows (SwiftUI diffs and AppKit lays them out on the main thread).
        started = Date()
        var table: NSTableView?
        for _ in 0..<600 {
            if let content = window.window?.contentView, let found = DragHarness.list(in: content), found.numberOfRows >= tabCount { table = found; break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        detail["listReadyMs"] = .number(ms(started))
        guard let table, let scroll = table.enclosingScrollView else { detail["error"] = "sidebar list not found"; return detail }
        detail["rows"] = .number(Double(table.numberOfRows))

        // Scrolling the whole list in 100 steps, drawing each one.
        let height = table.bounds.height - scroll.contentView.bounds.height
        var steps: [Double] = []
        for step in 0...100 {
            let began = Date()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: height * Double(step) / 100))
            scroll.reflectScrolledClipView(scroll.contentView)
            window.window?.displayIfNeeded()
            steps.append(Date().timeIntervalSince(began) * 1000)
        }
        steps.sort()
        detail["scrollStepMedianMs"] = .number((steps[steps.count / 2] * 10).rounded() / 10)
        detail["scrollStepWorstMs"] = .number((steps.last! * 10).rounded() / 10)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)

        // Idle: how long until the process goes quiet (under 100 ms of CPU per second), then 5 seconds of true idle.
        let quietFrom = Date()
        var quiet = false
        for _ in 0..<90 {
            let first = Usage()
            try? await Task.sleep(for: .seconds(1))
            if Usage().cpuSeconds - first.cpuSeconds < 0.1 { quiet = true; break }
        }
        detail["secondsUntilQuiet"] = .number(((Date().timeIntervalSince(quietFrom)) * 10).rounded() / 10)
        detail["reachedQuiet"] = .bool(quiet)
        let before = Usage()
        try? await Task.sleep(for: .seconds(5))
        let after = Usage()
        detail["idleCPUMsPerSecond"] = .number(((after.cpuSeconds - before.cpuSeconds) / 5 * 1000 * 10).rounded() / 10)
        detail["idleContextSwitchesPerSecond"] = .number(Double(after.contextSwitches - before.contextSwitches) / 5)
        detail["peakMBAfter"] = .number(after.peakMB.rounded())
        detail["webViews"] = .number(Double(window.tabs.tabs.filter(\.hasWebView).count))
        return detail
    }
}
