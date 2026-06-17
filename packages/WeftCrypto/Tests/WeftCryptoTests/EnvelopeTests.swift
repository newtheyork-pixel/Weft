import XCTest
import CryptoKit
@testable import WeftCrypto

final class EnvelopeTests: XCTestCase {

    func testEnvelopeRoundTripSingleRecipient() throws {
        let recipPriv = P256.KeyAgreement.PrivateKey()
        let recipient = Recipient(publicKey: recipPriv.publicKey)
        let pt = Data("the quick brown fox — a student essay".utf8)

        let env = try WeftEnvelope.seal(plaintext: pt, submissionId: "sub-123", version: "2",
                                        recipients: [recipient])
        XCTAssertEqual(env.suite, WeftConstants.suite)
        XCTAssertEqual(env.v, 1)
        XCTAssertEqual(env.content.aad, "sub-123|v2")
        XCTAssertEqual(env.wraps.count, 1)

        let out = try WeftEnvelope.open(envelope: env, privateKey: recipPriv)
        XCTAssertEqual(out, pt)
    }

    func testEnvelopeJSONEncodeDecodeRoundTrip() throws {
        let recipPriv = P256.KeyAgreement.PrivateKey()
        let env = try WeftEnvelope.seal(plaintext: Data("hello".utf8),
                                        submissionId: "s", version: "1",
                                        recipients: [Recipient(publicKey: recipPriv.publicKey)])
        let data = try env.jsonData()
        let decoded = try Envelope.from(jsonData: data)
        XCTAssertEqual(decoded, env)
        let out = try WeftEnvelope.open(envelope: decoded, privateKey: recipPriv)
        XCTAssertEqual(out, Data("hello".utf8))
    }

    func testMultiRecipientOnlyAddressedRecipientOpens() throws {
        // Three recipients: student, teacher, escrow.
        let student = P256.KeyAgreement.PrivateKey()
        let teacher = P256.KeyAgreement.PrivateKey()
        let escrow  = P256.KeyAgreement.PrivateKey()
        let outsider = P256.KeyAgreement.PrivateKey()

        let env = try WeftEnvelope.seal(
            plaintext: Data("multi-recipient content".utf8),
            submissionId: "item-9", version: "1",
            recipients: [Recipient(publicKey: student.publicKey),
                         Recipient(publicKey: teacher.publicKey),
                         Recipient(publicKey: escrow.publicKey)])

        XCTAssertEqual(env.wraps.count, 3)

        // Each addressed recipient recovers identical plaintext.
        for priv in [student, teacher, escrow] {
            let out = try WeftEnvelope.open(envelope: env, privateKey: priv)
            XCTAssertEqual(out, Data("multi-recipient content".utf8))
        }

        // An outsider with no wrap is rejected (no matching kid).
        XCTAssertThrowsError(try WeftEnvelope.open(envelope: env, privateKey: outsider)) { err in
            XCTAssertEqual(err as? WeftCryptoError, .noWrapForRecipient)
        }

        // Every wrap carries a distinct recipient_kid.
        let kids = Set(env.wraps.map { $0.recipient_kid })
        XCTAssertEqual(kids.count, 3)
    }

    func testTamperedContentFailsAuth() throws {
        let recipPriv = P256.KeyAgreement.PrivateKey()
        let env = try WeftEnvelope.seal(plaintext: Data("secret".utf8),
                                        submissionId: "x", version: "1",
                                        recipients: [Recipient(publicKey: recipPriv.publicKey)])
        // Flip a byte in the content ciphertext.
        var ctBytes = B64.decode(env.content.ct)!
        ctBytes[0] ^= 0x01
        let tampered = Envelope(v: env.v, suite: env.suite,
                                content: EnvelopeContent(aad: env.content.aad,
                                                         nonce: env.content.nonce,
                                                         ct: B64.encode(ctBytes)),
                                wraps: env.wraps)
        XCTAssertThrowsError(try WeftEnvelope.open(envelope: tampered, privateKey: recipPriv)) { err in
            XCTAssertEqual(err as? WeftCryptoError, .contentAuthFailed)
        }
    }

    func testTamperedAADFailsAuth() throws {
        let recipPriv = P256.KeyAgreement.PrivateKey()
        let env = try WeftEnvelope.seal(plaintext: Data("secret".utf8),
                                        submissionId: "x", version: "1",
                                        recipients: [Recipient(publicKey: recipPriv.publicKey)])
        // Change the AAD (e.g. row-swap / rollback attempt).
        let tampered = Envelope(v: env.v, suite: env.suite,
                                content: EnvelopeContent(aad: "x|v2",
                                                         nonce: env.content.nonce,
                                                         ct: env.content.ct),
                                wraps: env.wraps)
        XCTAssertThrowsError(try WeftEnvelope.open(envelope: tampered, privateKey: recipPriv)) { err in
            XCTAssertEqual(err as? WeftCryptoError, .contentAuthFailed)
        }
    }
}
