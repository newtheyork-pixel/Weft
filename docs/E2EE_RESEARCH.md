<!--
End-to-End Encryption for Weft — architecture research report.
Generated 2026-06-16 via a multi-agent research workflow (7 dimensions, adversarial verification).
Grounded in a read-only audit of the phase2-native-wiring branch + Tessera/weft-site + Supabase migrations.
This is a RESEARCH/DESIGN doc, not a committed plan. Decisions in §8 are still open.
-->

# End-to-End Encryption for Weft: Architecture Research Report

> **Founder decisions (2026-06-16):** Target upgraded to **full zero-knowledge — everything encrypted, nothing readable by Weft/Supabase.** Weft is **anti-AI** and is a *different product from Optimize*, so there is **no server-side content processing** to conflict with content E2EE (this *reinforces* the anti-AI brand: "private AND provably human"). The two-tier recommendation in §1/§7 is therefore superseded toward full-ZK; a dedicated **full-ZK addendum** (`E2EE_FULL_ZK.md`) details relational-layer encryption, server-op relocation, and the two irreducible residuals (hosted-OAuth identity + structural metadata). This base doc's crypto architecture (§3), key management (§4), and rollout mechanics (§7) still stand.

## 1. TL;DR / Verdict

**Build it, and build it as multi-recipient envelope encryption — but the cryptography is the easy 30%; key custody and institutional escrow under a passwordless Google-OAuth identity are the real 70%, and they are what will make or break this.** Weft today sits at rung 0 (TLS + Supabase at-rest disk encryption + RLS), where any Supabase admin, service-role key, or DB breach reads every essay, outline, and proctoring image in plaintext. The correct target is rung 3: client-side E2EE where the **student and their teacher** can decrypt but **Supabase cannot**, with a **mandatory institutional escrow recipient** so a lost device never permanently destroys graded coursework. The single most important recommendation: **adopt per-document envelope encryption (random AES-256-GCM content key (DEK) per item, wrapped per recipient via ECDH-P256 + HKDF-SHA256 + AES-GCM), pick P-256 as the one curve end-to-end, and make a school-held escrow key a non-optional co-recipient on every ciphertext from day one.** If you only do one thing this quarter, move the proctoring images off the public bucket and encrypt the not-yet-built screenshot capture — it is the highest harm-reduction-per-effort win and has none of the live-exam fragility of essays.

> **Decisive interop call up front:** there is **no native HPKE in browsers**. CryptoKit has HPKE; Web Crypto does not. So the cross-platform DEK-wrap primitive is **hand-rolled (or library-backed) ECDH-P256 + HKDF-SHA256 + AES-GCM**, specified as a byte-exact versioned envelope shared by both clients — *not* "HPKE on both sides." HPKE remains a fine native-only path on Apple, but the wire format must be one both clients implement natively. This corrects the optimistic "HPKE identically on both clients" framing in the source research.

---

## 2. What "E2EE" Means for Weft & the Threat Model

Weft's access pattern is **multi-recipient, not-the-server**: a student *writes* an essay/outline; that student's *teacher must read it to grade*; grades flow teacher→student. So content must decrypt for **both student and teacher**, but **not** for Supabase. This is the standard "wrap one content key to N recipients" pattern — and critically **not** a group-keying problem. Students never read each other's work, there is no mutually-readable group secret, and there is no forward-secrecy/post-compromise requirement for at-rest exam records. **MLS (RFC 9420) is unwarranted** and would actively conflict with the mandatory escrow requirement.

**What E2EE protects:** confidentiality of essay content, outlines, proctoring imagery, and grade feedback against the Supabase operator, a leaked service-role key, and a database breach. This collapses the breach blast radius and materially strengthens the FERPA posture (the operator stops being a custodian of *plaintext* education records and near-biometric webcam data).

