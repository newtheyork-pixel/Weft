import XCTest
import CryptoKit
@testable import WeftCrypto

final class WrappedPrivateKeyTests: XCTestCase {

    func testWrapOpenRoundTrip() throws {
        let id = UserIdentity.generate()
        let (blob, params) = try WeftWrappedPrivateKey.wrap(passphrase: "correct horse battery staple",
                                                            identity: id)
        XCTAssertEqual(params.kdf, "pbkdf2-sha256")
        XCTAssertEqual(params.iters, 600_000)

        let recovered = try WeftWrappedPrivateKey.open(passphrase: "correct horse battery staple",
                                                       blob: blob)
        // Same private scalars round-trip.
        XCTAssertEqual(recovered.identityPrivate.rawRepresentation,
                       id.identityPrivate.rawRepresentation)
        XCTAssertEqual(recovered.signingPrivate.rawRepresentation,
                       id.signingPrivate.rawRepresentation)
        // Same derived kids.
        XCTAssertEqual(recovered.identityKid, id.identityKid)
        XCTAssertEqual(recovered.signingKid, id.signingKid)
    }

    func testWrongPassphraseFails() throws {
        let id = UserIdentity.generate()
        let (blob, _) = try WeftWrappedPrivateKey.wrap(passphrase: "right", identity: id)
        XCTAssertThrowsError(try WeftWrappedPrivateKey.open(passphrase: "wrong", blob: blob)) { err in
            XCTAssertEqual(err as? WeftCryptoError, .passphraseWrongOrCorrupt)
        }
    }

    func testBlobStructureMatchesSharedFormat() throws {
        let id = UserIdentity.generate()
        let (blob, _) = try WeftWrappedPrivateKey.wrap(passphrase: "pw", identity: id)
        // Outer blob is base64 of a JSON envelope.
        let envData = B64.decode(blob)
        XCTAssertNotNil(envData)
        let env = try JSONDecoder().decode(WrappedKeyEnvelope.self, from: envData!)
        XCTAssertEqual(env.v, 1)
        XCTAssertEqual(env.kdf, "pbkdf2-sha256")
        XCTAssertEqual(env.iters, 600_000)
        XCTAssertEqual(B64.decode(env.salt)?.count, 16)
        XCTAssertEqual(B64.decode(env.nonce)?.count, 12)
        // ct = ciphertext || tag(16). bundle is small JSON so ct length > 16.
        XCTAssertGreaterThan(B64.decode(env.ct)!.count, 16)
    }

    func testDeterministicWithFixedSaltAndNonce() throws {
        let id = UserIdentity.generate()
        let salt = Data(repeating: 0xAB, count: 16)
        let nonce = Data(repeating: 0xCD, count: 12)
        let (b1, _) = try WeftWrappedPrivateKey.wrap(passphrase: "pw", identity: id, salt: salt, nonce: nonce)
        let (b2, _) = try WeftWrappedPrivateKey.wrap(passphrase: "pw", identity: id, salt: salt, nonce: nonce)
        XCTAssertEqual(b1, b2, "fixed salt+nonce must produce a byte-identical blob (interop determinism)")
    }
}
