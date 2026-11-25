import Foundation
import Testing
@testable import LilyCore

@Suite @MainActor struct LookalikeWarningTests {
    @Test func warnsOnlyForLookalikes() {
        let fake = URL(string: "https://xn--pple-43d.com/")!
        #expect(LookalikeWarning.verdict(for: fake)?.reason == .mixedScript)
        #expect(LookalikeWarning.verdict(for: URL(string: "https://apple.com/")) == nil)
        #expect(LookalikeWarning.verdict(for: URL(string: "https://xn--mnchen-3ya.de/")) == nil)
        #expect(LookalikeWarning.verdict(for: URL(string: "mailto:a@example.com")) == nil)
    }

    @Test func staysQuietAfterContinuing() {
        let fake = URL(string: "https://xn--ppl-43d.example/")!
        let verdict = LookalikeWarning.verdict(for: fake)
        #expect(verdict != nil)
        LookalikeWarning.allow(verdict!)
        #expect(LookalikeWarning.verdict(for: fake) == nil)
    }

    @Test func explainsTheReasonAndBothSpellings() {
        let verdict = LookalikeDomain.assess(host: "xn--pple-43d.com")!
        let text = LookalikeWarning.explanation(for: verdict)
        #expect(text.contains("different alphabets") && text.contains("xn--pple-43d.com") && text.contains("\u{0430}pple.com"))
    }

    @Test func hiddenCharactersAreShownAsEscapes() {
        let shown = LookalikeWarning.isolated("bank\u{200B}.com")
        #expect(shown == "\u{2068}bank\\u{200B}.com\u{2069}")
    }

    @Test func moreInvisibleCharactersAreEscaped() {
        for scalar in ["\u{2800}", "\u{17B4}", "\u{180B}", "\u{E0100}", "\u{2003}", "\u{E0041}", "\u{200B}"] {
            let shown = LookalikeWarning.isolated("bank\(scalar).com")
            #expect(shown.contains("\\u{"), "\(scalar.unicodeScalars.first!.value)")
        }
        // Ordinary text, including non-Latin letters, is shown as it is.
        #expect(LookalikeWarning.isolated("m\u{00FC}nchen.de") == "\u{2068}m\u{00FC}nchen.de\u{2069}")
    }
}
