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
        return "\(why)\n\nAddress: \(isolated(verdict.displayHost))\nAs the network sees it: \(verdict.asciiHost)"
    }

    /// The host is attacker-controlled: invisible and bidi-control characters are shown as \u{…} escapes, and the whole
    /// host sits in Unicode isolates so it can't reorder the text around it.
    static func isolated(_ host: String) -> String {
        let visible = host.unicodeScalars.map { scalar -> String in
            let hidden = scalar.properties.generalCategory == .format || scalar.properties.generalCategory == .control
                || (0xFE00...0xFE0F).contains(scalar.value) || [0x34F, 0x115F, 0x1160, 0x3164, 0xFFA0].contains(scalar.value)
            return hidden ? "\\u{\(String(scalar.value, radix: 16, uppercase: true))}" : String(scalar)
        }.joined()
        return "\u{2068}\(visible)\u{2069}"
    }

    /// Asks in a sheet on the tab's window; true to continue. No window to ask in (a background tab) means no.
    static func confirm(_ verdict: LookalikeDomain.Verdict, in window: NSWindow?) async -> Bool {
        guard let window, window.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This address may be imitating another site"
        alert.informativeText = explanation(for: verdict)
        alert.addButton(withTitle: "Go Back").keyEquivalent = "\u{1b}" // Escape leaves the sheet
        alert.addButton(withTitle: "Continue Anyway")
        let response = await alert.beginSheetModal(for: window)
        guard response == .alertSecondButtonReturn else { return false }
        allow(verdict)
        return true
    }
}
