// Weft E2EE — WRAPPED PRIVATE KEY format (shared with JS, must round-trip cross-device).
//
// KEK = PBKDF2-HMAC-SHA256(passphrase_utf8, salt(16B), iters=600000, dkLen=32)   [CommonCrypto]
// bundle = utf8(JSON {"identity_d": b64url(32B), "signing_d": b64url(32B)})
// blob  = AES-256-GCM(KEK, nonce(12B), bundle, AAD=utf8("weft-userkey/v1"))
// stored = base64( JSON {"v":1,"kdf":"pbkdf2-sha256","iters":600000,"salt":b64,"nonce":b64,"ct":b64(ct||tag)} )
import Foundation
import CryptoKit
import CommonCrypto

/// The inner JSON bundle holding both private scalars (base64url, no padding).
private struct PrivKeyBundle: Codable {
    let identity_d: String
    let signing_d: String
}

/// The outer stored JSON (before the final base64 wrap).
public struct WrappedKeyEnvelope: Codable, Equatable {
    public let v: Int
    public let kdf: String
    public let iters: Int
    public let salt: String   // base64 (standard)
    public let nonce: String  // base64 (standard)
    public let ct: String     // base64 of (ciphertext || tag)
}

/// kdf_params jsonb mirror: {kdf, iters, salt}.
public struct KdfParams: Codable, Equatable {
    public let kdf: String
    public let iters: Int
    public let salt: String
}

public enum WeftWrappedPrivateKey {

    /// PBKDF2-HMAC-SHA256 via CommonCrypto.
    static func pbkdf2(passphrase: String, salt: Data, iterations: Int, dkLen: Int) throws -> Data {
        var derived = Data(count: dkLen)
        let pwBytes = Array(passphrase.utf8)
        let saltBytes = [UInt8](salt)
        let status = derived.withUnsafeMutableBytes { (dkPtr: UnsafeMutableRawBufferPointer) -> Int32 in
            saltBytes.withUnsafeBufferPointer { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwBytes, pwBytes.count,
                    saltPtr.baseAddress, saltPtr.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    dkPtr.bindMemory(to: UInt8.self).baseAddress, dkLen
                )
            }
        }
        guard status == kCCSuccess else { throw WeftCryptoError.pbkdf2Failed }
        return derived
    }

    /// Wrap an identity's two private scalars under a passphrase.
    /// Returns the stored value: base64( JSON envelope ).  `kdfParams` mirrors {kdf,iters,salt} for the jsonb column.
    public static func wrap(passphrase: String, identity: UserIdentity,
                            salt: Data? = nil, nonce: Data? = nil) throws -> (blob: String, kdfParams: KdfParams) {
        let saltData = salt ?? randomBytes(16)
        let nonceData = nonce ?? randomBytes(12)

        let kekRaw = try pbkdf2(passphrase: passphrase, salt: saltData,
                                iterations: WeftConstants.pbkdf2Iterations, dkLen: 32)
        let kek = SymmetricKey(data: kekRaw)

        let bundle = PrivKeyBundle(
            identity_d: B64.urlEncodeNoPad(identity.identityPrivate.rawRepresentation),
            signing_d:  B64.urlEncodeNoPad(identity.signingPrivate.rawRepresentation)
        )
        let bundleEnc = JSONEncoder()
        bundleEnc.outputFormatting = [.sortedKeys]
        let bundleData = try bundleEnc.encode(bundle)

        let box = try AES.GCM.seal(bundleData, using: kek,
                                   nonce: AES.GCM.Nonce(data: nonceData),
                                   authenticating: WeftConstants.userKeyAAD)
        let ct = box.ciphertext + box.tag

        let env = WrappedKeyEnvelope(
            v: WeftConstants.userKeyVersion,
            kdf: "pbkdf2-sha256",
            iters: WeftConstants.pbkdf2Iterations,
            salt: B64.encode(saltData),
            nonce: B64.encode(nonceData),
            ct: B64.encode(ct)
        )
        let envEnc = JSONEncoder()
        envEnc.outputFormatting = [.sortedKeys]
        let envData = try envEnc.encode(env)
        let blob = B64.encode(envData)

        let params = KdfParams(kdf: "pbkdf2-sha256", iters: WeftConstants.pbkdf2Iterations,
                               salt: B64.encode(saltData))
        return (blob, params)
    }

    /// Open a wrapped-private-key blob with a passphrase, recovering the UserIdentity.
    public static func open(passphrase: String, blob: String) throws -> UserIdentity {
        guard let envData = B64.decode(blob),
              let env = try? JSONDecoder().decode(WrappedKeyEnvelope.self, from: envData),
              let saltData = B64.decode(env.salt),
              let nonceData = B64.decode(env.nonce),
              let ctFull = B64.decode(env.ct), ctFull.count >= 16 else {
            throw WeftCryptoError.badWrappedKeyBlob
        }

        let kekRaw = try pbkdf2(passphrase: passphrase, salt: saltData,
                                iterations: env.iters, dkLen: 32)
        let kek = SymmetricKey(data: kekRaw)

        let ct = ctFull.prefix(ctFull.count - 16)
        let tag = ctFull.suffix(16)
        guard let box = try? AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonceData),
                                               ciphertext: ct, tag: tag),
              let bundleData = try? AES.GCM.open(box, using: kek,
                                                 authenticating: WeftConstants.userKeyAAD) else {
            throw WeftCryptoError.passphraseWrongOrCorrupt
        }

        guard let bundle = try? JSONDecoder().decode(PrivKeyBundle.self, from: bundleData),
              let idD = B64.urlDecode(bundle.identity_d),
              let sgD = B64.urlDecode(bundle.signing_d),
              let identityPriv = try? P256.KeyAgreement.PrivateKey(rawRepresentation: idD),
              let signingPriv = try? P256.Signing.PrivateKey(rawRepresentation: sgD) else {
            throw WeftCryptoError.badWrappedKeyBlob
        }
        return UserIdentity(identityPrivate: identityPriv, signingPrivate: signingPriv)
    }

    static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        d.withUnsafeMutableBytes { ptr in
            _ = SecRandomCopyBytes(kSecRandomDefault, n, ptr.baseAddress!)
        }
        return d
    }
}
