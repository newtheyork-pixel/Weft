<!--
Weft E2EE — canonical decision log. Produced by the Integration Lead, 2026-06-17.
Single source of truth for all LOCKED decisions. Companion to:
  - docs/E2EE_ENVELOPE_SPEC.md        (envelope wire format + constants)
  - docs/E2EE_KEY_SUBSTRATE.md         (key/wrap substrate design notes)
  - docs/E2EE_NATIVE_INTEGRATION.md    (native app wiring plan)
  - Tessera/supabase/migrations/20260617050000_e2ee_key_substrate.sql (substrate, NOT applied)
  - Tessera/supabase/migrations/20260617060000_e2ee_schools_escrow.sql (school escrow, NOT applied)
Status legend: LOCKED = decided, build to it. ACCEPTED = a residual/limitation we knowingly accept.
TODO = decided in principle, not yet built. WARN-V1 = soft-enforced now, hard-gated later.
-->

# Weft E2EE — Canonical Decision Log

Weft is an anti-AI proctored in-class essay/exam app for schools. The goal is **full zero-knowledge end-to-end encryption**: neither Weft nor Supabase can read student content, PII, grades, or proctoring data. Recipients of any item are exactly `{student, the session's teacher, school escrow}`.

This document is the single source of truth for every locked decision. Each entry carries a **status** and a one-line **rationale**.

## 1. Product framing

| # | Decision | Status | Rationale |
|---|----------|--------|-----------|
| 1.1 | **Full zero-knowledge E2EE** — operator (Weft) and store (Supabase) cannot read content/PII/grades/proctoring. | LOCKED | The product's entire value is trustworthy in-class assessment; the operator must not be a reading party. |
| 1.2 | **Anti-AI proctoring** is the core feature; proctoring artifacts are first-class encrypted items. | LOCKED | Detecting AI-assisted work is the reason schools buy Weft; proctoring data is as sensitive as the essay. |

## 2. Accepted residual exposures (the 4 we knowingly accept)

True ZK cannot be enforced inside Postgres — `service_role` bypasses RLS, so an operator can mint a self-consistent forged roster. We relocate the real defense to the client + HSM (see §6) and accept these residuals explicitly.

| # | Residual | Status | Rationale |
|---|----------|--------|-----------|
| 2.1 | **Identity / social graph** — who is enrolled in which session, teacher↔student edges, timing of submissions are visible to the operator. | ACCEPTED | Required for routing, RLS, and scheduling; encrypting the graph would break the relational substrate. |
| 2.2 | **Metadata** — item types, counts, epochs, key-rotation events, roster shape are visible. | ACCEPTED | Needed for authorization and transparency logging; content stays sealed. |
| 2.3 | **Ciphertext length** — plaintext size leaks (no padding in v1). | ACCEPTED | Length-hiding (padding/framing) is deferred; low signal for essay/exam content. |
| 2.4 | **Web portal trust** — browser delivers JS each load, so the portal cannot offer the same TOFU guarantee as a shipped binary; a malicious served bundle is undetectable to a portal user. | ACCEPTED | The native client carries the strong trust anchor; portal is a convenience surface with disclosed weaker guarantees. |

## 3. Data lifecycle

| # | Decision | Status | Rationale |
|---|----------|--------|-----------|
| 3.1 | **Retain legacy plaintext data** already in the DB; do not destroy it. | ACCEPTED | Existing schools have live data; a destructive cutover is unacceptable. |
| 3.2 | **Greenfield-first content migration**: new items born-encrypted first; existing `content_html`/feedback/outlines handled by a later **dual-write then drop** path. | LOCKED | De-risks rollout — prove encryption on new writes before touching historical rows. |
| 3.3 | **`content_html` dual-write** during transition (encrypted + legacy column) gated by a client flag; drop the plaintext column only after a verified backfill. | LOCKED | Lets reads keep working while the encrypted path is validated; the drop is the irreversible step, so it is gated last. |

## 4. Cryptographic core (frozen wire formats — implement identically in Swift and JS)

