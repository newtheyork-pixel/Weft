// Weft E2EE envelope — productionized CryptoKit implementation of the proven spike.
// Multi-recipient seal/open. Interoperates byte-for-byte with envelope.mjs (Web Crypto).
import Foundation
import CryptoKit

// MARK: - Wire types

/// One per-recipient wrap of the content DEK.
public struct EnvelopeWrap: Codable, Equatable {
    public let recipient_kid: String  // base64(SHA-256(recipient pubkey x963))
    public let eph_pub: String        // base64 of 65B x963 ephemeral pubkey
    public let nonce: String          // base64 of 12B AES-GCM nonce
    public let wrapped_dek: String    // base64 of (ciphertext(32) || tag(16))

    public init(recipient_kid: String, eph_pub: String, nonce: String, wrapped_dek: String) {
        self.recipient_kid = recipient_kid
        self.eph_pub = eph_pub
        self.nonce = nonce
        self.wrapped_dek = wrapped_dek
    }
}

/// The AES-256-GCM-encrypted content body.
public struct EnvelopeContent: Codable, Equatable {
    public let aad: String     // "<submission_id>|v<version>"
    public let nonce: String   // base64 of 12B nonce
    public let ct: String      // base64 of (ciphertext || tag(16))

    public init(aad: String, nonce: String, ct: String) {
        self.aad = aad
        self.nonce = nonce
        self.ct = ct
    }
}

/// The full envelope wire object. JSON shape matches the spec §4 exactly.
public struct Envelope: Codable, Equatable {
    public let v: Int
    public let suite: String
    public let content: EnvelopeContent
    public let wraps: [EnvelopeWrap]

    public init(v: Int, suite: String, content: EnvelopeContent, wraps: [EnvelopeWrap]) {
        self.v = v
        self.suite = suite
        self.content = content
        self.wraps = wraps
    }

    /// Encode to canonical JSON bytes.
    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(self)
    }

    /// Decode from JSON bytes.
    public static func from(jsonData data: Data) throws -> Envelope {
        return try JSONDecoder().decode(Envelope.self, from: data)
    }
}

// MARK: - Recipient descriptor

/// A recipient the DEK should be wrapped to: its KeyAgreement public key.
public struct Recipient {
    public let publicKey: P256.KeyAgreement.PublicKey
    public init(publicKey: P256.KeyAgreement.PublicKey) { self.publicKey = publicKey }

    /// Construct from raw x963 (0x04||X||Y, 65B).
    public init(x963: Data) throws {
        guard let pk = try? P256.KeyAgreement.PublicKey(x963Representation: x963) else {
            throw WeftCryptoError.badPublicKey
        }
        self.publicKey = pk
    }

    /// recipient_kid = base64(SHA-256(pubkey x963)).
    public var kid: String { WeftCrypto.kid(forX963: publicKey.x963Representation) }
}

// MARK: - Envelope core

public enum WeftEnvelope {

