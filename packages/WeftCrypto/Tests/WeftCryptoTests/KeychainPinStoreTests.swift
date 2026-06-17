import XCTest
@testable import WeftCrypto

/// Exercises the production Keychain pin store. Each test uses a unique service
/// string so it never touches real pins, and cleans up after itself. When the
/// Keychain is unavailable (unsigned `swift test` binary -> errSecMissingEntitlement)
/// the tests XCTSkip rather than fail.
final class KeychainPinStoreTests: XCTestCase {
    private var service = ""
    private var store: KeychainTofuPinStore!
    private var keychainAvailable = false

    override func setUpWithError() throws {
        service = "com.weft.e2ee.test.\(UUID().uuidString)"
        store = KeychainTofuPinStore(service: service)
        // Probe: a write that succeeds means the Keychain is usable here.
        do {
            _ = try store.verifyThrowing(ownerUserId: "__probe__", presentedSigningKid: "probeKid")
            try store.unpinThrowing(ownerUserId: "__probe__")
            keychainAvailable = true
        } catch {
            keychainAvailable = false
        }
    }

    override func tearDownWithError() throws {
        for owner in ["owner1", "__probe__"] {
            try? store.unpinThrowing(ownerUserId: owner)
        }
    }

    func testFirstUseThenMatchThenMismatchKeepsOriginalPin() throws {
        try XCTSkipUnless(keychainAvailable, "Keychain unavailable (likely unsigned test binary)")
        XCTAssertEqual(try store.verifyThrowing(ownerUserId: "owner1", presentedSigningKid: "kidA"),
                       .pinnedOnFirstUse)
        XCTAssertEqual(try store.verifyThrowing(ownerUserId: "owner1", presentedSigningKid: "kidA"),
                       .match)
        // A changed key must NOT overwrite the pin.
        XCTAssertEqual(try store.verifyThrowing(ownerUserId: "owner1", presentedSigningKid: "kidB"),
                       .mismatch(pinnedKid: "kidA"))
        XCTAssertEqual(try store.pinnedKidThrowing(for: "owner1"), "kidA")
    }

    func testUnpinAllowsRepin() throws {
        try XCTSkipUnless(keychainAvailable, "Keychain unavailable (likely unsigned test binary)")
        _ = try store.verifyThrowing(ownerUserId: "owner1", presentedSigningKid: "kidA")
        try store.unpinThrowing(ownerUserId: "owner1")
        XCTAssertNil(try store.pinnedKidThrowing(for: "owner1"))
        XCTAssertEqual(try store.verifyThrowing(ownerUserId: "owner1", presentedSigningKid: "kidB"),
                       .pinnedOnFirstUse)
    }

    /// Complements the three Keychain round-trip tests: this one runs precisely
    /// when the Keychain is NOT usable, exercising the non-throwing protocol's
    /// fail-closed branch (a Keychain error must surface as `.mismatch`, never as
    /// silent trust).
    func testProtocolVerifyFailsClosedWhenKeychainUnavailable() throws {
        try XCTSkipUnless(!keychainAvailable, "Keychain is available; fail-closed branch not exercised here")
        XCTAssertEqual(store.verify(ownerUserId: "owner1", presentedSigningKid: "kidA"),
                       .mismatch(pinnedKid: "<keychain-unavailable>"))
    }

    func testOwnersAreIndependent() throws {
        try XCTSkipUnless(keychainAvailable, "Keychain unavailable (likely unsigned test binary)")
        XCTAssertEqual(try store.verifyThrowing(ownerUserId: "owner1", presentedSigningKid: "kidA"),
                       .pinnedOnFirstUse)
        // A different owner pinning a different kid does not collide.
        XCTAssertEqual(try store.verifyThrowing(ownerUserId: "__probe__", presentedSigningKid: "kidX"),
                       .pinnedOnFirstUse)
        XCTAssertEqual(try store.pinnedKidThrowing(for: "owner1"), "kidA")
    }
}