| # | Decision | Status | Rationale |
|---|----------|--------|-----------|
| 4.1 | **Curve P-256 (NIST) end-to-end**, suite `P256-HKDF-SHA256-AES256GCM`. | LOCKED | Secure Enclave compatible (native), Web Crypto native (portal), no third-party crypto deps. |
| 4.2 | **Per-item random AES-256-GCM DEK** (nonce 12B, tag 128b; stored bytes = `ciphertext‖tag`, nonce separate). | LOCKED | Per-item DEKs let each item be re-wrapped to its own recipient set without a global key. |
| 4.3 | **DEK wrap** = ephemeral P-256 ECDH → `HKDF-SHA256(salt='weft-e2ee-v1', info='weft-dek-wrap/v1'‖ephPubX963(65)‖recipPubX963(65))` → AES-256-GCM(AAD=`weft-wrap/v1`). `recipient_kid = base64(SHA-256(recipient pubkey x963))`. | LOCKED | Spike-proven, interop-verified Swift↔JS; binding both pubkeys into HKDF info prevents wrap reuse. |
| 4.4 | **Public-key wire** = X9.63 uncompressed `0x04‖X‖Y` (65B), base64. CryptoKit `.x963Representation` == Web Crypto `raw`. | LOCKED | The one encoding that is byte-identical on both platforms. |
| 4.5 | **Wrapped private key**: KEK = **PBKDF2-HMAC-SHA256(passphrase, salt 16B, iters=600000, 32B)**; bundle = `utf8(JSON{identity_d, signing_d})` as base64url-no-pad raw 32B scalars; blob = AES-256-GCM(AAD=`weft-userkey/v1`) stored as `base64(JSON{v,kdf,iters,salt,nonce,ct})`; `kdf_params` mirrors `{kdf,iters,salt}`. | LOCKED | PBKDF2 is native on both CommonCrypto and Web Crypto (no deps), giving cross-platform parity. **Interop-verified: JS opens the Swift-produced blob and recovers exact scalars (interop[B1] PASS).** |
| 4.6 | **PBKDF2-600k now; Argon2id is the documented future hardening.** | LOCKED | Argon2id is memory-hard but not native on both platforms in v1; swap is a clean KDF-id bump (`kdf` field) later. |
| 4.7 | **Signed roster signature**: ECDSA P-256 over SHA-256 of the canonical payload `sig_domain 0x00 owner 0x00 key_kind 0x00 pubkey_b64 0x00 kid 0x00 key_epoch 0x00 coalesce(predecessor_kid,'')` (single 0x00 separators, UTF-8). Signing keys self-signed (`signer_kid=kid`); identity keys signed by the user's signing key. `sig_domain` source of truth = the migration default **`weft-pubkey-v1`**. | LOCKED — §8 RESOLVED | Tamper-evidence in-DB; the canonical payload is interop-verified byte-identical Swift↔JS, and the signature encoding + hashing + domain were reconciled on the Swift side 2026-06-17 (see §8) — roster verification now interoperates (`interop[B2]` PASS). |

## 5. Recipient model

| # | Decision | Status | Rationale |
|---|----------|--------|-----------|
| 5.1 | **Single teacher per session.** Grading is single-teacher; **no co-teacher / no re-wrap in v1.** | LOCKED | Eliminates the hardest key-management case (re-wrapping to a changing recipient set) for v1. |
| 5.2 | **Student-authored items** (essay / outline / proctoring) wrap to `{student, session-teacher, escrow}`. | LOCKED | The student, their grader, and the school recovery quorum are the only legitimate readers. |
| 5.3 | **Teacher-authored items** (grade / comment) wrap to `{student, teacher, escrow}`. | LOCKED | The student must read their own grade; teacher keeps a copy; escrow for recovery. |
| 5.4 | **Mandatory escrow wrap on every item** (DB-enforced via deferred trigger in the substrate). | LOCKED | Guarantees school recoverability; a missing escrow wrap is a data-loss bomb. |
| 5.5 | **Gradebook = client-side aggregate.** No server-side grade aggregation. | ACCEPTED | Grades are encrypted; the server cannot sum them, so aggregation happens in the (trusted) client. |

## 6. Escrow & trust model

