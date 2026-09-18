//
//  WeftContentSeal.swift
//  Weft — seal an essay to the teacher's (and the student's) device keys so
//  the server stores ciphertext, not the writing. Suite matches the dormant
//  WeftCrypto package: P256-HKDF-SHA256-AES256GCM. The private key lives in
//  iCloud Keychain when the Mac syncs, this-device otherwise.
//
//  If the teacher has not published a key yet, autosave stays plaintext so a
//  class is never locked out of grading.
//

import Foundation
import CryptoKit
import Security

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

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case kid
        case publicX963 = "public_x963"
    }
}

enum WeftContentSeal {

    static let suite = "P256-HKDF-SHA256-AES256GCM"
    private static let hkdfSalt = Data("weft-e2ee-v1".utf8)
    private static let wrapLabel = Data("weft-dek-wrap/v1".utf8)
    private static let wrapAAD = Data("weft-wrap/v1".utf8)
    private static let envelopeVersion = 1
    private static let keychainService = "app.weft.device-agreement"

    // MARK: Device key

    /// The caller's agreement public key, creating one if this Mac has none.
    static func publishableKey(userId: String) -> DevicePublicKey? {
        guard let priv = privateKey(for: userId) else { return nil }
        let x963 = priv.publicKey.x963Representation
        return DevicePublicKey(userId: userId, kid: kid(forX963: x963),
                               publicX963: x963.base64EncodedString())
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

    static func open(envelope env: WeftEnvelope, userId: String) throws -> Data {
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
        let dek = try AES.GCM.open(wsb, using: kek, authenticating: wrapAAD)

        guard let cNonce = Data(base64Encoded: env.content.nonce),
              let cBytes = Data(base64Encoded: env.content.ct),
              cBytes.count >= 16
        else { throw SealError.badEnvelope }
        let cct = cBytes.prefix(cBytes.count - 16)
        let ctag = cBytes.suffix(16)
        let csb = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: cNonce),
                                        ciphertext: cct, tag: ctag)
        return try AES.GCM.open(csb, using: SymmetricKey(data: dek),
                                authenticating: Data(env.content.aad.utf8))
    }

    static func sealHTML(_ html: String, userId: String,
                         published: [DevicePublicKey], aad: String) -> WeftEnvelope? {
        let teacherKeys = published.filter { $0.userId != nil && $0.userId != userId }
        guard !teacherKeys.isEmpty, let data = html.data(using: .utf8) else { return nil }
        var pubs = publicKeys(from: published)
        if let selfKey = localRecipient(userId: userId) {
            let raw = selfKey.x963Representation
            if !pubs.contains(where: { $0.x963Representation == raw }) {
                pubs.append(selfKey)
            }
        }
        guard !pubs.isEmpty else { return nil }
        return try? seal(plaintext: data, aad: aad, recipients: pubs)
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
        if let existing = readKey(account: userId) { return existing }
        let created = P256.KeyAgreement.PrivateKey()
        guard storeKey(created, account: userId) else { return nil }
        return created
    }

    private static func readKey(account: String) -> P256.KeyAgreement.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
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

    /// Prefer iCloud Keychain so a second Mac can grade; fall back to this device.
    @discardableResult
    private static func storeKey(_ key: P256.KeyAgreement.PrivateKey, account: String) -> Bool {
        let data = key.rawRepresentation
        if addKey(data, account: account, sync: true) { return true }
        return addKey(data, account: account, sync: false)
    }

    private static func addKey(_ data: Data, account: String, sync: Bool) -> Bool {
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        if sync { add[kSecAttrSynchronizable as String] = kCFBooleanTrue }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem { return readKey(account: account) != nil }
        return status == errSecSuccess
    }
}