**What it explicitly does NOT protect — state this in the threat-model doc and do not oversell it to schools:**
- A **compromised/XSS'd client.** Keys in IndexedDB and tokens in localStorage are reachable by any script in the page. Non-extractable CryptoKeys block *export* but **not** *use* — injected script can still call `decrypt()`. Non-extractable keys are defense-in-depth/obfuscation, **not** an XSS mitigation. Real mitigations: strict CSP + SRI + dependency hygiene, and steering the most sensitive flows to the native app.
- A **malicious teacher** — they are a legitimate recipient.
- **Metadata.** `word_count`, autosave timestamps/cadence, ciphertext sizes (which leak approximate essay length even without `word_count`), submission times, file counts/sizes, and the wraps table (which reveals the recipient set per document). For a proctored exam this is non-trivial — continuous-autosave `word_count` + timestamps leaks fine-grained writing dynamics (velocity, pauses). Treat it as a **disclosed, accepted leak**, not "low-sensitivity."
- **Server tampering/rollback.** AEAD protects each blob's integrity, but a malicious server can still drop, reorder, replay, or swap ciphertext *rows*. For a graded-exam-integrity product, anti-rollback (signed version chain / monotonic counter) matters for grade disputes — see §6.

**The two paradoxes to design around:**
1. **Proctoring vs. confidentiality:** proctoring imagery is the *most* sensitive data (near-biometric) yet the easiest to encrypt — it's greenfield, one-shot, no AI-grading conflict.
2. **Availability vs. E2EE:** the product's core promise is "a student never loses their work," yet pure E2EE makes **key loss = permanent, unrecoverable data loss** — a worse failure than a breach for this product. This is why escrow is non-negotiable, and why the live-exam path must never block on crypto/network success.

---

## 3. Recommended Cryptographic Architecture

### Envelope (hybrid) encryption — the spine
For each item, generate a fresh random **256-bit DEK**; encrypt the payload with **AES-256-GCM(DEK, fresh-random-96-bit-nonce)**; wrap the DEK once per recipient. This decouples *who can read* (cheap O(1) rewrap of a 32-byte key) from *re-encrypting the body* (the continuously-autosaved essay). Both clients use **OS-native AES-GCM** — CryptoKit `AES.GCM`, Web Crypto `AES-GCM` — zero added libraries for the content layer.

