import AppKit

/// The warning for addresses that imitate another site (`аpple.com` with a Cyrillic "а"). Detection lives in LilyKit
/// (`LookalikeDomain`); this decides when to ask and remembers "Continue anyway" for the rest of the run.
@MainActor
enum LookalikeWarning {
    /// Hosts the person chose to continue to, until Lily quits. Never saved.
    private(set) static var allowedHosts: Set<String> = []

    /// The verdict to warn about for a main-frame navigation to `url`, nil when it can go ahead. (It must not compare with
    /// the page the tab is "on": by the time the policy is decided for a typed address, the tab's URL already is the target.)
    static func verdict(for url: URL?) -> LookalikeDomain.Verdict? {
        guard let url, let host = url.host?.lowercased() else { return nil }
        // Cheap exit for ordinary addresses: a look-alike needs punycode or non-ASCII letters.
        guard host.contains("xn--") || !host.allSatisfy(\.isASCII) else { return nil }
        // Remembered by the ASCII (punycode) form, the same key `allow` stores, whichever form the URL's host arrives in.
        guard let verdict = LookalikeDomain.assess(url), !allowedHosts.contains(verdict.asciiHost) else { return nil }
        return verdict
    }

    static func allow(_ verdict: LookalikeDomain.Verdict) { allowedHosts.insert(verdict.asciiHost) }

    static func explanation(for verdict: LookalikeDomain.Verdict) -> String {
        let why: String
        switch verdict.reason {
        case .mixedScript: why = "It mixes letters from different alphabets, a trick used to copy a well-known address."
        case .allConfusable: why = "Every letter is from another alphabet but looks like a Latin one, a trick used to copy a well-known address."
        case .malformed: why = "It contains characters that are invalid or invisible."
        }
        return "\(why)\n\nShown as: \(isolated(verdict.displayHost))\nReal address: \(verdict.asciiHost)"
    }

    /// The host is attacker-controlled: invisible and bidi-control characters are shown as \u{…} escapes, and the whole
    /// host sits in Unicode isolates so it can't reorder the text around it.
    static func isolated(_ host: String) -> String {
        let visible = host.unicodeScalars.map { scalar -> String in
            hidden(scalar) ? "\\u{\(String(scalar.value, radix: 16, uppercase: true))}" : String(scalar)
        }.joined()
        return "\u{2068}\(visible)\u{2069}"
    }

    /// Characters that show as nothing or as a blank: format and control characters, every kind of space and separator,
    /// private-use and unassigned code points, variation selectors, tags, and the blank-looking fillers.
    static func hidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .format, .control, .spaceSeparator, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate: return true
        default: break
        }
        let v = scalar.value
        return (0xFE00...0xFE0F).contains(v) || (0xE0100...0xE01EF).contains(v) || (0xE0000...0xE007F).contains(v)
            || (0x180B...0x180F).contains(v) || [0x34F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0].contains(v)
    }

    enum Outcome { case allowed, declined, couldNotAsk }

    /// Asks in a sheet on the tab's window. `couldNotAsk` when there is no window to ask in (a background tab) or another
    /// sheet is already up: the navigation is still stopped, and the caller says so and offers to open it anyway.
    static func confirm(_ verdict: LookalikeDomain.Verdict, in window: NSWindow?) async -> Outcome {
        guard let window, window.attachedSheet == nil else { return .couldNotAsk }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This address may be imitating another site"
        alert.informativeText = explanation(for: verdict)
        // "Cancel" is the safe default and takes both keys: Return is its key equivalent, and Escape is handled below.
        // (NSAlert gives a button one key only, and a first button titled "Cancel" gets only Escape. Before, a custom
        // Escape key on "Go Back" left the sheet with no default at all, so Return did nothing.)
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\r"
        alert.addButton(withTitle: "Continue Anyway").hasDestructiveAction = true // the risky choice, marked as such
        // Escape (or Command-period) cancels while this sheet is up, and only for the sheet's own window; the monitor exists
        // only for that long.
        let sheet = alert.window
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let cancels = (event.keyCode == 53 && flags.isEmpty) || (event.charactersIgnoringModifiers == "." && flags == .command)
            let target = event.window
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard cancels, target === sheet, window.attachedSheet === sheet else { return false }
                window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                return true
            }
            return handled ? nil : event
        }
        let response = await alert.beginSheetModal(for: window)
        if let monitor { NSEvent.removeMonitor(monitor) }
        guard response == .alertSecondButtonReturn else { return .declined }
        allow(verdict)
        return .allowed
    }
}
