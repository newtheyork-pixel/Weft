// Weft E2EE — Secure Enclave device-key cache (Apple-style daily unlock).
//
// The passphrase (WrappedPrivateKey.swift) is the CROSS-DEVICE recovery anchor.
// This file adds the Apple model on top: after the first passphrase unlock on a
// device, the user's identity is re-wrapped to a hardware key generated in the
// Secure Enclave and gated by Touch ID, then cached in the Keychain. Subsequent
// launches recover the identity with a biometric tap — no passphrase.
//
// Properties of the device key:
//  - Non-extractable: the private key never leaves the Secure Enclave; only an
//    opaque, SE-encrypted `dataRepresentation` is persisted. Copying it to
//    another machine is useless.
//  - Biometric-gated: every use (the ECDH unwrap) requires the CURRENT biometric
//    set (`.biometryCurrentSet`, the default) — no passcode fallback, and the key
//    is invalidated if the device's fingerprints/face change. A caller may opt
//    down to `.userPresence` (biometric OR passcode) for hardware without Touch ID.
//  - Device-bound: Keychain items are `...ThisDeviceOnly` and never sync.
//
// The persisted Keychain blob (SE key dataRepresentation + the ECIES envelope) is
// CIPHERTEXT and is intentionally NOT itself biometric-gated: it is useless
// without the SE key (whose use IS gated), and gating reads would force a Touch ID
// prompt on every `isEnrolled` check. The blob's AEAD AAD binds the `account`, so
// an enrollment cannot be cross-used between accounts on a shared device.
//
// The wrap is ECIES with the SE key as recipient, reusing the package's
// primitives (P-256 ECDH -> HKDF-SHA256 -> AES-256-GCM). The constants here are
// DEVICE-LOCAL (this never interoperates with JS), so they are intentionally
// separate from the frozen cross-platform set in Constants.swift.
//
// Threading: all Keychain access is serialized on a private queue. Call `unlock`
// OFF the main thread — it blocks on the modal biometric prompt.
import Foundation
import CryptoKit
import LocalAuthentication
import Security

public enum WeftDeviceKeyError: Error, Equatable {
    case secureEnclaveUnavailable
    case notEnrolled
    case keychainStatus(OSStatus)
    case accessControlFailed
    case badEnrollmentBlob
    case unwrapFailed
}

/// How the Secure Enclave key is gated.
public enum BiometricPolicy {
    /// Touch ID bound to the CURRENTLY enrolled biometric set; no passcode
    /// fallback, and the key is invalidated if biometrics change. Strongest.
    /// Requires biometric hardware — `enroll` throws on Macs without Touch ID.
    case biometryCurrentSet
    /// Touch ID OR device passcode. More recoverable, weaker (a known passcode
    /// unlocks the identity). Use only when biometric-only is not viable.
    case userPresence
}

/// Stores the user's identity behind a Secure Enclave key + biometrics on this device.
public final class WeftDeviceKeyStore {

    // Device-local KDF/AEAD context (NOT part of the cross-platform frozen set).
    private static let kdfSalt   = Data("weft-device-v1".utf8)
    private static let kdfInfo   = Data("weft-se-identity/v1".utf8)
    private static let aadPrefix = Data("weft-device-identity/v1".utf8)
    private static let enrollmentVersion = 1

    private let service: String
    private let account: String
    private let policy: BiometricPolicy
    private let queue = DispatchQueue(label: "weft.device.keystore")

    /// - Parameters:
    ///   - service: Keychain service namespace.
    ///   - account: Per-owner account (pass the user id on a shared device). Bound
    ///     into the AEAD AAD, so a blob for one account cannot be opened as another.
    ///   - policy: Biometric gating; `.biometryCurrentSet` (strongest) by default.
    public init(service: String = "com.weft.e2ee.device-identity",
                account: String = "default",
                policy: BiometricPolicy = .biometryCurrentSet) {
        self.service = service
        self.account = account
        self.policy = policy
    }

    /// True if this hardware has a Secure Enclave (Apple Silicon / T2).
    public var isSecureEnclaveAvailable: Bool { SecureEnclave.isAvailable }

    /// True if an enrollment blob is present and decodable for this device+account.
    public var isEnrolled: Bool { queue.sync { (try? loadBlob()) != nil } }

