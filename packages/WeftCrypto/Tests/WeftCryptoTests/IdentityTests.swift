import XCTest
import CryptoKit
@testable import WeftCrypto

final class IdentityTests: XCTestCase {

    func testKidStability() {
        let priv = P256.KeyAgreement.PrivateKey()
        let x963 = priv.publicKey.x963Representation
        let k1 = WeftCrypto.kid(forX963: x963)
        let k2 = WeftCrypto.kid(forX963: x963)
        XCTAssertEqual(k1, k2, "kid must be deterministic for a fixed key")
        XCTAssertEqual(k1, WeftCrypto.kid(for: priv.publicKey))

        // Different key -> different kid.
        let other = P256.KeyAgreement.PrivateKey()
        XCTAssertNotEqual(k1, WeftCrypto.kid(for: other.publicKey))

        // kid is base64 of a 32-byte SHA-256.
        XCTAssertEqual(B64.decode(k1)?.count, 32)
    }

    func testSignedRosterValidSignatures() throws {
        let id = UserIdentity.generate()
        let (signingEntry, identityEntry) = try id.signedRoster(ownerUserId: "owner-uuid-1")

        // signing key is self-signed
        XCTAssertEqual(signingEntry.signer_kid, signingEntry.kid)
        let signingRoster = RosterKey(sigDomain: signingEntry.sig_domain,
                                      ownerUserId: signingEntry.owner_user_id,
                                      keyKind: .signing, pubkeyB64: signingEntry.pubkey,
                                      kid: signingEntry.kid, keyEpoch: signingEntry.key_epoch,
                                      predecessorKid: signingEntry.predecessor_kid)
        XCTAssertTrue(WeftRoster.verify(signingRoster, signatureB64: signingEntry.signature,
                                        with: id.signingPublic))

        // identity key is signed by the signing key
        XCTAssertEqual(identityEntry.signer_kid, id.signingKid)
        let identityRoster = RosterKey(sigDomain: identityEntry.sig_domain,
                                       ownerUserId: identityEntry.owner_user_id,
                                       keyKind: .identity, pubkeyB64: identityEntry.pubkey,
                                       kid: identityEntry.kid, keyEpoch: identityEntry.key_epoch,
                                       predecessorKid: identityEntry.predecessor_kid)
        XCTAssertTrue(WeftRoster.verify(identityRoster, signatureB64: identityEntry.signature,
                                        with: id.signingPublic))
    }

    func testTamperedRosterSignatureFails() throws {
        let id = UserIdentity.generate()
        let (_, identityEntry) = try id.signedRoster(ownerUserId: "owner-uuid-1")

        // Tamper: change the kid in the verified payload — signature must no longer validate.
        let tampered = RosterKey(sigDomain: identityEntry.sig_domain,
                                 ownerUserId: identityEntry.owner_user_id,
                                 keyKind: .identity, pubkeyB64: identityEntry.pubkey,
                                 kid: identityEntry.kid + "X",  // tampered
                                 keyEpoch: identityEntry.key_epoch,
                                 predecessorKid: identityEntry.predecessor_kid)
        XCTAssertFalse(WeftRoster.verify(tampered, signatureB64: identityEntry.signature,
                                         with: id.signingPublic))

        // Wrong signer key also fails.
        let wrongSigner = P256.Signing.PrivateKey().publicKey
        let untampered = RosterKey(sigDomain: identityEntry.sig_domain,
                                   ownerUserId: identityEntry.owner_user_id,
                                   keyKind: .identity, pubkeyB64: identityEntry.pubkey,
                                   kid: identityEntry.kid, keyEpoch: identityEntry.key_epoch,
                                   predecessorKid: identityEntry.predecessor_kid)
        XCTAssertFalse(WeftRoster.verify(untampered, signatureB64: identityEntry.signature,
                                         with: wrongSigner))
    }

    func testCanonicalPayloadHasSingleNullSeparators() {
        let r = RosterKey(sigDomain: "weft-roster/v1", ownerUserId: "owner",
                          keyKind: .identity, pubkeyB64: "PUB", kid: "KID",
                          keyEpoch: 1, predecessorKid: nil)
        let parts = ["weft-roster/v1", "owner", "identity", "PUB", "KID", "1", ""]
        var expected = Data()
        for (i, p) in parts.enumerated() {
            if i > 0 { expected.append(0) }
            expected.append(Data(p.utf8))
        }
        XCTAssertEqual(r.canonicalPayload(), expected)
    }
}
