// Weft E2EE — kid computation, key bootstrap (identity + signing keypairs), and the SIGNED ROSTER signature.
import Foundation
import CryptoKit

public enum WeftCrypto {
    /// kid = base64(SHA-256(pubkey x963)).  Stable across runs for a fixed key.
    public static func kid(forX963 x963: Data) -> String {
        B64.encode(Data(SHA256.hash(data: x963)))
    }

    /// Convenience for a KeyAgreement public key.
    public static func kid(for pub: P256.KeyAgreement.PublicKey) -> String {
        kid(forX963: pub.x963Representation)
    }

    /// Convenience for a Signing (ECDSA) public key.
    public static func kid(for pub: P256.Signing.PublicKey) -> String {
        kid(forX963: pub.x963Representation)
    }
}

// MARK: - key_kind / sig_domain

/// Roster key kinds (mirrors public_keys.key_kind).
public enum KeyKind: String {
    case identity
    case signing
    case escrow
}

// MARK: - Bootstrapped identity

/// A freshly bootstrapped user identity: a P-256 KeyAgreement (identity) keypair and a
/// P-256 ECDSA (signing) keypair, plus the published roster rows + signatures for both.
public struct UserIdentity {
    public let identityPrivate: P256.KeyAgreement.PrivateKey
    public let signingPrivate: P256.Signing.PrivateKey

    public var identityPublic: P256.KeyAgreement.PublicKey { identityPrivate.publicKey }
    public var signingPublic: P256.Signing.PublicKey { signingPrivate.publicKey }

    public var identityKid: String { WeftCrypto.kid(for: identityPublic) }
    public var signingKid: String { WeftCrypto.kid(for: signingPublic) }

    /// identity pubkey x963 base64 (roster `pubkey` field).
    public var identityPubkeyB64: String { B64.encode(identityPublic.x963Representation) }
    /// signing pubkey x963 base64 (roster `pubkey` field).
    public var signingPubkeyB64: String { B64.encode(signingPublic.x963Representation) }

    public init(identityPrivate: P256.KeyAgreement.PrivateKey,
                signingPrivate: P256.Signing.PrivateKey) {
        self.identityPrivate = identityPrivate
        self.signingPrivate = signingPrivate
    }

    /// Generate a fresh identity (both keypairs random).
    public static func generate() -> UserIdentity {
        UserIdentity(identityPrivate: P256.KeyAgreement.PrivateKey(),
                     signingPrivate: P256.Signing.PrivateKey())
    }
}

// MARK: - Signed roster

/// A signable/verifiable roster row (matches public_keys columns relevant to the signature).
public struct RosterKey {
    public let sigDomain: String
    public let ownerUserId: String
    public let keyKind: KeyKind
    public let pubkeyB64: String   // base64 x963
    public let kid: String
    public let keyEpoch: Int
    public let predecessorKid: String?  // nil for the first epoch

    public init(sigDomain: String, ownerUserId: String, keyKind: KeyKind,
                pubkeyB64: String, kid: String, keyEpoch: Int, predecessorKid: String?) {
        self.sigDomain = sigDomain
        self.ownerUserId = ownerUserId
        self.keyKind = keyKind
        self.pubkeyB64 = pubkeyB64
        self.kid = kid
        self.keyEpoch = keyEpoch
        self.predecessorKid = predecessorKid
    }

    /// The canonical signing payload, per the SHARED FORMAT:
    /// sig_domain 0x00 owner 0x00 kind 0x00 pubkey_b64 0x00 kid 0x00 key_epoch 0x00 coalesce(predecessor_kid,'')
    /// single 0x00 separators, UTF-8.
    public func canonicalPayload() -> Data {
        let sep = Data([0x00])
        let fields: [String] = [
            sigDomain,
            ownerUserId,
            keyKind.rawValue,
            pubkeyB64,
            kid,
            String(keyEpoch),
            predecessorKid ?? ""
        ]
        var out = Data()
        for (i, f) in fields.enumerated() {
            if i > 0 { out.append(sep) }
            out.append(Data(f.utf8))
        }
        return out
    }
}

public enum WeftRoster {
    /// Sign a roster key with an ECDSA signing private key. Signature is over SHA-256 of the canonical payload.
    /// Returns base64 of the DER ECDSA signature.
    public static func sign(_ key: RosterKey, with signingKey: P256.Signing.PrivateKey) throws -> String {
        // ECDSA over the canonical payload. CryptoKit's signature(for:) hashes the message with
        // SHA-256 internally, so this is ECDSA-SHA256(payload) — matching Web Crypto's single hash
        // (do NOT pre-hash, or you double-hash). Emit RAW r‖s (64B); Web Crypto rejects DER.
        let sig = try signingKey.signature(for: key.canonicalPayload())
        return B64.encode(sig.rawRepresentation)
    }

    /// Verify a roster-key signature against a signing public key.
    public static func verify(_ key: RosterKey, signatureB64: String,
                              with signingPub: P256.Signing.PublicKey) -> Bool {
        guard let sigData = B64.decode(signatureB64),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: sigData) else {
            return false
        }
        return signingPub.isValidSignature(sig, for: key.canonicalPayload())
    }
}

// MARK: - Signed roster bundle (ready to publish + export as a vector)

/// A signed identity-key roster entry: the row fields plus its signature.
public struct SignedRosterEntry: Codable, Equatable {
    public let sig_domain: String
    public let owner_user_id: String
    public let key_kind: String
    public let pubkey: String
    public let kid: String
    public let key_epoch: Int
    public let predecessor_kid: String?
    public let signer_kid: String
    public let signature: String
}

extension UserIdentity {
    /// Build + sign both roster rows for this identity:
    ///  - signing key: self-signed (signer_kid == kid)
    ///  - identity key: signed by the signing key
    /// `sigDomain` defaults to "weft-pubkey-v1" (matches the migration default + JS SIG_DOMAIN_DEFAULT).
    public func signedRoster(ownerUserId: String,
                             sigDomain: String = "weft-pubkey-v1",
                             keyEpoch: Int = 1) throws -> (signing: SignedRosterEntry, identity: SignedRosterEntry) {
        // signing key (self-signed)
        let signingRoster = RosterKey(sigDomain: sigDomain, ownerUserId: ownerUserId,
                                      keyKind: .signing, pubkeyB64: signingPubkeyB64,
                                      kid: signingKid, keyEpoch: keyEpoch, predecessorKid: nil)
        let signingSig = try WeftRoster.sign(signingRoster, with: signingPrivate)
        let signingEntry = SignedRosterEntry(
            sig_domain: sigDomain, owner_user_id: ownerUserId, key_kind: "signing",
            pubkey: signingPubkeyB64, kid: signingKid, key_epoch: keyEpoch,
            predecessor_kid: nil, signer_kid: signingKid, signature: signingSig)

        // identity key (signed by the signing key)
        let identityRoster = RosterKey(sigDomain: sigDomain, ownerUserId: ownerUserId,
                                       keyKind: .identity, pubkeyB64: identityPubkeyB64,
                                       kid: identityKid, keyEpoch: keyEpoch, predecessorKid: nil)
        let identitySig = try WeftRoster.sign(identityRoster, with: signingPrivate)
        let identityEntry = SignedRosterEntry(
            sig_domain: sigDomain, owner_user_id: ownerUserId, key_kind: "identity",
            pubkey: identityPubkeyB64, kid: identityKid, key_epoch: keyEpoch,
            predecessor_kid: nil, signer_kid: signingKid, signature: identitySig)

        return (signingEntry, identityEntry)
    }
}