    /// Derive the wrap KEK from an ECDH shared secret, binding eph + recipient pubkeys into HKDF info.
    /// Matches the spike's deriveKek exactly.
    static func deriveKek(shared: SharedSecret, ephPubRaw: Data, recipPubRaw: Data) -> SymmetricKey {
        let info = WeftConstants.wrapLabel + ephPubRaw + recipPubRaw
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: WeftConstants.hkdfSalt,
            sharedInfo: info,
            outputByteCount: 32
        )
    }

    /// Seal `plaintext` to one or more recipients.
    /// - Parameters:
    ///   - submissionId / version: form the content AAD "<submission_id>|v<version>".
    public static func seal(
        plaintext: Data,
        submissionId: String,
        version: String,
        recipients: [Recipient]
    ) throws -> Envelope {
        precondition(!recipients.isEmpty, "seal requires at least one recipient")

        // 1) content: random DEK + AES-256-GCM, AAD = "<sid>|v<ver>"
        let dekKey = SymmetricKey(size: .bits256)
        let dek = dekKey.withUnsafeBytes { Data($0) }
        let aadStr = "\(submissionId)|v\(version)"
        let cbox = try AES.GCM.seal(plaintext, using: dekKey,
                                    nonce: AES.GCM.Nonce(),
                                    authenticating: Data(aadStr.utf8))
        let content = EnvelopeContent(
            aad: aadStr,
            nonce: B64.encode(Data(cbox.nonce)),
            ct: B64.encode(cbox.ciphertext + cbox.tag)   // ct || tag (Web Crypto layout)
        )

        // 2) wrap DEK to each recipient (fresh ephemeral key per wrap)
        var wraps: [EnvelopeWrap] = []
        for r in recipients {
            let recipPubRaw = r.publicKey.x963Representation
            let eph = P256.KeyAgreement.PrivateKey()
            let ephPubRaw = eph.publicKey.x963Representation
            guard let shared = try? eph.sharedSecretFromKeyAgreement(with: r.publicKey) else {
                throw WeftCryptoError.ecdhFailed
            }
            let kek = deriveKek(shared: shared, ephPubRaw: ephPubRaw, recipPubRaw: recipPubRaw)
            let wbox = try AES.GCM.seal(dek, using: kek,
                                        nonce: AES.GCM.Nonce(),
                                        authenticating: WeftConstants.wrapAAD)
            wraps.append(EnvelopeWrap(
                recipient_kid: WeftCrypto.kid(forX963: recipPubRaw),
                eph_pub: B64.encode(ephPubRaw),
                nonce: B64.encode(Data(wbox.nonce)),
                wrapped_dek: B64.encode(wbox.ciphertext + wbox.tag)
            ))
        }

        return Envelope(v: WeftConstants.envelopeVersion, suite: WeftConstants.suite,
                        content: content, wraps: wraps)
    }

    /// Open an envelope as the holder of `privateKey`. Only the addressed recipient can unwrap.
    public static func open(
        envelope env: Envelope,
        privateKey: P256.KeyAgreement.PrivateKey
    ) throws -> Data {
        let recipPubRaw = privateKey.publicKey.x963Representation
        let myKid = WeftCrypto.kid(forX963: recipPubRaw)
        guard let w = env.wraps.first(where: { $0.recipient_kid == myKid }) else {
            throw WeftCryptoError.noWrapForRecipient
        }

        guard let ephPubRaw = B64.decode(w.eph_pub),
              let ephPub = try? P256.KeyAgreement.PublicKey(x963Representation: ephPubRaw),
              let wNonce = B64.decode(w.nonce),
              let wrapped = B64.decode(w.wrapped_dek) else {
            throw WeftCryptoError.badEnvelope
        }
        guard let shared = try? privateKey.sharedSecretFromKeyAgreement(with: ephPub) else {
            throw WeftCryptoError.ecdhFailed
        }
        let kek = deriveKek(shared: shared, ephPubRaw: ephPubRaw, recipPubRaw: recipPubRaw)

        // unwrap DEK
        guard wrapped.count >= 16 else { throw WeftCryptoError.badEnvelope }
        let wct = wrapped.prefix(wrapped.count - 16)
        let wtag = wrapped.suffix(16)
        guard let wsb = try? AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: wNonce),
                                               ciphertext: wct, tag: wtag),
              let dek = try? AES.GCM.open(wsb, using: kek, authenticating: WeftConstants.wrapAAD) else {
            throw WeftCryptoError.unwrapAuthFailed
        }

        // decrypt content
        guard let cNonce = B64.decode(env.content.nonce),
              let cBytes = B64.decode(env.content.ct), cBytes.count >= 16 else {
            throw WeftCryptoError.badEnvelope
        }
        let cct = cBytes.prefix(cBytes.count - 16)
        let ctag = cBytes.suffix(16)
        guard let csb = try? AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: cNonce),
                                               ciphertext: cct, tag: ctag),
              let pt = try? AES.GCM.open(csb, using: SymmetricKey(data: dek),
                                         authenticating: Data(env.content.aad.utf8)) else {
            throw WeftCryptoError.contentAuthFailed
        }
        return pt
    }
}
