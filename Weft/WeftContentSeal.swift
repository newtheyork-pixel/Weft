//
//  WeftContentSeal.swift
//  Weft — seal an essay to the teacher's (and the student's) essay keys so
//  the server stores ciphertext, not the writing. Suite matches the dormant
//  WeftCrypto package: P256-HKDF-SHA256-AES256GCM.
//
//  Each person has ONE essay key, rebuilt from their essay password
//  (PBKDF2-SHA256, salted with their user id). The password never leaves
//  the Mac. The private key is kept in this Mac's keychain only (never
//  iCloud), so the password is typed once per Mac.
//
//  Essays are never sent unsealed: with no teacher key the exam does not
//  start (see AppState.loadExamRecipientKeys).
//

import Foundation
import CryptoKit
import Security
import CommonCrypto

// MARK: - Wire types (byte-compatible with packages/WeftCrypto Envelope)

struct WeftEnvelope: Codable, Hashable, Sendable {
    var v: Int
    var suite: String
    var content: WeftEnvelopeContent
    var wraps: [WeftEnvelopeWrap]
}

struct WeftEnvelopeContent: Codable, Hashable, Sendable {
    var aad: String
    var nonce: String
    var ct: String
}

/// Short text (a comment quote) sealed with an essay's content key.
struct WeftSealedText: Codable, Hashable, Sendable {
    var v: Int
    var nonce: String
    var ct: String
}

struct WeftEnvelopeWrap: Codable, Hashable, Sendable {
    var recipientKid: String
    var ephPub: String
    var nonce: String
    var wrappedDek: String

    enum CodingKeys: String, CodingKey {
        case recipientKid = "recipient_kid"
        case ephPub = "eph_pub"
        case nonce
        case wrappedDek = "wrapped_dek"
    }
}

/// A published P-256 agreement key (`user_device_keys` row).
struct DevicePublicKey: Codable, Hashable, Sendable {
    var userId: String?
    var kid: String
    var publicX963: String
    /// When the key was published (shown to a teacher for a key they did
    /// not add). Server-stamped text, displayed as-is.
    var createdAt: String? = nil

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case kid
        case publicX963 = "public_x963"
        case createdAt = "created_at"
    }
}

enum WeftContentSeal {

    static let suite = "P256-HKDF-SHA256-AES256GCM"
    private static let hkdfSalt = Data("weft-e2ee-v1".utf8)
    private static let wrapLabel = Data("weft-dek-wrap/v1".utf8)
    private static let wrapAAD = Data("weft-wrap/v1".utf8)
    private static let envelopeVersion = 1
    private static let keychainService = "app.weft.essay-key"
    /// Pre-password keys (one per Mac, some iCloud-synced). Removed on sight.
    private static let oldKeychainService = "app.weft.device-agreement"

    /// Shortest essay password accepted.
    static let minPasswordLength = 12
    /// PBKDF2 rounds: makes each guess at a password slow.
    private static let pbkdf2Rounds: UInt32 = 2_000_000

    // MARK: Essay key

    /// The caller's public key, or nil if this Mac doesn't hold their key yet.
    static func publishableKey(userId: String) -> DevicePublicKey? {
        guard let priv = privateKey(for: userId) else { return nil }
        return publicRecord(of: priv, userId: userId)
    }

    static func publicRecord(of priv: P256.KeyAgreement.PrivateKey, userId: String) -> DevicePublicKey {
        let x963 = priv.publicKey.x963Representation
        return DevicePublicKey(userId: userId, kid: kid(forX963: x963),
                               publicX963: x963.base64EncodedString())
    }