    // MARK: - Enroll / unlock / reset

    /// Bind `identity` to this device behind the Secure Enclave + biometrics.
    /// Call once after a successful passphrase unlock. Overwrites any prior
    /// enrollment for this account. Throws `secureEnclaveUnavailable` (no SE) or a
    /// Keychain/access-control error (e.g. no biometric hardware under
    /// `.biometryCurrentSet`); the caller may then stay passphrase-only.
    public func enroll(_ identity: UserIdentity, context: LAContext? = nil) throws {
        guard SecureEnclave.isAvailable else { throw WeftDeviceKeyError.secureEnclaveUnavailable }
        try queue.sync {
            let access = try makeAccessControl()
            let seKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                accessControl: access,
                authenticationContext: context
            )
            // enroll uses only the SE PUBLIC key, so it needs NO biometric prompt.
            let wrapped = try Self.wrapBundle(identity, toRecipientPublic: seKey.publicKey, aad: aad())
            let blob = DeviceEnrollment(
                v: Self.enrollmentVersion,
                seKey: B64.encode(seKey.dataRepresentation),
                wrapped: wrapped
            )
            try storeBlob(blob)
        }
    }

    /// Recover the device-bound identity. Triggers a biometric prompt (the SE key's
    /// ECDH is the gated operation). Throws `notEnrolled` if never enrolled. Call
    /// OFF the main thread.
    public func unlock(context: LAContext? = nil) throws -> UserIdentity {
        try queue.sync {
            guard let blob = try loadBlob() else { throw WeftDeviceKeyError.notEnrolled }
            guard let seKeyData = B64.decode(blob.seKey) else { throw WeftDeviceKeyError.badEnrollmentBlob }
            let seKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                dataRepresentation: seKeyData,
                authenticationContext: context
            )
            return try Self.recover(from: blob.wrapped, aad: aad()) { ephPub in
                // Biometric prompt happens HERE, on the SE private-key operation.
                try seKey.sharedSecretFromKeyAgreement(with: ephPub)
            }
        }
    }

    /// Remove this device's enrollment (e.g. on sign-out). Throws if the Keychain
    /// delete fails, so an incomplete wipe is detectable — never silent.
    /// NOTE: this clears only the device-key blob; a full sign-out should also
    /// clear the TOFU pin store + in-memory identity (caller's responsibility).
    public func reset() throws {
        try queue.sync {
            let status = SecItemDelete(baseQuery() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw WeftDeviceKeyError.keychainStatus(status)
            }
        }
    }

    // MARK: - ECIES core (recipient-agnostic; testable with a software key)

    /// Persisted, SE-encrypted form of the identity. The `seKey` blob is useless
    /// without the originating Secure Enclave.
    struct DeviceEnrollment: Codable, Equatable {
        let v: Int
        let seKey: String                 // b64 SE key dataRepresentation
        let wrapped: DeviceWrappedIdentity
    }

    /// ECIES envelope over the identity's two private scalars.
    struct DeviceWrappedIdentity: Codable, Equatable {
        let ephPub: String  // b64 x963 (65B) of the ephemeral public key
        let nonce: String   // b64 (12B)
        let ct: String      // b64 of (ciphertext || tag)
    }

    /// Wrap the identity to a recipient public key (the SE public key in production).
    /// Fresh ephemeral keypair; only the recipient PUBLIC half is needed, so this
    /// never touches the SE private key (no biometric prompt). `aad` binds context
    /// (the account) into the AEAD tag.
    static func wrapBundle(_ identity: UserIdentity,
                           toRecipientPublic recipientPub: P256.KeyAgreement.PublicKey,
                           aad: Data) throws -> DeviceWrappedIdentity {
        let eph = P256.KeyAgreement.PrivateKey()
        let shared = try eph.sharedSecretFromKeyAgreement(with: recipientPub)
        let kek = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                 salt: kdfSalt, sharedInfo: kdfInfo,
                                                 outputByteCount: 32)
        let bundle = encodeBundle(identity)
        let box = try AES.GCM.seal(bundle, using: kek, authenticating: aad)
        return DeviceWrappedIdentity(
            ephPub: B64.encode(eph.publicKey.x963Representation),
            nonce: B64.encode(Data(box.nonce)),
            ct: B64.encode(box.ciphertext + box.tag)
        )
    }

    /// Recover the identity from an ECIES envelope. `deriveShared` performs the
    /// ECDH with the recipient PRIVATE key — for the SE that is the gated op; in
    /// tests it is a software key. `aad` must match the wrap.
    static func recover(from wrapped: DeviceWrappedIdentity,
                        aad: Data,
                        deriveShared: (_ ephPub: P256.KeyAgreement.PublicKey) throws -> SharedSecret) throws -> UserIdentity {
        guard let ephRaw = B64.decode(wrapped.ephPub),
              let nonceData = B64.decode(wrapped.nonce),
              let ctFull = B64.decode(wrapped.ct), ctFull.count >= 16,
              let ephPub = try? P256.KeyAgreement.PublicKey(x963Representation: ephRaw) else {
            throw WeftDeviceKeyError.badEnrollmentBlob
        }
        let shared = try deriveShared(ephPub)
        let kek = shared.hkdfDerivedSymmetricKey(using: SHA256.self,
                                                 salt: kdfSalt, sharedInfo: kdfInfo,
                                                 outputByteCount: 32)
        let ct = ctFull.prefix(ctFull.count - 16)
        let tag = ctFull.suffix(16)
        guard let box = try? AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: nonceData),
                                               ciphertext: ct, tag: tag),
              let bundleData = try? AES.GCM.open(box, using: kek, authenticating: aad) else {
            throw WeftDeviceKeyError.unwrapFailed
        }
        return try decodeBundle(bundleData)
    }

    // MARK: - Identity bundle codec (device-local; same shape as the passphrase bundle)

    private struct PrivBundle: Codable { let identity_d: String; let signing_d: String }

    static func encodeBundle(_ identity: UserIdentity) -> Data {
        let bundle = PrivBundle(
            identity_d: B64.urlEncodeNoPad(identity.identityPrivate.rawRepresentation),
            signing_d:  B64.urlEncodeNoPad(identity.signingPrivate.rawRepresentation)
        )
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(bundle)) ?? Data()
    }

    static func decodeBundle(_ data: Data) throws -> UserIdentity {
        guard let bundle = try? JSONDecoder().decode(PrivBundle.self, from: data),
              let idD = B64.urlDecode(bundle.identity_d),
              let sgD = B64.urlDecode(bundle.signing_d),
              let idPriv = try? P256.KeyAgreement.PrivateKey(rawRepresentation: idD),
              let sgPriv = try? P256.Signing.PrivateKey(rawRepresentation: sgD) else {
            throw WeftDeviceKeyError.unwrapFailed
        }
        return UserIdentity(identityPrivate: idPriv, signingPrivate: sgPriv)
    }

    // MARK: - Access control + Keychain (callers hold `queue`)

    /// AEAD AAD = prefix || 0x00 || account — binds the enrollment to its owner.
    private func aad() -> Data { Self.aadPrefix + Data([0x00]) + Data(account.utf8) }

    private func makeAccessControl() throws -> SecAccessControl {
        let flags: SecAccessControlCreateFlags = policy == .biometryCurrentSet
            ? [.privateKeyUsage, .biometryCurrentSet]
            : [.privateKeyUsage, .userPresence]
        var err: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            flags,
            &err
        ) else {
            throw WeftDeviceKeyError.accessControlFailed
        }
        return access
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Add-or-update so a write failure can never leave the device unenrolled
    /// (no destructive delete-then-add window).
    private func storeBlob(_ blob: DeviceEnrollment) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(blob)

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary,
                                             [kSecValueData as String: data] as CFDictionary)
            guard updateStatus == errSecSuccess else { throw WeftDeviceKeyError.keychainStatus(updateStatus) }
        default:
            throw WeftDeviceKeyError.keychainStatus(addStatus)
        }
    }

    private func loadBlob() throws -> DeviceEnrollment? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data,
                  let blob = try? JSONDecoder().decode(DeviceEnrollment.self, from: data) else {
                throw WeftDeviceKeyError.badEnrollmentBlob
            }
            return blob
        case errSecItemNotFound:
            return nil
        default:
            throw WeftDeviceKeyError.keychainStatus(status)
        }
    }
}
