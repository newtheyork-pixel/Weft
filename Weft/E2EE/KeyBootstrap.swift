//
//  KeyBootstrap.swift
//  Weft — E2EE Stage 1 key bootstrap (E2EE_NATIVE_INTEGRATION §1).
//
//  On first login ever: generate identity + signing keypairs, wrap the private
//  bundle under a user passphrase (PBKDF2-600k), publish both public keys to
//  `public_keys`, store the wrapped bundle in `user_keys`, and TOFU-pin our own
//  signing key. On a returning device / re-login: open the stored bundle with
//  the passphrase. NO content is encrypted here — that is Stage 2. This only
//  makes the user a valid crypto recipient.
//
#if canImport(WeftCrypto)
import Foundation
import WeftCrypto

enum KeyBootstrap {

    struct Result {
        let identity: UserIdentity
        /// true if this call generated + published fresh keys (first login ever).
        let createdNewKeys: Bool
    }

    // PostgREST row shapes — snake_case property names == column names, so the
    // SupabaseManager JSONEncoder writes them verbatim (no key conversion).
    private struct UserKeysRow: Decodable {
        let user_id: String
        let wrapped_privkey: String
    }
    private struct UserKeysUpsert: Encodable {
        let user_id: String
        let identity_kid: String
        let identity_pubkey: String
        let wrapped_privkey: String
        let wrap_method: String
        let kdf_params: KdfParams
        let prf_credential_id: String?
    }
    /// Used only to pin the generic `T` for fire-and-forget writes (never decoded).
    private struct PgIgnored: Decodable {}

    /// Idempotent key bootstrap. `passphrase(isNewKey)` is invoked at most once,
    /// and only when a passphrase is actually required.
    static func ensure(
        userId: String,
        supabase: SupabaseManager,
        pinStore: KeychainTofuPinStore = KeychainTofuPinStore(),
        passphrase provide: (_ isNewKey: Bool) async throws -> String
    ) async throws -> Result {
        // 1. Already bootstrapped? Open the stored wrapped bundle.
        let existing: [UserKeysRow] = try await supabase.rows(
            "user_keys",
            query: [
                URLQueryItem(name: "user_id", value: "eq.\(userId)"),
                URLQueryItem(name: "select", value: "user_id,wrapped_privkey"),
            ]
        )
        if let row = existing.first {
            let pass = try await provide(false)
            let identity = try WeftWrappedPrivateKey.open(passphrase: pass, blob: row.wrapped_privkey)
            // TOFU-pin our own signing kid (first-use on this device).
            try pinStore.verifyThrowing(ownerUserId: userId, presentedSigningKid: identity.signingKid)
            return Result(identity: identity, createdNewKeys: false)
        }

        // 2. First login ever: generate, wrap, publish.
        let identity = UserIdentity.generate()
        let pass = try await provide(true)
        let (blob, kdf) = try WeftWrappedPrivateKey.wrap(passphrase: pass, identity: identity)

        // Publish public keys — signing first (self-signed), then identity (signed
        // by the signing key). RLS scopes these inserts to auth.uid() == userId.
        let roster = try identity.signedRoster(ownerUserId: userId)
        _ = try await supabase.insert("public_keys", values: roster.signing, returning: false) as [PgIgnored]
        _ = try await supabase.insert("public_keys", values: roster.identity, returning: false) as [PgIgnored]

        // Store the wrapped private bundle for cross-device sync.
        let payload = UserKeysUpsert(
            user_id: userId,
            identity_kid: identity.identityKid,
            identity_pubkey: identity.identityPubkeyB64,
            wrapped_privkey: blob,
            wrap_method: "pbkdf2-sha256",
            kdf_params: kdf,
            prf_credential_id: nil
        )
        _ = try await supabase.upsert("user_keys", values: payload, onConflict: "user_id", returning: false) as [PgIgnored]

        // TOFU-pin our own signing kid.
        try pinStore.verifyThrowing(ownerUserId: userId, presentedSigningKid: identity.signingKid)

        return Result(identity: identity, createdNewKeys: true)
    }
}
#endif