    /// Rebuild the essay key from the password. Slow on purpose (~0.3 s), so
    /// call it off the main thread. Same password + same user = same key.
    static func deriveKey(password: String, userId: String) -> P256.KeyAgreement.PrivateKey? {
        let pw = Array(password.utf8)
        let salt = Array("weft-essay-key/v1|\(userId.lowercased())".utf8)
        var seed = [UInt8](repeating: 0, count: 32)
        let rc = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                      password, pw.count,
                                      salt, salt.count,
                                      CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                      pbkdf2Rounds, &seed, seed.count)
        guard rc == kCCSuccess else { return nil }
        // Turn the seed into a valid P-256 scalar. Almost always the first
        // try works; the counter covers the ~2^-32 chance it doesn't.
        let ikm = SymmetricKey(data: seed)
        for counter in 0..<16 {
            let raw = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm,
                                             info: Data("weft-essay-key/p256/\(counter)".utf8),
                                             outputByteCount: 32)
            let bytes = raw.withUnsafeBytes { Data($0) }
            if let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: bytes) { return key }
        }
        return nil
    }

    /// Keep the key on this Mac (keychain, this device only, never iCloud).
    @discardableResult
    static func saveKey(_ key: P256.KeyAgreement.PrivateKey, userId: String) -> Bool {
        forgetKey(userId: userId)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: userId,
            kSecValueData as String: key.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Drop this Mac's copy of the key (and any pre-password key).
    static func forgetKey(userId: String) {
        for service in [keychainService, oldKeychainService] {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: userId,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            ]
            SecItemDelete(q as CFDictionary)
        }
    }

    static func localRecipient(userId: String) -> P256.KeyAgreement.PublicKey? {
        privateKey(for: userId)?.publicKey
    }

    static func publicKey(from device: DevicePublicKey) -> P256.KeyAgreement.PublicKey? {
        guard let data = Data(base64Encoded: device.publicX963) else { return nil }
        return try? P256.KeyAgreement.PublicKey(x963Representation: data)
    }

    // MARK: Seal / open

    /// Wrap `plaintext` to every recipient. Empty recipients is a no-op error.
    static func seal(plaintext: Data, aad: String,
                     recipients: [P256.KeyAgreement.PublicKey]) throws -> WeftEnvelope {
        guard !recipients.isEmpty else { throw SealError.noRecipients }
        let dekKey = SymmetricKey(size: .bits256)
        let dek = dekKey.withUnsafeBytes { Data($0) }
        let cbox = try AES.GCM.seal(plaintext, using: dekKey,
                                    nonce: AES.GCM.Nonce(),
                                    authenticating: Data(aad.utf8))
        let content = WeftEnvelopeContent(
            aad: aad,
            nonce: Data(cbox.nonce).base64EncodedString(),
            ct: (cbox.ciphertext + cbox.tag).base64EncodedString())

        var wraps: [WeftEnvelopeWrap] = []
        wraps.reserveCapacity(recipients.count)
        for recip in recipients {
            let recipPubRaw = recip.x963Representation
            let eph = P256.KeyAgreement.PrivateKey()
            let ephPubRaw = eph.publicKey.x963Representation
            let shared = try eph.sharedSecretFromKeyAgreement(with: recip)
            let kek = deriveKek(shared: shared, ephPubRaw: ephPubRaw, recipPubRaw: recipPubRaw)
            let wbox = try AES.GCM.seal(dek, using: kek,
                                        nonce: AES.GCM.Nonce(),
                                        authenticating: wrapAAD)
            wraps.append(WeftEnvelopeWrap(
                recipientKid: kid(forX963: recipPubRaw),
                ephPub: ephPubRaw.base64EncodedString(),
                nonce: Data(wbox.nonce).base64EncodedString(),
                wrappedDek: (wbox.ciphertext + wbox.tag).base64EncodedString()))
        }
        return WeftEnvelope(v: envelopeVersion, suite: suite, content: content, wraps: wraps)
    }

    /// Unwrap this Mac's copy of the envelope's content key.
    static func openDEK(envelope env: WeftEnvelope, userId: String) throws -> SymmetricKey {
        guard let privateKey = privateKey(for: userId) else { throw SealError.noDeviceKey }
        let recipPubRaw = privateKey.publicKey.x963Representation
        let myKid = kid(forX963: recipPubRaw)
        guard let w = env.wraps.first(where: { $0.recipientKid == myKid }) else {
            throw SealError.noWrapForRecipient
        }
        guard let ephPubRaw = Data(base64Encoded: w.ephPub),
              let ephPub = try? P256.KeyAgreement.PublicKey(x963Representation: ephPubRaw),
              let wNonce = Data(base64Encoded: w.nonce),
              let wrapped = Data(base64Encoded: w.wrappedDek),
              wrapped.count >= 16
        else { throw SealError.badEnvelope }

        let shared = try privateKey.sharedSecretFromKeyAgreement(with: ephPub)
        let kek = deriveKek(shared: shared, ephPubRaw: ephPubRaw, recipPubRaw: recipPubRaw)
        let wct = wrapped.prefix(wrapped.count - 16)
        let wtag = wrapped.suffix(16)
        let wsb = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: wNonce),
                                        ciphertext: wct, tag: wtag)
        return SymmetricKey(data: try AES.GCM.open(wsb, using: kek, authenticating: wrapAAD))
    }

    static func open(envelope env: WeftEnvelope, userId: String) throws -> Data {
        let dek = try openDEK(envelope: env, userId: userId)
        guard let cNonce = Data(base64Encoded: env.content.nonce),
              let cBytes = Data(base64Encoded: env.content.ct),
              cBytes.count >= 16
        else { throw SealError.badEnvelope }
        let cct = cBytes.prefix(cBytes.count - 16)
        let ctag = cBytes.suffix(16)
        let csb = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: cNonce),
                                        ciphertext: cct, tag: ctag)
        return try AES.GCM.open(csb, using: dek, authenticating: Data(env.content.aad.utf8))
    }

    // MARK: Text sealed under an essay's content key (comment quotes)

    /// AAD binding a sealed quote to its essay, so it can't be moved to another.
    static func quoteAAD(submissionId: String) -> String { "comment-quote|\(submissionId)|v1" }

    /// Seal short text with the content key of an essay this Mac can open.
    /// Whoever can open the essay (teacher, student) can open this; nobody else.
    static func sealText(_ text: String, underEssay env: WeftEnvelope, userId: String,
                         aad: String) -> WeftSealedText? {
        guard let dek = try? openDEK(envelope: env, userId: userId),
              let box = try? AES.GCM.seal(Data(text.utf8), using: dek, nonce: AES.GCM.Nonce(),
                                          authenticating: Data(aad.utf8))
        else { return nil }
        return WeftSealedText(v: 1, nonce: Data(box.nonce).base64EncodedString(),
                              ct: (box.ciphertext + box.tag).base64EncodedString())
    }

    static func openText(_ sealed: WeftSealedText, underEssay env: WeftEnvelope,
                         userId: String, aad: String) -> String? {
        guard let dek = try? openDEK(envelope: env, userId: userId),
              let nonce = Data(base64Encoded: sealed.nonce),
              let bytes = Data(base64Encoded: sealed.ct), bytes.count >= 16,
              let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                               ciphertext: bytes.prefix(bytes.count - 16),
                                               tag: bytes.suffix(16)),
              let data = try? AES.GCM.open(box, using: dek, authenticating: Data(aad.utf8))
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Seal to the given teacher keys plus the writer's own essay key. No teacher key, no envelope: the caller must not send anything.
    static func sealHTML(_ html: String, userId: String,
                         teacherKeys: [DevicePublicKey], aad: String) -> WeftEnvelope? {
        var pubs = publicKeys(from: teacherKeys.filter(isGenuine))
        guard !pubs.isEmpty, let data = html.data(using: .utf8) else { return nil }
        if let selfKey = localRecipient(userId: userId) {
            let raw = selfKey.x963Representation
            if !pubs.contains(where: { $0.x963Representation == raw }) {
                pubs.append(selfKey)
            }
        }
        return try? seal(plaintext: data, aad: aad, recipients: pubs)
    }

    /// True when the key id really is SHA-256 of the key and the key is a
    /// valid P-256 point. Wraps are matched by id, so an id that doesn't
    /// match its key must never be used.
    static func isGenuine(_ device: DevicePublicKey) -> Bool {
        guard let data = Data(base64Encoded: device.publicX963),
              (try? P256.KeyAgreement.PublicKey(x963Representation: data)) != nil
        else { return false }
        return kid(forX963: data) == device.kid
    }

    static func publicKeys(from devices: [DevicePublicKey]) -> [P256.KeyAgreement.PublicKey] {
        devices.compactMap { publicKey(from: $0) }
    }

    static func aad(sessionId: String, studentId: String, questionId: String) -> String {
        "\(sessionId)|\(studentId)|\(questionId)|v1"
    }

    /// Open ciphertext as UTF-8 HTML, or nil if this Mac cannot.
    static func openHTML(_ env: WeftEnvelope, userId: String) -> String? {
        guard let data = try? open(envelope: env, userId: userId) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Internals

    enum SealError: Error {
        case noRecipients, noDeviceKey, noWrapForRecipient, badEnvelope
    }

    private static func kid(forX963 data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private static func deriveKek(shared: SharedSecret, ephPubRaw: Data,
                                  recipPubRaw: Data) -> SymmetricKey {
        let info = wrapLabel + ephPubRaw + recipPubRaw
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: hkdfSalt, sharedInfo: info, outputByteCount: 32)
    }

    private static func privateKey(for userId: String) -> P256.KeyAgreement.PrivateKey? {
        guard !userId.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: userId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let key = try? P256.KeyAgreement.PrivateKey(rawRepresentation: data)
        else { return nil }
        return key
    }
}
