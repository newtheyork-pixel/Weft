//
//  ExamDraftStore.swift
//  Weft — encrypted on-Mac essay drafts so a wifi blip cannot eat the hour.
//
//  The plaintext lives in memory (the NSTextView). On disk it is AES-GCM under
//  a per-account key in the Keychain (this-device, when unlocked). Weft's
//  servers are not involved in this file. Sync is a separate hop: if it fails,
//  the student keeps writing and this copy is what crash-restore reads.
//

import Foundation
import CryptoKit
import Security

enum ExamDraftStore {

    struct Draft: Sendable {
        var html: String
        var wordCount: Int
        var updatedAt: Date
    }

    /// Seal the current essay onto this Mac. False = could not write; the
    /// caller may still try the network.
    @discardableResult
    static func save(userId: String, sessionId: String,
                     html: String, wordCount: Int) -> Bool {
        guard !userId.isEmpty, !sessionId.isEmpty else { return false }
        guard let key = symmetricKey(for: userId),
              let plain = html.data(using: .utf8),
              let sealed = try? AES.GCM.seal(plain, using: key),
              let combined = sealed.combined
        else { return false }
        let payload = FilePayload(v: 1, combined: combined,
                                  updatedAt: Date(), wordCount: wordCount)
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        do {
            let url = try fileURL(userId: userId, sessionId: sessionId)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func load(userId: String, sessionId: String) -> Draft? {
        guard !userId.isEmpty, !sessionId.isEmpty else { return nil }
        guard let url = try? fileURL(userId: userId, sessionId: sessionId),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(FilePayload.self, from: data),
              let key = symmetricKey(for: userId),
              let box = try? AES.GCM.SealedBox(combined: payload.combined),
              let plain = try? AES.GCM.open(box, using: key),
              let html = String(data: plain, encoding: .utf8)
        else { return nil }
        return Draft(html: html, wordCount: payload.wordCount, updatedAt: payload.updatedAt)
    }

    static func remove(userId: String, sessionId: String) {
        guard let url = try? fileURL(userId: userId, sessionId: sessionId) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Disk

    private struct FilePayload: Codable {
        var v: Int
        var combined: Data
        var updatedAt: Date
        var wordCount: Int
    }

    private static func fileURL(userId: String, sessionId: String) throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return root
            .appendingPathComponent("Weft", isDirectory: true)
            .appendingPathComponent("Drafts", isDirectory: true)
            .appendingPathComponent(userId, isDirectory: true)
            .appendingPathComponent("\(sessionId).box", isDirectory: false)
    }

    // MARK: - Keychain

    private static let service = "app.weft.draft-key"

    private static func symmetricKey(for userId: String) -> SymmetricKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: userId,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let added = SecItemAdd(add as CFDictionary, nil)
        if added == errSecDuplicateItem {
            return symmetricKey(for: userId)
        }
        guard added == errSecSuccess else { return nil }
        return key
    }
}