| # | Decision | Status | Rationale |
|---|----------|--------|-----------|
| 6.1 | **School-held escrow** — an **M-of-N quorum of the school's own admins**. Weft hosts the HSM but cannot meet quorum alone. | LOCKED | Custody belongs to the school, not Weft; quorum prevents any single admin (or Weft) from unilateral recovery. |
| 6.2 | **Escrow PUBLIC key owned by a custodian principal**; the **escrow PRIVATE key is never in the DB** (HSM/KMS off-DB). `quorum_m/n` are HSM-side policy metadata only. | LOCKED | The DB is honest-but-untrusted; no key material or quorum secret may live where `service_role` can read it. |
| 6.3 | **ZK truth: substitution defense is CLIENT-SIDE** = TOFU pin of signing keys + shipped escrow-kid allowlist + external transparency-log mirror. In-DB signatures are **tamper-evidence only**. | LOCKED | `service_role` bypasses RLS, so the operator can forge a self-consistent roster; only out-of-DB anchors detect it. |
| 6.4 | **Transparency mirror = signed daily git commit to a public repo** (`key_transparency_log` snapshot + SHA-256 hash chain). | LOCKED | A public, append-only, externally-witnessed mirror makes split-view/silent-rotation attacks auditable. |
| 6.5 | **Rotation predecessor cross-sign**: `key_epoch>1` with non-nil `predecessor_kid` should be cross-signed by the predecessor — **WARN in v1, hard-gate later.** | WARN-V1 | The canonical payload already carries `predecessor_kid`; enforcing the cross-sign before rotation UX exists would block legitimate rotation. |

## 7. Platform & roadmap

| # | Decision | Status | Rationale |
|---|----------|--------|-----------|
| 7.1 | **Blackbaud deferred** → becomes a native teacher-client concern when built; placeholder only, do not build now. | LOCKED | Out of the critical E2EE path; integrating an external SIS now adds trust surface for no v1 benefit. |
| 7.2 | **Web portal** ships with disclosed weaker trust (see 2.4); the **native macOS client is the strong trust anchor** (TOFU pin + compiled-in allowlist). | LOCKED | A shipped binary can carry an immutable allowlist + persistent keychain pin; a re-served web bundle cannot. |

## 8. RESOLVED — cross-language roster-signature reconciliation (was OPEN; fixed 2026-06-17)

The envelope and wrapped-private-key formats were already interop-verified (Swift→JS envelope decrypt PASS; Swift wrapped-privkey open under JS PASS). The signed-roster signature initially did NOT interoperate — three concrete divergences, found empirically. **All three are now fixed on the Swift side (`packages/WeftCrypto/Sources/WeftCrypto/Identity.swift`), and the `interop[B2]` roster-verification test PASSES** — `weft-crypto-js` opens and verifies the Swift-produced `signed_identity.json` vector (full JS suite 28/28 green). Kept here for the record:

- **OPEN-1 — signature encoding. RESOLVED.** Swift previously emitted DER (~70–72B), which Web Crypto rejects. Fixed: `Identity.swift` now returns `sig.rawRepresentation` (raw r‖s, 64B) on sign and parses `ECDSASignature(rawRepresentation:)` on verify — matching JS Web Crypto and the substrate intent.
- **OPEN-2 — hashing. RESOLVED.** Swift previously signed `signature(for: SHA256(payload))`, double-hashing because CryptoKit re-hashes its input. Fixed: `Identity.swift` now signs `signingKey.signature(for: key.canonicalPayload())` so CryptoKit applies a single SHA-256 — matching JS `ECDSA-SHA256(payload)`.
- **OPEN-3 — `sig_domain` default. RESOLVED.** Standardized on the migration's `weft-pubkey-v1`: `Identity.signedRoster(...)` defaults `sigDomain = "weft-pubkey-v1"`, matching JS `SIG_DOMAIN_DEFAULT` and the substrate default.

The canonical signing **payload** was already byte-identical across languages; only the wrapper (encoding + hash + domain) needed reconciling, and it now is.

## 9. RESOLVED — substrate schema `wrap_method` CHECK (was OPEN; fixed 2026-06-17)

- **OPEN-4 — `user_keys.wrap_method` CHECK. RESOLVED.** The CHECK initially omitted the value the clients write. Because the substrate migration is reviewable-only (NOT yet applied), the fix landed in-place: `20260617050000_e2ee_key_substrate.sql` now constrains `wrap_method in ('pbkdf2-sha256','argon2id-passphrase','webauthn-prf','argon2id+prf')` — `'pbkdf2-sha256'` (the value both clients write per locked §4.5) is accepted, so no follow-up migration is needed. This was the only client↔schema column mismatch; `dek_wraps` and `public_keys` columns match the clients exactly.
