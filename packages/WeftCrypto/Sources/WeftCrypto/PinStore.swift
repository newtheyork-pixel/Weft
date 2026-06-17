// Weft E2EE — TOFU (Trust On First Use) pin store for signing keys.
//
// The ONLY real defender against server-side key substitution (Postgres service_role bypasses RLS).
// Keyed owner_user_id -> first-seen signing kid. verify(pin) hard-fails on a change (Signal-style
// "safety number changed" alert), so a swapped roster row is caught client-side.
//
// This file defines the PROTOCOL + an in-memory test impl. A real Keychain-backed impl is a TODO.
import Foundation

/// A first-seen signing-key pin for an owner.
public struct SigningKeyPin: Equatable {
    public let ownerUserId: String
    public let signingKid: String
    public init(ownerUserId: String, signingKid: String) {
        self.ownerUserId = ownerUserId
        self.signingKid = signingKid
    }
}

/// Result of checking a presented signing kid against the pin store.
public enum PinCheckResult: Equatable {
    /// No pin existed; this kid was just recorded (trust-on-first-use).
    case pinnedOnFirstUse
    /// Matches the existing pin — trusted.
    case match
    /// Differs from the pinned kid — HARD FAIL. The caller must alert + refuse.
    case mismatch(pinnedKid: String)
}

/// TOFU pin store contract. Implementations persist owner -> first-seen signing kid.
public protocol TofuPinStore {
    /// The currently pinned signing kid for an owner, if any.
    func pinnedSigningKid(for ownerUserId: String) -> String?

    /// Check a presented signing kid. On first use, pins it and returns `.pinnedOnFirstUse`.
    /// On a match returns `.match`. On a change returns `.mismatch` WITHOUT overwriting the pin.
    @discardableResult
    func verify(ownerUserId: String, presentedSigningKid: String) -> PinCheckResult

    /// Explicitly remove a pin (e.g. after an out-of-band verified key rotation / re-enrollment).
    func unpin(ownerUserId: String)
}

extension TofuPinStore {
    /// Throwing convenience: throws `WeftCryptoError.pinMismatch` on a changed key, else returns the result.
    @discardableResult
    public func requireTrusted(ownerUserId: String, presentedSigningKid: String) throws -> PinCheckResult {
        let r = verify(ownerUserId: ownerUserId, presentedSigningKid: presentedSigningKid)
        if case let .mismatch(pinnedKid) = r {
            throw WeftCryptoError.pinMismatch(owner: ownerUserId,
                                              pinnedKid: pinnedKid,
                                              presentedKid: presentedSigningKid)
        }
        return r
    }
}

/// In-memory pin store for tests. Thread-safe via a serial queue.
/// TODO: ship a KeychainTofuPinStore (kSecClassGenericPassword, per-owner item) for production.
public final class InMemoryTofuPinStore: TofuPinStore {
    private var pins: [String: String] = [:]
    private let queue = DispatchQueue(label: "weft.tofu.pinstore")

    public init() {}

    public func pinnedSigningKid(for ownerUserId: String) -> String? {
        queue.sync { pins[ownerUserId] }
    }

    @discardableResult
    public func verify(ownerUserId: String, presentedSigningKid: String) -> PinCheckResult {
        queue.sync {
            if let existing = pins[ownerUserId] {
                return existing == presentedSigningKid ? .match : .mismatch(pinnedKid: existing)
            }
            pins[ownerUserId] = presentedSigningKid
            return .pinnedOnFirstUse
        }
    }

    public func unpin(ownerUserId: String) {
        queue.sync { _ = pins.removeValue(forKey: ownerUserId) }
    }
}
