import Testing
@testable import LilyCore

@Suite struct AppLockTests {
    @Test func offByDefaultAndNeverAsks() async {
        var asked = false
        #expect(await AppLock.gate(enabled: false) { asked = true; return false } == .unlocked)
        #expect(!asked)
        #expect(!AppLock.isEnabled)
    }

    @Test func opensOnlyWhenTheOwnerAuthenticates() async {
        #expect(await AppLock.gate(enabled: true) { true } == .unlocked)
        #expect(await AppLock.gate(enabled: true) { false } == .denied)
    }

    /// A Mac with no password or Touch ID can't prove anything: the lock must not lock the owner out.
    @Test func unavailableAuthenticationDoesNotLockOut() async {
        #expect(await AppLock.gate(enabled: true) { nil } == .unlocked)
    }
}
