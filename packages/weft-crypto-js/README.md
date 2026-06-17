# weft-crypto-js

Zero-dependency ESM JS crypto core for Weft E2EE. Web Crypto only (Node 22 `webcrypto` == the browser's `SubtleCrypto`, so this is browser-faithful for the portal). Mirrors the Swift `WeftCrypto` core so blobs/keys round-trip cross-platform.

Suite: **`P256-HKDF-SHA256-AES256GCM`**. Frozen constants and byte-layouts match `docs/E2EE_ENVELOPE_SPEC.md`, the proven spike (`spikes/e2ee-interop/envelope.mjs`), and `docs/E2EE_KEY_SUBSTRATE.md`.

## Modules

- `src/envelope.mjs` — `seal({recipientRawPubs, plaintext, submissionId, version})` / `openWithKey(env, privKey, pubRaw)`. Per-item AES-256-GCM DEK; DEK wrapped per recipient via ephemeral ECDH-P256 → HKDF-SHA256 → AES-256-GCM. Multi-recipient (student, teacher, escrow). Reuses the spike's exact HKDF salt `weft-e2ee-v1`, info prefix `weft-dek-wrap/v1` ‖ ephPub(65) ‖ recipPub(65), wrap AAD `weft-wrap/v1`, content AAD `<submissionId>|v<version>`. JWK dev path (`sealToJwk`/`openWithJwk`) for cross-language fixtures.
- `src/keys.mjs` — `generateUserKeys()` → P-256 identity (ECDH) + signing (ECDSA) keypairs, raw X9.63 pubkeys (65B), raw 32B private scalars, kids. Plus scalar↔key import helpers used by the wrapped-key path.
- `src/roster.mjs` — signed-roster signatures. `canonicalPayload`, `signRosterRow`, `verifyRosterRow`, `buildSignedRoster` (signing self-signed, identity signed by the signing key).
- `src/wrappedKey.mjs` — `wrapPrivateKey(passphrase, {identityD, signingD})` / `openPrivateKey(passphrase, blob)`. PBKDF2-HMAC-SHA256 600k → AES-256-GCM, the exact JSON blob.
- `src/pinstore.mjs` — TOFU pin-store interface + `InMemoryPinStore` + `tofuCheck`. The only real key-substitution detector. IndexedDB/keychain impls are documented TODOs.

## kid

`kid = base64( SHA-256( raw X9.63 pubkey ) )` — standard base64 (not base64url).

## Shared formats (must be byte-identical to Swift)

**Wrapped private key** (`user_keys.wrapped_privkey`):
`KEK = PBKDF2-HMAC-SHA256(passphrase_utf8, salt(16B), 600000, 32)`; `bundle = utf8(JSON {"identity_d":b64url(d 32B),"signing_d":b64url(d 32B)})`; `blob = AES-256-GCM(KEK, nonce(12B), bundle, AAD=utf8('weft-userkey/v1'))` stored as `base64(JSON {"v":1,"kdf":"pbkdf2-sha256","iters":600000,"salt":b64,"nonce":b64,"ct":b64(ct‖tag)})`. `kdf_params` jsonb mirrors `{kdf,iters,salt}`.

**Signed-roster signature** (`public_keys.signature`): ECDSA P-256 over SHA-256 of canonical payload `sig_domain 0x00 owner_user_id 0x00 key_kind 0x00 pubkey_b64 0x00 kid 0x00 key_epoch 0x00 coalesce(predecessor_kid,'')` — single 0x00 separators, UTF-8. Signature is raw `r‖s` (64B), base64 — matches CryptoKit `rawRepresentation`. Signing keys self-sign (`signer_kid=kid`); identity keys are signed by the signing key.

## Test

```
npm test            # node --test over test/*.test.mjs
```

28 tests: envelope round-trip + multi-recipient + AAD-tamper/ct-flip negatives, key bootstrap, roster sign/verify, wrapped-key round-trip + shape + wrong-passphrase, pin store, and interop.

## Cross-platform interop contract (for the Swift dev)

`test/interop.test.mjs` has two tiers:

- **[A] live now** — decrypts `spikes/e2ee-interop/env_swift.json` (Swift CryptoKit envelope) with `recipient.priv.jwk`. Passing today (recovers the real plaintext), proving the envelope crypto interoperates JS↔Swift.
- **[B] live now** — reads Swift `WeftCrypto/TestVectors/` (emitted by `WEFT_EXPORT_VECTORS=1 swift test`). Passing today; the vectors exist and the JS suite opens/verifies them:
  - `wrapped_privkey.json`: `{ "passphrase", "blob", "identity_d_b64url", "signing_d_b64url" }` — JS opens `blob` with `passphrase` and asserts the scalars match. (Note: JS produces a fresh random salt/nonce per wrap, so cross-platform parity is verified by **JS opening a Swift-produced blob**, not by byte-equal blobs.)
  - `signed_identity.json`: `{ "owner_user_id","key_kind":"identity","pubkey","kid","key_epoch","predecessor_kid","sig_domain","signer_kid","signature","signing_pubkey" }` — JS verifies the signature with `signing_pubkey`.

Reverse-direction vectors (JS-produced blobs the Swift dev opens): both directions of the wrapped-key and signature formats are deterministic-on-open, so emitting fixtures from either side and opening on the other is sufficient.
