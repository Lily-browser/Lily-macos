import Foundation
import Testing
@testable import LilyCore

@Suite @MainActor struct LookalikeWarningTests {
    @Test func warnsOnlyForLookalikes() {
        let fake = URL(string: "https://xn--pple-43d.com/")!
        #expect(LookalikeWarning.verdict(for: fake, from: nil)?.reason == .mixedScript)
        #expect(LookalikeWarning.verdict(for: URL(string: "https://apple.com/"), from: nil) == nil)
        #expect(LookalikeWarning.verdict(for: URL(string: "https://xn--mnchen-3ya.de/"), from: nil) == nil)
        #expect(LookalikeWarning.verdict(for: URL(string: "mailto:a@example.com"), from: nil) == nil)
    }

    @Test func staysQuietWithinTheSamePageAndAfterContinuing() {
        let fake = URL(string: "https://xn--ppl-43d.example/")!
        let verdict = LookalikeWarning.verdict(for: fake, from: nil)
        #expect(verdict != nil)
        #expect(LookalikeWarning.verdict(for: fake, from: fake) == nil) // already on it
        LookalikeWarning.allow(verdict!)
        #expect(LookalikeWarning.verdict(for: fake, from: nil) == nil)
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
}
