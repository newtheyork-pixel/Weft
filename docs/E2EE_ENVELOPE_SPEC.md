<!--
Weft E2EE envelope format v1 — the byte-exact, cross-platform spec.
VERIFIED 2026-06-16 by a runnable interop harness: spikes/e2ee-interop/ (CryptoKit <-> Web Crypto, both directions).
This is the "first deliverable" both design docs called the make-or-break item. Do not change constants without re-running run.sh.
-->

# Weft E2EE Envelope Format — v1 (`P256-HKDF-SHA256-AES256GCM`)

**Status: VERIFIED.** A runnable harness at [`spikes/e2ee-interop/`](../spikes/e2ee-interop/) encrypts in Apple **CryptoKit** and decrypts in browser-equivalent **Web Crypto** (Node's `webcrypto` = the same SubtleCrypto API the portal uses) *and the reverse*, plus negative tests for AAD tamper and ciphertext flips. All pass. Run it: `cd spikes/e2ee-interop && ./run.sh`.

This document is the **byte-exact contract** both clients implement. The base design (`E2EE_RESEARCH.md`) and full-ZK addendum (`E2EE_FULL_ZK.md`) depend on it. **Do not change any constant, label, or encoding below without re-running `run.sh`** — a one-byte drift in the HKDF `info` or a swapped tag order causes silent interop or security failure.

## 1. Primitives (one curve, end-to-end)

| Role | Choice | CryptoKit | Web Crypto |
|---|---|---|---|
| KEM curve | **NIST P-256** | `P256.KeyAgreement` (+ Secure Enclave–compatible) | `ECDH`, `namedCurve:'P-256'` |
| Key agreement | ECDH → 32-byte shared X | `sharedSecretFromKeyAgreement` | `deriveBits({name:'ECDH'}, …, 256)` |
| KDF | **HKDF-SHA256** → 32 bytes | `SharedSecret.hkdfDerivedSymmetricKey(using: SHA256.self, …)` | `deriveBits({name:'HKDF', hash:'SHA-256'}, …)` |
| AEAD | **AES-256-GCM**, 96-bit nonce, 128-bit tag | `AES.GCM` | `AES-GCM`, `tagLength:128` |
| Pubkey fingerprint | SHA-256 of the raw public point | `SHA256.hash` | `digest('SHA-256')` |

Rationale for P-256 over X25519 is in `E2EE_RESEARCH.md` §3 (Secure Enclave is P-256-only; both stacks support P-256 natively).

## 2. Encodings (the interop-critical part)

- **Public key on the wire:** X9.63 **uncompressed point** `0x04 ‖ X(32) ‖ Y(32)` = **65 bytes**.
  - CryptoKit `publicKey.x963Representation` **==** Web Crypto `exportKey('raw', …)`. (Confirmed identical in the harness.)
- **ECDH shared secret:** the **32-byte big-endian X coordinate**. CryptoKit's `SharedSecret` raw bytes **==** Web Crypto `deriveBits(ECDH)`. HKDF is then run over those identical bytes on both sides.
- **AES-GCM output ordering:** the stored ciphertext blob is **`ciphertext ‖ tag(16)`** (Web Crypto's native layout). On CryptoKit, write `sealedBox.ciphertext + sealedBox.tag`; on decrypt, split off the last 16 bytes as the tag. The **nonce is stored separately**.
- **Envelope fields:** standard **base64** (not base64url).
- **Key interchange (keys only):** **JWK** (`kty:"EC", crv:"P-256", x,y[,d]`), base64url per the JWK spec. Web Crypto reads JWK natively; CryptoKit builds the point as `0x04 ‖ b64url(x) ‖ b64url(y)` and the private scalar from `b64url(d)`. *(In production, public keys come from the signed key directory, not JWK files — JWK is just the test/dev interchange. Private keys never leave the client in usable form; see key-custody in the base doc.)*

## 3. Construction

**Per item** (essay, grade, file, roster row, …):

1. **Content key (DEK):** random 256-bit key. `AES-256-GCM(DEK, nonce₁(random 12B), plaintext, AAD = "<submission_id>|v<version>")`. The AAD is **bound into the tag** — it cryptographically ties the ciphertext to its row identity + version (anti row-swap / rollback; see addendum §3b).
2. **Wrap the DEK to each recipient** `r ∈ {student, teacher, school-escrow, …}` (ECIES-style, fresh ephemeral key per wrap):
   - ephemeral keypair `E`; `shared = ECDH(E_priv, r_pub)`
   - `KEK = HKDF-SHA256(IKM = shared, salt = "weft-e2ee-v1", info = "weft-dek-wrap/v1" ‖ E_pub(65) ‖ r_pub(65), L = 32)` — binding `E_pub` and `r_pub` into `info` is the HPKE-style key-confirmation that prevents wrap reuse/confusion.
   - `wrapped_dek = AES-256-GCM(KEK, nonce₂(random 12B), DEK, AAD = "weft-wrap/v1")`
   - `recipient_kid = base64(SHA-256(r_pub_raw))`

### Constants (frozen — must match `envelope.swift` and `envelope.mjs`)
| Name | Value (UTF-8 bytes) |
|---|---|
| suite | `P256-HKDF-SHA256-AES256GCM` |
| HKDF salt | `weft-e2ee-v1` |
| HKDF info prefix | `weft-dek-wrap/v1` |
| DEK-wrap AAD | `weft-wrap/v1` |
| content AAD | `<submission_id>\|v<version>` |

## 4. Wire format

```json
{
  "v": 1,
  "suite": "P256-HKDF-SHA256-AES256GCM",
  "content": { "aad": "<submission_id>|v<version>", "nonce": "<b64 12B>", "ct": "<b64 ciphertext‖tag>" },
  "wraps": [
    { "recipient_kid": "<b64 sha256(r_pub)>", "eph_pub": "<b64 65B x963>", "nonce": "<b64 12B>", "wrapped_dek": "<b64 48B = ct(32)‖tag(16)>" }
  ]
}
```
Decryptor: compute its own `recipient_kid`, find the matching wrap, ECDH+HKDF→KEK, unwrap DEK, AES-GCM-open `content`. Adding a recipient later is a new `wraps[]` entry (an INSERT), never a content re-encrypt — in production the `wraps` live in a normalized table, not inline (see base doc §3).

## 5. What the spike proves — and what it deliberately leaves to production

**Proven:** the cryptographic core interoperates byte-for-byte across CryptoKit and Web Crypto, both directions; AAD binding and AEAD integrity are enforced (tamper rejected).

**Not yet built here (intentionally — these are the next deliverables, not crypto risks):**
- Multi-recipient wrapping (structure is present; spike exercises one recipient).
- The **key directory + signed roster + TOFU pinning** (incl. the escrow pubkey) — the trust layer from the addendum.
- **Key custody** (Secure Enclave / WebAuthn-PRF gate, Argon2id-passphrase-wrapped private key) — keys here are throwaway JWKs.
- **Nonce discipline at scale:** per the base doc §3, continuous autosave under one DEK should use a per-(device,session) nonce prefix + counter, or per-session DEK rotation, rather than the simple random 96-bit nonce used in this single-shot spike.
- **Chunked/framed AEAD** for large `outline_uploads` blobs (Web Crypto AES-GCM is single-shot in memory).
- `suite`/`v` negotiation for the future PQ migration (X-Wing/ML-KEM).

## 6. Files
- [`spikes/e2ee-interop/envelope.swift`](../spikes/e2ee-interop/envelope.swift) — CryptoKit reference impl + CLI.
- [`spikes/e2ee-interop/envelope.mjs`](../spikes/e2ee-interop/envelope.mjs) — Web Crypto reference impl + CLI (browser-faithful).
- [`spikes/e2ee-interop/run.sh`](../spikes/e2ee-interop/run.sh) — the cross-language + negative test harness.
