// Weft E2EE — production Keychain-backed TOFU pin store.
//
// Persists `owner_user_id -> first-seen signing kid` in the OS Keychain
// (kSecClassGenericPassword, data-protection keychain, ThisDeviceOnly). This is
// the durable counterpart to InMemoryTofuPinStore and the real client-side
// defender against server-side key substitution (see PinStore.swift).
//
// Entitlement note: the data-protection keychain requires the app to be signed
// with a keychain-access-group entitlement (every normal signed macOS app has
// one by default). An UNSIGNED binary (e.g. a bare `swift test` run) gets
// errSecMissingEntitlement (-34018); the test suite XCTSkips when that happens.
import Foundation
import Security

/// Keychain operation failure, surfaced by the throwing API.
public enum KeychainPinError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

/// TOFU pin store persisted in the OS Keychain.
///
/// Prefer the throwing API (`verifyThrowing` / `pinnedKidThrowing` / `unpinThrowing`)
/// in production so Keychain failures surface explicitly. The non-throwing
/// `TofuPinStore` conformance is a drop-in for code written against the protocol;
/// it FAILS CLOSED on a Keychain error (treats the store as untrusted) rather than
/// silently trusting.
public final class KeychainTofuPinStore: TofuPinStore {
    private let service: String
    private let accessGroup: String?
    private let queue = DispatchQueue(label: "weft.tofu.keychain")

    /// OSStatus of the most recent Keychain operation (errSecSuccess on success). For diagnostics.
    public private(set) var lastStatus: OSStatus = errSecSuccess

    /// - Parameters:
    ///   - service: Keychain service string namespacing these pins. Default is the production value.
    ///   - accessGroup: Optional keychain access group; nil uses the app's default group.
    public init(service: String = "com.weft.e2ee.tofu-signing-pin", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let g = accessGroup { q[kSecAttrAccessGroup as String] = g }
        return q
    }

    // MARK: - Throwing core (single-item Keychain ops; callers hold `queue`)

    private func readKid(account: String) throws -> String? {
        var q = baseQuery(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        lastStatus = status
        switch status {
        case errSecSuccess:
            guard let data = out as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
            return s
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainPinError.unexpectedStatus(status)
        }
    }

    private func addKid(_ kid: String, account: String) throws {
        var q = baseQuery(account: account)
        q[kSecValueData as String] = Data(kid.utf8)
        // Device-bound, survives reboot, never synced to iCloud — TOFU pins are
        // per-device trust anchors and must not roam.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        lastStatus = status
        guard status == errSecSuccess else { throw KeychainPinError.unexpectedStatus(status) }
    }

    private func deleteKid(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        lastStatus = status
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainPinError.unexpectedStatus(status)
        }
    }

    // MARK: - Throwing public API (preferred)

    public func pinnedKidThrowing(for ownerUserId: String) throws -> String? {
        try queue.sync { try readKid(account: ownerUserId) }
    }

    /// On first use, pins and returns `.pinnedOnFirstUse`. On a match returns `.match`.
    /// On a change returns `.mismatch` WITHOUT overwriting the pin. Read/write is atomic
    /// within this store via a serial queue.
    @discardableResult
    public func verifyThrowing(ownerUserId: String, presentedSigningKid: String) throws -> PinCheckResult {
        try queue.sync {
            if let existing = try readKid(account: ownerUserId) {
                return existing == presentedSigningKid ? .match : .mismatch(pinnedKid: existing)
            }
            try addKid(presentedSigningKid, account: ownerUserId)
            return .pinnedOnFirstUse
        }
    }

    public func unpinThrowing(ownerUserId: String) throws {
        try queue.sync { try deleteKid(account: ownerUserId) }
    }

    // MARK: - TofuPinStore conformance (non-throwing, fails CLOSED on error)

    public func pinnedSigningKid(for ownerUserId: String) -> String? {
        (try? pinnedKidThrowing(for: ownerUserId)) ?? nil
    }

    /// Fails CLOSED: a Keychain error returns a sentinel `.mismatch` so the caller
    /// refuses rather than silently trusting. A real kid is base64(SHA-256(...)) and
    /// never equals the sentinel, so there is no collision. Prefer `verifyThrowing`.
    @discardableResult
    public func verify(ownerUserId: String, presentedSigningKid: String) -> PinCheckResult {
        do {
            return try verifyThrowing(ownerUserId: ownerUserId, presentedSigningKid: presentedSigningKid)
        } catch {
            return .mismatch(pinnedKid: "<keychain-unavailable>")
        }
    }

    public func unpin(ownerUserId: String) {
        try? unpinThrowing(ownerUserId: ownerUserId)
    }
}
