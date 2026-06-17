import XCTest
@testable import WeftCrypto

final class PinStoreTests: XCTestCase {

    func testTofuFirstUseThenMatch() {
        let store = InMemoryTofuPinStore()
        XCTAssertNil(store.pinnedSigningKid(for: "owner-1"))

        XCTAssertEqual(store.verify(ownerUserId: "owner-1", presentedSigningKid: "kidA"),
                       .pinnedOnFirstUse)
        XCTAssertEqual(store.pinnedSigningKid(for: "owner-1"), "kidA")

        // Same kid later -> match.
        XCTAssertEqual(store.verify(ownerUserId: "owner-1", presentedSigningKid: "kidA"), .match)
    }

    func testTofuMismatchDoesNotOverwrite() {
        let store = InMemoryTofuPinStore()
        _ = store.verify(ownerUserId: "owner-1", presentedSigningKid: "kidA")

        // A changed key -> mismatch, and the original pin is preserved.
        XCTAssertEqual(store.verify(ownerUserId: "owner-1", presentedSigningKid: "kidEVIL"),
                       .mismatch(pinnedKid: "kidA"))
        XCTAssertEqual(store.pinnedSigningKid(for: "owner-1"), "kidA")
    }

    func testRequireTrustedThrowsOnMismatch() {
        let store = InMemoryTofuPinStore()
        XCTAssertNoThrow(try store.requireTrusted(ownerUserId: "o", presentedSigningKid: "good"))
        XCTAssertNoThrow(try store.requireTrusted(ownerUserId: "o", presentedSigningKid: "good"))
        XCTAssertThrowsError(try store.requireTrusted(ownerUserId: "o", presentedSigningKid: "bad")) { err in
            XCTAssertEqual(err as? WeftCryptoError,
                           .pinMismatch(owner: "o", pinnedKid: "good", presentedKid: "bad"))
        }
    }

    func testUnpinAllowsRePin() {
        let store = InMemoryTofuPinStore()
        _ = store.verify(ownerUserId: "o", presentedSigningKid: "kidA")
        store.unpin(ownerUserId: "o")
        XCTAssertNil(store.pinnedSigningKid(for: "o"))
        XCTAssertEqual(store.verify(ownerUserId: "o", presentedSigningKid: "kidB"), .pinnedOnFirstUse)
    }

    /// Integration: pin the bootstrapped signing kid, then catch a substituted roster.
    func testPinIntegrationWithBootstrappedIdentity() throws {
        let store = InMemoryTofuPinStore()
        let real = UserIdentity.generate()
        let (signing, _) = try real.signedRoster(ownerUserId: "student-1")

        XCTAssertEqual(store.verify(ownerUserId: "student-1", presentedSigningKid: signing.kid),
                       .pinnedOnFirstUse)

        // Operator substitutes a different signing key for the same owner.
        let forged = UserIdentity.generate()
        let (forgedSigning, _) = try forged.signedRoster(ownerUserId: "student-1")
        XCTAssertEqual(store.verify(ownerUserId: "student-1", presentedSigningKid: forgedSigning.kid),
                       .mismatch(pinnedKid: signing.kid))
    }
}