### The DEK-wrap primitive — settled
**Primary cross-platform wrap: ECDH-P256 → HKDF-SHA256 → AES-256-GCM (or AES-KW)** with a fresh ephemeral sender keypair per wrap (ECIES-style, mirroring HPKE's encapsulated key). This is native on **both** sides:
- **Native:** CryptoKit `P256.KeyAgreement` / `SecureEnclave.P256.KeyAgreement` → `sharedSecretFromKeyAgreement` → `hkdfDerivedSymmetricKey` → `AES.GCM.seal`. (Or CryptoKit HPKE-DHKEM-P256 — equivalent, native-only.)
- **Web:** SubtleCrypto `deriveBits(ECDH P-256)` → `importKey(HKDF)` → `deriveKey(AES-GCM/AES-KW)`.

**Curve decision — pick P-256 end-to-end and commit.** This is load-bearing because it cascades into key storage and recovery: **the Secure Enclave supports P-256 only.** If you want hardware-backed non-exportable native keys (you do), you must use P-256 everywhere. (Note: the historical "Web Crypto lacks X25519" reason is now *outdated* — X25519 shipped across all engines in 2024–2025 — but P-256 remains the right call for SE alignment + broadest baseline, not because X25519 is unavailable. You cannot have *both* an SE-protected key *and* an X25519 HPKE ciphersuite.)

> **Footgun warning (verifier-flagged):** the hand-rolled ECDH+HKDF+AES-GCM path requires a **frozen, byte-exact spec** — KDF `info` string, salt, AEAD nonce layout, AAD, and wrapped-DEK encoding — shared across two codebases. Drift causes silent interop *or security* failures. Specify this versioned envelope format as the **first deliverable** and add native-encrypt→web-decrypt (and vice-versa) round-trip tests in CI.

### AES-GCM nonce safety under continuous autosave — the one place this actually bites
A single essay row is upserted every ~0.8s for the whole exam, re-encrypting the full `content_html` under the **same per-submission DEK** with a **fresh random 96-bit nonce each write** (`SecRandomCopyBytes`/`crypto.getRandomValues`; **never** content-derived). Per-document random keys keep you orders of magnitude below the 2³² random-nonce birthday bound — *but* with multi-hour, multi-device, keystroke-level saves over years this must be designed, not assumed. **Decision:** use a **per-(device, session) nonce prefix + monotonic counter**, OR rotate the DEK per session, to eliminate cross-device random-nonce collision risk on flaky reconnects. (XChaCha20-Poly1305 / AES-GCM-SIV would be nicer but are absent from Web Crypto — counter discipline is the realistic cross-platform answer.)

### Multi-recipient wrapping
For each recipient — `{student-self, teacher, institutional-escrow}` (+ optional co-teacher) — wrap the same DEK and store `{recipient_key_id, suite, ephemeral_pub/enc, wrapped_dek}`. Typical essay = 3 wraps. `recipient_key_id` = SHA-256 JWK thumbprint of the public key (rotation-expressible). Decryption: client finds the blob matching a key it holds, unwraps the DEK, AES-GCM-decrypts content.

### AAD binding (mandatory)
Bind **AAD = canonical(submission_id ‖ version ‖ recipient-context)** into **both** the content AEAD **and** every DEK wrap. Without it, the operator (who controls the DB) can swap one student's ciphertext+wraps into another row or replay an old autosave undetected. This is the cheap defense against blob-swap/confused-deputy and partially mitigates row-level tampering.

### Wire/storage format
A **versioned** self-describing envelope, base64url. Content ciphertext (`nonce ‖ ct ‖ tag`) lives in `essay_submissions.content_html` (column stays TEXT) or a private-bucket object; **wraps live in a normalized table**, never crammed into the content column — so adding a recipient is an `INSERT`, not a body rewrite, and RLS scopes wrap rows per recipient. Keep a `suite`/`enc_version` field in every wrap so you can later migrate to CryptoKit's post-quantum X-Wing (ML-KEM, OS 26) without re-architecting.

### Integrity vs. sender authentication
AEAD covers tamper-detection. **Essays: AEAD-only** is acceptable (RLS + auth already attribute the row). **Grades: sign.** Grade feedback (teacher→student) has real non-repudiation value for disputes — but **do not** rely on Web Crypto Ed25519 (it only reached the last engine, Chrome 137, in May 2025; broad coverage ~2027, reintroducing exactly the min-version risk we avoid elsewhere). **Use P-256 ECDSA for grade signatures** (universal Web Crypto support, consistent with the P-256 decision). Note for exam-integrity context: AEAD-only essays mean a DEK-holder can substitute validly-decrypting ciphertext — combine with the AAD binding + version chain (§6) if authorship integrity becomes a requirement.

---

## 4. Key Management (the crux)

Weft's hardest problem: **passwordless Google-OAuth identity → no password-derived key.** No single primitive solves custody. The design below is the only one that satisfies native + web + teacher-grading-on-a-second-Mac simultaneously.

### Identity key — portable, software-synced, SE-gated
- **One identity keypair per user (P-256).** The **private half is wrapped by a KEK and stored as ciphertext in Supabase** (`user_keys.wrapped_privkey`). This blob is the cross-device sync mechanism — no Signal-style QR device-linking ceremony.
- **KEK sources, in priority:**
  1. **WebAuthn PRF** where available (derives a stable 32-byte secret from a synced passkey → HKDF → AES-KW). **Treat PRF as opportunistic, NOT load-bearing.** Support is uneven: Safari PRF only via platform authenticators/iCloud Keychain (not roaming YubiKeys), Firefox/Android weak, and — critically — **PRF output is NOT guaranteed identical across provider ecosystems (Apple iCloud Keychain vs Google Password Manager) or across hybrid/QR transport.** So PRF does not give a portability *guarantee*; a Chromebook student and a Mac student may get different PRF values. Drop any "same KEK everywhere via PRF" assumption.
  2. **User-set encryption passphrase → Argon2id (WASM on web; PBKDF2 ≥600k iters as a weaker fallback)** — the **universal, mandatory fallback**. Tune Argon2id params against your **lowest-end target Chromebook** (memory-hardness, not just time, is the binding constraint — benchmark before committing to any "~250–500 ms" figure).
- **Secure Enclave is a per-device gate, NOT the identity key.** SE keys are P-256-only, hardware-bound, and invisible to the web portal — the opaque blob only that SE can reopen, so it can never roam. Use `SecureEnclave.P256` to wrap/hold the in-memory identity privkey behind Touch ID locally. Never as the cross-recipient identity key.

### Public-key trust/distribution (the gap that, unaddressed, defeats E2EE entirely)
A `recipient_keys`/`public_keys` directory lets any client fetch a wrap-target — but **nothing binds that key to the identity.** A malicious Supabase admin (the exact adversary) can substitute their own key into the directory and silently become a recipient (key-substitution MITM). **This is not optional hardening — without it the server-blind property is not achieved.** Ship:
1. **TOFU pinning** + change warnings + an out-of-band short-fingerprint/SAS verification (iMessage-CKV style).
2. **Sign each identity pubkey with an account-level signing key**, and have the native teacher app publish a **signed roster** of the student keys it grades, so silent substitution is detectable.
3. **Defer full Key Transparency** (CONIKS/log-backed map) — disproportionate infra for a vendor Weft's size; document as roadmap.

> **TOFU's weakest moment is Weft-specific:** the *first autosave of the first exam* encrypts to the teacher's server-asserted pubkey with no prior pin. The signed-roster/account-signing-key mitigation is what closes this; call it out explicitly.

### Recovery & institutional escrow — the K-12 reality
**Make a school-held escrow public key a MANDATORY co-recipient on every ciphertext**, plus issue each student a one-time recovery code. This single move simultaneously solves: key-loss (#1 risk), teacher-key-absent-at-write bootstrapping, multi-device recovery, and FERPA/COPPA lawful-access/records-request obligations — while keeping Supabase blind. This is **rung 3, deliberately not rung 4** (pure no-escrow).

> **State the central tradeoff honestly (verifier-flagged):** escrow re-centralizes trust. Whoever holds the escrow private key can decrypt the **entire school's corpus** — the threat model becomes "trust no one but student+teacher **plus the escrow custodian + their HSM/Shamir quorum.**" This is the highest-value attack target in the system. Mitigate and **specify, not gesture at**: who holds it (school IT vs Weft-as-custodian — affects the FERPA story), where (HSM/KMS), **Shamir M-of-N split among school admins**, per-school (not global) scope, rotation, and an **audited break-glass approval workflow**. Note also: the FERPA *legal* "must retain a recovery key" framing is an interpretation, not black-letter law — the escrow case rests primarily on data-loss/operational grounds and the affirmative records-access-on-request obligation; label it as such.

### Bootstrapping, rotation & re-wrap fan-out
- **Teacher key must exist before a student's first write.** Gate "start exam" on teacher-pubkey-present (preferred). Envelope design allows **lazy re-wrap** later — performed by a key-holding client **or** the escrow key, **never** by an edge function reading plaintext DEK.
- **Re-wrap fan-out is an operational bomb** for the highest-churn data. Teacher rotation/loss requires re-wrapping the DEK of **every** still-relevant essay (potentially hundreds) — doable only by a current DEK-holder (client or escrow), as a background job. **Design lever: prefer a per-class (or per-session) content key wrapped once per class over a per-essay DEK wrapped per row**, to bound re-wrap cost. (Weigh against per-document crypto-shredding granularity — see §5/§6.)
- Student transfer/leave: nothing to re-key; revoke RLS. Crypto-shredding (deleting the wraps) is a clean FERPA delete primitive — call it out as a benefit.

---

## 5. Per-Data-Type Plan (mapped to real schema)

> Verifier corrections folded in: **the Blackbaud edge function does NOT read `essay_grades.points`/`students.email` from the DB — it takes `{session_id, score, total}` from the client request body and the email from the JWT.** So the "encrypting these breaks Blackbaud" justifications in the source research are **factually wrong.** They can stay plaintext for *simplicity/aggregation*, but Blackbaud is not the blocker.

| # | Data (real name) | Encrypt? | Recipients | Storage / key location | Notes |
|---|---|---|---|---|---|
| 1 | `essay_submissions.content_html` | **Encrypt** | student + teacher + escrow | ciphertext in `content_html` (TEXT); wraps in new `essay_dek_wraps(submission_id, recipient_kind, recipient_key_id, wrapped_dek, suite)` | Crown jewel. Stable per-submission DEK, fresh-nonce-per-save; DEK wrapped once at first save. `submit_essay` (timestamp-only) unaffected. |
| 2 | `essay_submissions.word_count` | **Plaintext** (client-computed) | — | unchanged | Keeps teacher dashboard + portal "X words". **Disclosed** leak (writing cadence over autosaves), not "low-sensitivity." |
| 3 | `outline_uploads` file bytes (private bucket `outlines`) | **Encrypt** | student + teacher + escrow | ciphertext object; path `<uid>/<session_id>/<file>` **unchanged** so storage RLS still works; wrap row keyed per `(session_id, user_id)` (table is `UNIQUE(session_id,user_id)`) | Large binary: Web Crypto AES-GCM is single-shot in-memory — **chunk/frame large PDFs/DOCX**, don't assume single-shot. |
| 4 | `outline_uploads.original_name` / `display_name` | **Encrypt** | student + teacher | ciphertext in same columns | Filenames leak topic/identity. `mime_type` + `size_bytes` stay plaintext (Content-Type, UI). |
| 5a | `student_screenshots.url` (PUBLIC `test-media`) | **Encrypt + move to PRIVATE bucket** | teacher + escrow (student optional) | ciphertext in new private `proctoring` bucket, signed URLs; **per-session image DEK wrapped once**, fresh nonce per image | Greenfield native capture → encrypt from day one. Realtime grid decrypts client-side per event. |
| 5b | `students.webcam_snapshot` | **Encrypt in-place** | teacher + escrow | **Currently an inline base64 data URL in the row** (not a bucket pointer) — encrypt the bytes, store ciphertext in column or relocate to private bucket | Distinct remedy from 5a; risk is in-table plaintext PII, not a public URL. |
| 6 | `essay_grades.feedback` (greenfield) | **Encrypt + P-256-ECDSA-sign** | student + teacher + escrow | ciphertext in `feedback`; wraps in `grade_dek_wraps` | Born encrypted — zero migration. Signature for non-repudiation. |
| 7 | `essay_grades.points` / `points_possible` | **Plaintext** | — | unchanged | For gradebook aggregation/simplicity. **Not** a Blackbaud blocker (client supplies score/total). Could be encrypted if desired. |
| 8 | `students.name` / `students.email` | **Plaintext** (data-minimize) | — | unchanged | Needed for roster + RLS `user_id` linkage. Email used for Blackbaud comes from **JWT, not this column**. Residual plaintext-PII surface for FERPA review. |
| 9 | `test_files` / `test_urls` / `test-media` teacher content | **Plaintext** | — | unchanged | "Anyone reads" by design; students must see them. Encrypting needs an unbounded whole-class recipient set for zero benefit. |
| 10 | `blackbaud_connections.access_token`/`refresh_token` | **Out of E2EE scope — app-layer KMS encryption** | — | server-held KMS key | Service-role edge fn MUST use them. **Higher-priority secrets gap than several E2EE items** — plaintext refresh tokens in a DB breach = standing access to schools' Blackbaud SKY data. |

**Pre-implementation audit (verifier-flagged, must close):** confirm the `get_my_returned_work` / `get_my_submission` RPCs are opaque pass-throughs and do **not** parse/transform/filter on `content_html`/`feedback` server-side. If any do, content E2EE breaks them — this is the gap between "mechanical" and "not." Likewise audit the `supabase_realtime` publication: once payloads are ciphertext, the live proctoring grid and any realtime essay-monitoring must decrypt client-side per event.

---

## 6. What It Breaks + Risk Table

| # | Risk | Severity | Likelihood | Mitigation |
|---|---|---|---|---|
| 1 | **Key loss = permanent loss of graded exam** | Catastrophic | High w/o mitigation | **Mandatory school-escrow recipient** + student recovery code. Never single-key. |
| 2 | Live-exam autosave: crypto/network failure bricks in-progress answer | Catastrophic | Low–Med | Keep an **unencrypted local plaintext copy on-device as source of truth** during the exam; encrypted server row is a replica; **never block the keystroke path** on crypto/network. (Note: "encrypted at rest by OS" is true for native/FileVault, **not guaranteed** for a browser IndexedDB copy on arbitrary student disks.) |
| 3 | AES-GCM nonce reuse / cross-device collision under one DEK | Catastrophic (conf+integrity) | Low if coded right | Per-(device,session) nonce prefix + counter, or per-session DEK rotation. |
| 4 | ~~Future server-side AI grading impossible~~ — **NOT A CONSTRAINT** | — | — | **Resolved (founder, 2026-06-16):** Weft is an *anti-AI* proctoring product, distinct from Optimize. No server-side AI grading / embeddings / OCR / full-text search exists or is planned. Full content E2EE has **zero feature conflict**, and "we can't read it, nor can any AI" *reinforces* the anti-AI positioning. |
| 5 | Teacher pubkey absent at first write (bootstrapping) | High | Medium | Gate exam start on teacher pubkey; lazy re-wrap; escrow fallback. |
| 6 | Public-key substitution (server MITM on key directory) | High | Medium | Signed pubkeys + signed teacher roster + TOFU pin. **Without this, E2EE is not actually achieved.** |
| 7 | Server tampering/rollback/row-swap of ciphertext | High (grade disputes) | Medium | AAD-bind (submission_id‖version); client-maintained signed monotonic version chain. |
| 8 | XSS exfiltrates keys/plaintext at runtime | High | Medium | CSP + SRI + dependency hygiene; prefer native for sensitive flows. (Non-extractable keys ≠ XSS defense.) |
| 9 | **Public `test-media` bucket exposes near-biometric minor data** | High | **Realized today** | Move to private bucket + signed URLs **now** (no crypto needed). |
| 10 | Escrow key compromise = whole-school plaintext break | High | Low (if HSM/Shamir) | HSM/KMS, M-of-N Shamir split, per-school scope, audited break-glass. |
| 11 | Multi-device / PRF key desync support burden | Medium | High | Passphrase-wrapped blob as mandatory fallback; PRF opportunistic only. |
| 12 | In-exam re-auth / key-unwrap latency blocks a timed exam | Medium–High | Medium | Cache key material before exam start; never gate keystrokes on a mid-exam passkey/Argon2id prompt. |
| 13 | Loss of server search/analytics/admin-debug | Low | Certain | Accept; client-side or drop. SSE/blind-index leaks pattern+access for low-value gain — **don't adopt.** |
| 14 | `blackbaud_connections` tokens plaintext in DB | High | Realized today | App-layer KMS encryption (separate workstream). |

**Compliance angle:** E2EE genuinely strengthens FERPA (operator stops being a plaintext custodian; breach blast radius collapses) and supports the school-official "direct control" exception. COPPA (<13) is **school-mediated consent**, not per-parent — somewhat less of a hard blocker than implied, but state biometric laws (e.g., NY Ed Law §2-d) are the sharper edge and reinforce encrypting webcam/screenshots. FERPA/COPPA **records-access-on-request** is an affirmative obligation → escrow with **audited access logging** is mandatory, and pure rung-4 is arguably non-compliant.

---

## 7. The Spectrum & Staged Recommendation

**The rungs:** (0) TLS + at-rest disk + RLS — *today; operator sees all plaintext.* (1) server-side/vendor-key column encryption. (2) app-layer envelope, vendor-held keys. (3) **client-side E2EE + institutional escrow ← land here.** (4) pure E2EE, no escrow — *rejected (K-12 data-loss + access obligations).*

**Rung 1 is a dead end on this platform:** Supabase **pgsodium and Transparent Column Encryption are pending deprecation and explicitly not recommended** ("high operational complexity and misconfiguration risk"); TCE was already pulled from the dashboard for "sharp edges." **Vault is a secrets manager, not an operator boundary** — `vault.decrypted_secrets` is service-role-readable (SQL-grant, not cryptographic). Use Vault only to hold KMS/escrow-unwrap credentials. **Skip rung 2** too: Weft's servers never need essay plaintext (submit just timestamps; Blackbaud takes numbers), so rung 2 adds a key server and attack surface for zero confidentiality win — go straight to rung 3.

> **Honesty about effort (verifier-flagged):** "if you only do one crypto thing" hides that the one thing requires the entire substrate — public-key directory, key bootstrap, escrow, recovery, re-wrap, dual-write migration, *and* the cross-platform envelope spec — to exist first. This is a **multi-quarter effort**, not a sprint.

### Sequenced rollout on the live schema

**Phase 0 — this sprint, decoupled from crypto:** Move `test-media` contents to a **private bucket + signed URLs + RLS**. Encrypt `blackbaud_connections` tokens with a server KMS key. Highest harm-reduction-per-effort; no key infra needed.

**Phase 1 — substrate:** Specify the **versioned byte-exact envelope** (KEM=ECDH-P256, KDF=HKDF-SHA256 info/salt, AEAD=AES-256-GCM, nonce layout, AAD, wrapped-DEK encoding); native-encrypt↔web-decrypt round-trips in CI. Ship `public_keys` + `user_keys` tables + key bootstrap at next OAuth login (**native-first** — teacher and student both use the native CryptoKit app): SE-gated P-256 identity key, pubkey upload, passphrase-Argon2id fallback, **mandatory escrow recipient + signed-roster trust**.

**Phase 2 — encrypt greenfield/low-fragility data first:** (a) **proctoring screenshot capture** (born encrypted, no migration); (b) **`outline_uploads`** (one-shot, chunked for large files); (c) **`essay_grades.feedback`** (born encrypted + ECDSA-signed).

**Phase 3 — `content_html` last, behind a flag, with dual-write:**
- *Phase A:* add nullable `content_ciphertext` + wrap columns + `enc_version`; app **dual-writes** plaintext + ciphertext; reads prefer ciphertext when `enc_version` set.
- *Phase B:* backfill old rows by re-encrypting on the **student's next login** (only student/teacher/escrow can produce valid wraps — **never** backfill server-side).
- *Phase C:* **hard cutover** — set a date, stop writing `content_html`, **purge/quarantine un-migrated plaintext.** Do not rely on opportunistic re-login; abandoned accounts would otherwise leave plaintext forever. **Acknowledge the dual-write window is a period of unchanged operator exposure.**

**If you only do one thing:** Phase 0's bucket fix + encrypting the greenfield screenshot capture — biggest compliance ROI, none of the live-exam fragility.

**Long-term target:** rung 3 across essays + outlines + proctoring images + grade feedback, P-256 end-to-end with SE/passkey/passphrase custody, mandatory audited school escrow, PII deliberately plaintext, and a `suite` field ready for the X-Wing/ML-KEM PQ migration.

---

## 8. Open Questions / Decisions Needed from the Founder

1. ~~Optimize AI roadmap vs. essay E2EE.~~ **RESOLVED (founder, 2026-06-16):** Weft is anti-AI and distinct from Optimize — no server-side essay processing now or planned, so content E2EE has no feature conflict. **Encryption bar chosen: full zero-knowledge (everything encrypted). AI grading: N/A.** See `E2EE_FULL_ZK.md`.
2. **Escrow custody:** school IT vs Weft-as-operator? HSM vs Shamir M-of-N among admins? Per-school scope? This *is* the real trust boundary and the FERPA story.
3. **Under-13 deployments (COPPA)?** Drives whether recovery secrets can be student-held or must be school-managed.
4. **Minimum supported macOS + browser matrix.** Confirms P-256 sufficiency (it is) and Argon2id tuning ceiling on lowest-end Chromebooks.
5. **Metadata acceptance:** are `word_count`, autosave cadence, ciphertext-size length-leakage, and the recipient-set-revealing wraps table acceptable to schools, or must any be padded/coarsened?
6. **Co-teacher/TA model:** graders fixed at class creation (wrap at write time) or added later (requires lazy re-wrap)? Drives per-class-key vs per-essay-key.
7. **Curve final sign-off:** confirm P-256 end-to-end (couples to SE-backed keys). This is irreversible-ish once data is encrypted.

---

## 9. Suggested Next Steps

1. **Phase 0 PR (this week, no crypto):** flip `test-media` to a private bucket with RLS + short-lived signed URLs; relocate `student_screenshots`/`webcam_snapshot` reads to signed URLs. Separately, wrap `blackbaud_connections` tokens with a KMS key.
2. **Envelope-spec spike + CI interop test:** write the versioned envelope format doc, then a tiny harness that encrypts a DEK-wrapped AES-GCM blob in **CryptoKit (P256 ECDH→HKDF→AES-GCM)** and decrypts it in **SubtleCrypto**, and vice-versa, with AAD binding. **This de-risks the single biggest interop hazard before any schema work.**
3. **Schema migration sketch (greenfield-safe):**
   - `public_keys(user_id, key_type [secure_enclave|webauthn_prf|escrow], pubkey_spki, fingerprint, created_at)`
   - `user_keys(user_id PK, identity_pubkey, wrapped_privkey, wrap_method, kdf_params jsonb, prf_credential_id, fingerprint, created_at)`
   - `essay_dek_wraps(submission_id, recipient_kind, recipient_key_id, wrapped_dek, suite)` (+ `grade_dek_wraps`, `blob_dek_wraps` or one generic `dek_wraps`)
   - RLS: owner reads/writes own `user_keys`; anyone reads `public_keys`; a user reads only wrap rows addressed to a key they hold.
4. **Audit gaps before claiming "mechanical":** dump the SQL of `get_my_returned_work` / `get_my_submission` and confirm opaque pass-through; check the `supabase_realtime` publication membership and plan client-side decrypt for the live grid.
5. **Prototype the envelope on ONE field end-to-end:** `essay_grades.feedback` (greenfield, single field, signed) — exercises the full path (bootstrap → wrap to student+teacher+escrow → ECDSA-sign → decrypt on both clients) with zero migration risk before touching the autosaved crown jewel.
6. **Escrow break-glass design doc:** custody, Shamir threshold, rotation, and **audited** recovery workflow — required before go-live, since it is the system's highest-value attack target and the FERPA access-on-request mechanism.
