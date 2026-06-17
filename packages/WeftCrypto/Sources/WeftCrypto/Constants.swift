// Weft E2EE — frozen protocol constants. MUST match the proven spike (envelope.swift / envelope.mjs)
// and docs/E2EE_ENVELOPE_SPEC.md byte-for-byte. Do not change without re-running the interop harness.
import Foundation

public enum WeftConstants {
    /// Cipher suite identifier.
    public static let suite = "P256-HKDF-SHA256-AES256GCM"

    /// HKDF salt used when deriving a KEK from the ECDH shared secret.
    public static let hkdfSalt = Data("weft-e2ee-v1".utf8)

    /// HKDF `info` prefix; full info = prefix || ephPub(65) || recipPub(65).
    public static let wrapLabel = Data("weft-dek-wrap/v1".utf8)

    /// AAD bound into the DEK-wrap AES-GCM tag.
    public static let wrapAAD = Data("weft-wrap/v1".utf8)

    /// AAD bound into the wrapped-private-key AES-GCM tag (WRAPPED PRIVATE KEY shared format).
    public static let userKeyAAD = Data("weft-userkey/v1".utf8)

    /// PBKDF2 iteration count for the passphrase KEK (WRAPPED PRIVATE KEY shared format).
    public static let pbkdf2Iterations: Int = 600_000

    /// Envelope wire version.
    public static let envelopeVersion = 1

    /// Wrapped-private-key blob version.
    public static let userKeyVersion = 1
}

// MARK: - Base64 helpers

public enum B64 {
    /// Standard base64 encode (used for envelope + kid fields).
    public static func encode(_ d: Data) -> String { d.base64EncodedString() }

    /// Standard base64 decode.
    public static func decode(_ s: String) -> Data? { Data(base64Encoded: s) }

    /// base64url encode without padding (used inside the wrapped-privkey JSON bundle: identity_d / signing_d).
    public static func urlEncodeNoPad(_ d: Data) -> String {
        var s = d.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
             .replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    /// base64url decode (tolerates missing padding).
    public static func urlDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

/// Crypto errors surfaced by WeftCrypto.
public enum WeftCryptoError: Error, Equatable {
    case badPublicKey
    case badPrivateKey
    case ecdhFailed
    case noWrapForRecipient
    case unwrapAuthFailed
    case contentAuthFailed
    case badEnvelope
    case badWrappedKeyBlob
    case pbkdf2Failed
    case passphraseWrongOrCorrupt
    case pinMismatch(owner: String, pinnedKid: String, presentedKid: String)
}
