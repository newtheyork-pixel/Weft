import XCTest
import CryptoKit
@testable import WeftCrypto

final class SecureEnclaveStoreTests: XCTestCase {

    private let aadA = Data("weft-device-identity/v1\u{0}accountA".utf8)
    private let aadB = Data("weft-device-identity/v1\u{0}accountB".utf8)

    // MARK: ECIES core — runs headless using a SOFTWARE key in place of the SE key.

    func testWrapUnwrapRoundTrip() throws {
        let identity = UserIdentity.generate()
        let recipient = P256.KeyAgreement.PrivateKey()   // stands in for the SE key

        let wrapped = try WeftDeviceKeyStore.wrapBundle(identity, toRecipientPublic: recipient.publicKey, aad: aadA)
        let recovered = try WeftDeviceKeyStore.recover(from: wrapped, aad: aadA) { ephPub in
            try recipient.sharedSecretFromKeyAgreement(with: ephPub)
        }

        XCTAssertEqual(recovered.identityKid, identity.identityKid)
        XCTAssertEqual(recovered.signingKid, identity.signingKid)
        // The recovered scalars must actually be the same keys, not just same kids.
        XCTAssertEqual(recovered.identityPrivate.rawRepresentation,
                       identity.identityPrivate.rawRepresentation)
        XCTAssertEqual(recovered.signingPrivate.rawRepresentation,
                       identity.signingPrivate.rawRepresentation)
    }

    func testWrongRecipientCannotUnwrap() throws {
        let identity = UserIdentity.generate()
        let recipient = P256.KeyAgreement.PrivateKey()
        let attacker = P256.KeyAgreement.PrivateKey()

        let wrapped = try WeftDeviceKeyStore.wrapBundle(identity, toRecipientPublic: recipient.publicKey, aad: aadA)
        XCTAssertThrowsError(try WeftDeviceKeyStore.recover(from: wrapped, aad: aadA) { ephPub in
            try attacker.sharedSecretFromKeyAgreement(with: ephPub)   // wrong private key
        })
    }

    func testWrongAADCannotUnwrap() throws {
        // Account-binding: a blob wrapped under accountA's AAD must not open under accountB's.
        let identity = UserIdentity.generate()
        let recipient = P256.KeyAgreement.PrivateKey()
        let wrapped = try WeftDeviceKeyStore.wrapBundle(identity, toRecipientPublic: recipient.publicKey, aad: aadA)
        XCTAssertThrowsError(try WeftDeviceKeyStore.recover(from: wrapped, aad: aadB) { ephPub in
            try recipient.sharedSecretFromKeyAgreement(with: ephPub)  // right key, wrong AAD
        })
    }

    func testTamperedCiphertextRejected() throws {
        let identity = UserIdentity.generate()
        let recipient = P256.KeyAgreement.PrivateKey()
        let wrapped = try WeftDeviceKeyStore.wrapBundle(identity, toRecipientPublic: recipient.publicKey, aad: aadA)

        var ctBytes = B64.decode(wrapped.ct)!
        ctBytes[0] ^= 0x01
        let tampered = WeftDeviceKeyStore.DeviceWrappedIdentity(
            ephPub: wrapped.ephPub, nonce: wrapped.nonce, ct: B64.encode(ctBytes))

        XCTAssertThrowsError(try WeftDeviceKeyStore.recover(from: tampered, aad: aadA) { ephPub in
            try recipient.sharedSecretFromKeyAgreement(with: ephPub)
        })
    }

    func testEachWrapUsesFreshEphemeralKey() throws {
        let identity = UserIdentity.generate()
        let recipient = P256.KeyAgreement.PrivateKey()
        let a = try WeftDeviceKeyStore.wrapBundle(identity, toRecipientPublic: recipient.publicKey, aad: aadA)
        let b = try WeftDeviceKeyStore.wrapBundle(identity, toRecipientPublic: recipient.publicKey, aad: aadA)
        // Fresh ephemeral keypair + nonce per wrap => non-deterministic blobs.
        XCTAssertNotEqual(a.ephPub, b.ephPub)
        XCTAssertNotEqual(a.ct, b.ct)
    }

    // MARK: Secure Enclave path — guarded (skips when SE / entitlement unavailable).

    private var service = ""
    private var store: WeftDeviceKeyStore!

    override func setUp() {
        service = "com.weft.e2ee.test.\(UUID().uuidString)"
        store = WeftDeviceKeyStore(service: service, account: "tester")
    }
    override func tearDown() { try? store.reset() }

    func testSecureEnclaveAvailabilityIsQueryable() {
        // Always runs: documents that the probe is a plain Bool, no throw.
        _ = store.isSecureEnclaveAvailable
    }

    func testEnrollThenIsEnrolledThenReset() throws {
        try XCTSkipUnless(store.isSecureEnclaveAvailable, "No Secure Enclave on this host")
        let identity = UserIdentity.generate()
        do {
            // enroll uses only the SE PUBLIC key, so it needs no biometric prompt.
            try store.enroll(identity)
        } catch {
            throw XCTSkip("SE key creation unavailable here (unsigned binary / no biometric hw): \(error)")
        }
        XCTAssertTrue(store.isEnrolled)
        try store.reset()
        XCTAssertFalse(store.isEnrolled)
        // NOTE: unlock() is intentionally NOT exercised here — it triggers a
        // Touch ID prompt that cannot be satisfied in a headless test run.
    }
}
