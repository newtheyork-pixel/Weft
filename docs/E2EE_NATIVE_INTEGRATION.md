<!--
Weft E2EE — native integration plan (read-only map). Produced 2026-06-17 by the native lead.
This document does NOT edit the shipped app. Every call site below is cited from the shipped
branch origin/phase2-native-wiring at the line numbers current on that branch. The actual wiring
is a LATER, careful, on-branch task; this is the blueprint for it.
-->

# Weft E2EE — Native Integration Plan

**Scope.** Map exactly where the `WeftCrypto` package (Swift, at `packages/WeftCrypto/`) hooks into
the **shipped** native macOS app (`origin/phase2-native-wiring`, the `Weft/*.swift` target) to make
student content, PII, grades, and proctoring **born-encrypted** against the
[`P256-HKDF-SHA256-AES256GCM`](E2EE_ENVELOPE_SPEC.md) envelope, writing into the
[key/wrap substrate](E2EE_KEY_SUBSTRATE.md)
(`Tessera/supabase/migrations/20260617050000_e2ee_key_substrate.sql`).

**Truth model (from the substrate doc).** `service_role` bypasses RLS, so the substitution defense
is **client-side**: a TOFU pin store of signing keys, a shipped escrow-kid allowlist, and an
external transparency-log mirror. In-DB signatures are tamper-evidence only. That means **all** of
the security-load-bearing work lives in this native code path — it is mandatory, not optional.

## 0. Current state of the pieces (honest)

- **Stage 0 is essentially done — the package now carries the full CryptoKit API, not just
  constants.** `packages/WeftCrypto/Sources/WeftCrypto/`: `Constants.swift` (frozen `suite`/
  `hkdfSalt = weft-e2ee-v1`/`wrapLabel = weft-dek-wrap/v1`/`wrapAAD = weft-wrap/v1`/
  `userKeyAAD = weft-userkey/v1`/`pbkdf2Iterations = 600000`, `B64` helpers, `WeftCryptoError` incl.
  `pinMismatch`); `Envelope.swift` (multi-recipient `WeftEnvelope.seal/open` + `deriveKek`);
  `Identity.swift` (`UserIdentity.generate`, `kid`, `WeftRoster.sign/verify` — raw r‖s, single-hash,
  `weft-pubkey-v1`); `WrappedPrivateKey.swift` (PBKDF2-600k passphrase wrap/open); `PinStore.swift`
  (TOFU protocol + in-memory impl). The JS twin `packages/weft-crypto-js/` is complete (28/28 green)
  and interop is verified both directions — envelope, wrapped-privkey, AND roster signature — via
  `spikes/e2ee-interop/run.sh` plus the package interop tests. Stage-1 trust anchors are also done:
  `KeychainPinStore.swift` (`KeychainTofuPinStore`, fail-closed), `EscrowAllowlist.swift`
  (`WeftEscrowAllowlist`, empty in v1), and `SecureEnclaveStore.swift` (`WeftDeviceKeyStore` —
  Secure Enclave + biometric daily-unlock cache; the Apple-style mirror §1 calls for). **Still
  missing for Stage 1+ (see §8):** framed AEAD for large blobs and the per-(device,session) nonce
  counter.
- The migration is **reviewable, not applied**, and depends on a provisioned `escrow_custodian_uid()`
  and an HSM-published escrow key (substrate doc "pre-apply checklist"). The native bootstrap below
  is one of the three pre-apply gates.
- The shipped app writes **plaintext** today: `content_html`, `essay_grades.feedback`,
  `outline_uploads` + the `outlines` bucket bytes, and (greenfield) proctoring. The plan is a
  **feature-flagged dual-write** so plaintext keeps working until E2EE is proven on real devices.

## 1. Login / OAuth completion — key bootstrap

**Where the session becomes real:**
- `Weft/SupabaseManager.swift:983` `exchangeCode(_:verifier:)` POSTs `grant_type=pkce` and at
  `:999` calls `setSession(accessToken: token.accessToken, refreshToken: token.refreshToken)`. This
  is the *transport* completion. It is invoked from `signInWithGoogle()` (`SupabaseManager.swift:919`)
  and the deep-link tail `handleDeepLink` → `resumeAuthCallback` (`AppState.swift:1457`).
- `Weft/AppState.swift:328` `signInWithGoogle()` is the *app-level* completion: at `:335` it calls
  `supabase.fetchUser()`, sets `userId`/`email`/`displayName`, and at `:339` flips `signedIn = true`,
  then resolves role and routes.

**Hook point: a new `await ensureKeysBootstrapped(user:)` call immediately after
`AppState.swift:339` (`signedIn = true`), before routing.** It must run for **both** teacher and
student (a teacher is also a recipient of their own grade/comment wraps, and the *student's* first
wrap needs the teacher's key to already exist — see §6 ordering). Sequence:

1. **Look up `user_keys` for `auth.uid()`** (`select * where user_id = eq.<uid>`, via the existing
   `SupabaseManager.rows<T>` at `:174`). Two cases:
   - **Row exists (returning device or re-login):** fetch `wrapped_privkey` + `kdf_params`, prompt
     for the encryption passphrase, run `KEK = PBKDF2-HMAC-SHA256(passphrase, salt, 600000, 32)`,
     AES-256-GCM-open the blob with `AAD = userKeyAAD`, recover `identity_d` + `signing_d`. Load the
     keypairs into memory (and, where available, mirror the privkey into the Keychain/Secure Enclave
     for this device so the passphrase isn't re-prompted every launch). On bad passphrase →
     `WeftCryptoError.passphraseWrongOrCorrupt`, surface a retry; **do not** clobber the row.
   - **No row (first login ever):** generate fresh P-256 **identity** (ECDH) and **signing** (ECDSA)
     keypairs; **prompt for a new encryption passphrase** (with a "this cannot be reset by Weft"
     warning — losing it loses the student's content unless escrow recovers it); build the bundle
     `{"identity_d":b64url(32B),"signing_d":b64url(32B)}`, wrap it (PBKDF2→KEK→AES-GCM, `AAD =
     userKeyAAD`), and persist.

2. **Publish public keys** (must be atomic-ish; signing first so identity can reference it):
   - **Signing key** → `public_keys` insert with `key_kind='signing'`, `key_epoch=1`,
     `predecessor_kid=null`, `signer_kid=kid` (**self-signed**), `signature =` ECDSA over SHA-256 of
     the canonical payload `sig_domain‖0x00‖owner_user_id‖0x00‖key_kind‖0x00‖pubkey_b64‖0x00‖kid‖0x00‖key_epoch‖0x00‖''`
     (the SIGNED ROSTER format; substrate `public_keys` CHECK at migration `:117` enforces
     `signer_kid=kid` for signing rows).
   - **Identity key** → `public_keys` insert with `key_kind='identity'`, **signed by the signing key**
     (`signer_kid = signing.kid`, `predecessor_kid=''`).
   - `kid = base64(SHA-256(pubkey_x963_65B))` for each (envelope spec §2).
   - **`user_keys`** → upsert `{user_id, identity_kid, identity_pubkey, wrapped_privkey, wrap_method:'pbkdf2-sha256', kdf_params:{kdf,iters:600000,salt}}`.
     `prf_credential_id` left null in v1 (WebAuthn-PRF is documented future hardening).
   - All four writes go through the existing `SupabaseManager.insert<>`/`upsert<>` (`:190`, `:398`).

3. **Set up the pin store (TOFU).** Persist `owner_user_id → first-seen signing kid` to the OS
   Keychain. On bootstrap, **pin our own** signing kid. The pin store is consulted on every recipient
   fetch (§6). Ship the **escrow-kid allowlist** compiled into the binary (a `WeftCrypto` constant or
   a bundled signed plist), so the client refuses to wrap to any escrow key it doesn't recognize.

**Constraints / notes.**
- This is the **one** synchronous-ish blocking gate that's acceptable to put on the login path
  (it's not the keystroke path). Show a "Setting up secure keys…" state; on failure, **do not enter
  the exam/grading UI in E2EE mode** — fall back to flagged plaintext or block, per §7 flag state.
- The passphrase prompt belongs in a new SwiftUI sheet presented from the `signedIn` transition;
  `SignInView.swift` is the natural host but **is not edited** here — the on-branch task adds a new
  view and presents it.

## 2. Essay autosave — born-encrypted content

**The keystroke → save pipeline (do not break its timing):**
- `Weft/ExamView.swift:468` `scheduleSave()` sets `saveState = .saving`, cancels the prior debounce,
  and at `:473` spawns `saveDebounce = Task { try? await Task.sleep(for: .seconds(0.8)); … await
  persistNow(generation:) }`. **0.8s debounce.**
- `ExamView.swift:480` `persistNow(_:)` calls `await app.autosaveEssay(html: controller.htmlSnapshot(), wordCount:)`,
  and on failure reschedules a 4s retry (`:488`).
- `Weft/AppState.swift:1310` `autosaveEssay(html:wordCount:)` calls
  `supabase.upsertEssaySubmission(...contentHTML: html...)` (`SupabaseManager.swift:697`), which
  upserts `essay_submissions` on conflict `(session_id,student_id,question_id)`.
- `AppState.swift:1330` `submitExam(...)` calls `autosaveEssay` first (final flush) then
  `submit_essay` lock.

**Hook point: inside `AppState.autosaveEssay` (`:1310`), between receiving `html` and calling
`upsertEssaySubmission`.** Transform:

1. **Per-submission DEK, derived once, reused across autosaves of the same submission.** Generate a
   random AES-256 DEK the first time this `(session_id,student_id,question_id)` is written this
   session; **cache it in memory** keyed by submission. (Per envelope spec §5 "nonce discipline":
   for continuous autosave under one DEK use a **per-(device,session) nonce prefix + counter**, not a
   fresh random 96-bit nonce each save — implement the counter in the autosave wrapper so we never
   reuse a (DEK,nonce) pair across the thousands of autosaves a long essay produces.)
2. **Encrypt** `content_html` with the DEK: `AES-256-GCM(DEK, nonce, html_utf8, AAD = "<submission_id>|v<version>")`.
   The AAD binds the ciphertext to the row + version (anti row-swap/rollback). Store
   `ciphertext‖tag` as the new ciphertext column / wrapped value, `nonce` separately.
3. **Wrap the DEK once per submission** to `{student(self), session-teacher, escrow}` and INSERT into
   `dek_wraps` (`item_type='essay'`, `item_id=submission_id`, `session_id`, `recipient_kind`,
   `recipient_user_id`, `recipient_kid`, `eph_pub`, `nonce`, `wrapped_dek`, `suite`). **Wraps are
   written once** (the first save), not every autosave — subsequent autosaves only rewrite the
   content ciphertext (envelope spec §4: "Adding a recipient later is a new wraps[] entry … never a
   content re-encrypt"). The teacher + escrow pubkeys come from §6.

**Keystroke-path-must-not-block constraint.** Encryption is cheap (single AES-GCM over a few KB), but
recipient **fetch + pin verification** must NOT happen on the 0.8s tick. Resolve recipients **once at
exam entry** (when the student registers via `registerStudent`, `SupabaseManager.swift:675`) and
cache `{teacher pubkey, escrow pubkey}` + the DEK + wrap rows. By the time `scheduleSave` fires, the
only per-tick work is one AES-GCM seal + one upsert — identical latency profile to today.

**Local-plaintext-cache safety net.** The shipped failure model (`persistNow` retries every 4s; a
failed flush keeps the student in the exam) must survive E2EE. Keep a **local plaintext autosave
file** on disk (sandbox container, per submission) written on every tick **before** the network
upsert, exactly as the current "the work must not be lost" invariant demands. If key bootstrap failed
or the recipient cache is empty, the exam still runs on plaintext-local + flagged plaintext-DB
(`submitExam` at `:1330` must never return false purely because encryption couldn't initialize — see
§7). The local cache is the student's own machine; it's the recovery path if a wrap/DEK is later
unreadable.

## 3. Grade save + comment save (teacher side)

**Grade save:**
- `Weft/ReviewGradingView.swift:841` `saveCurrentGrade(share:)` → at `:853` `app.saveGrade(...feedback: commentText, share:)`.
- `Weft/AppState.swift:1120` `saveGrade(...)` → `supabase.upsertGrade(...feedback:...)`
  (`SupabaseManager.swift:638`), upsert on conflict `submission_id`. `points`/`points_possible` and
  `released_at` are also sensitive.

**Hook point: inside `AppState.saveGrade` (`:1120`), before `upsertGrade`.**
1. Build the gradable plaintext (the feedback `body`, and — decide per schema — the numeric `points`;
   at minimum `feedback` must be encrypted; points may stay plaintext only if product accepts the
   teacher↔student score being operator-visible, which contradicts the ZK goal, so **encrypt the
   grade payload as a JSON blob** `{points,points_possible,feedback}` under one DEK).
2. **DEK + encrypt** with `AAD = "<submission_id>|grade|v<version>"` (distinct item AAD namespace).
3. **ECDSA-sign** the grade with the teacher's **signing** key (tamper-evidence; same canonical
   approach as roster signing but over the grade payload) and store the signature alongside.
4. **Wrap the DEK** to `{student, teacher(self), escrow}` → `dek_wraps` with `item_type='grade'`,
   `item_id = grade row id` (or `submission_id` if the grade row is keyed by it). Recipient set per
   the LOCKED decision: teacher-authored items wrap to `{student, teacher, escrow}`.
5. `released_at` gating is unchanged — encryption does not alter the share logic at `AppState.swift:1120`.

**Comment save.** The shipped native app surfaces a **single "Final comment"** (the grade `feedback`)
— there is no separate inline-`essay_comments` write path in `origin/phase2-native-wiring`
(the renderer/portal owns inline `essay_comments`; native only reads them back via the
`ReturnedWorkItem.comments` DTO, `SupabaseManager.swift:1029`). So **for native v1 the "comment" is
the grade's `feedback` field and is encrypted in the same blob as the grade** (above). If/when native
gains an inline-comment author path, it follows the identical pattern: encrypt `body`, ECDSA-sign,
wrap to `{student, teacher, escrow}`, `item_type='comment'`. Flag this as a TODO so the JS/portal
side (which DOES write `essay_comments`) and native stay interop-identical.

## 4. Outline upload — encrypt bytes before upload

**Where bytes leave the device:**
- `Weft/AppState.swift:482` `uploadOutline(for:fileURL:)` reads `Data(contentsOf: fileURL)` (`:~513`),
  size-checks (`outlineMaxBytes`, 10 MB), computes `path = "<userId>/<sid>/<name>"`, then at `:515`
  `supabase.uploadOutlineFile(data:path:contentType:)` (`SupabaseManager.swift:820`, raw POST to the
  private `outlines` bucket), then at `:516` `supabase.upsertOutline(...)` writes the metadata row
  (`SupabaseManager.swift:762`).

**Hook point: in `AppState.uploadOutline` (`:482`), between the `Data(contentsOf:)` read and
`uploadOutlineFile`.**
1. **DEK + encrypt the file bytes** with `AAD = "<outline_id>|v1"`. **Large-blob caveat** (envelope
   spec §5): Web Crypto AES-GCM is single-shot in memory and the portal must read these back, so to
   stay interop-identical use a **framed/chunked AEAD** (fixed chunk size, per-chunk nonce =
   prefix‖counter, AAD per chunk binds index) rather than one 10 MB seal — define the framing in
   `WeftCrypto` and mirror it in `weft-crypto-js`. Upload the ciphertext frames instead of plaintext
   to the same `outlines` bucket path.
2. **Wrap the DEK** to `{student(self), session-teacher, escrow}` (student-authored item) →
   `dek_wraps` `item_type='outline'`, `item_id = outline_uploads.id`.
3. **`upsertOutline` metadata stays**, but `mime_type`/`original_name` are now PII-ish — consider
   encrypting `original_name` into the row or accepting it as low-sensitivity metadata (product
   call; note it). `size_bytes` will be the ciphertext size; keep the plaintext size check **before**
   encrypting (it already is, at the `outlineMaxBytes` guard).
4. Preserve the existing "begin-writing lock" semantics (`upsertOutline` returns nil-without-throwing
   on RLS refusal, handled at `AppState.swift:~521`) — encryption is inserted upstream of that and
   doesn't change it. The teacher reads back via `signedOutlineURL` + decrypt using their teacher wrap.

## 5. Proctoring capture (greenfield — born-encrypted when built)

`Weft/ProctoringEngine.swift` today produces a `ProctoringReport` (`:50`) of *checks* (display count,
VM, screen-recording perm, sharing/remote apps) consumed in-memory and folded into the `students` row
at `registerStudent` (`SupabaseManager.swift:675`); **periodic screenshots / capture frames are
deprioritized and NOT built** (`ProctoringEngine.swift:482`–488 product notes; capture is TODO at
`:87`). There is **no proctoring-artifact upload path to hook today.**

**Mandate for when it is built:** proctoring artifacts (screenshots, capture frames, event logs) are
the most sensitive student PII in the system and **must be born-encrypted** — never written plaintext
even transiently to the DB/bucket. Build the capture path to, from the first write: DEK-encrypt each
artifact (`AAD = "<artifact_id>|v1"`, framed AEAD for image blobs as in §4), wrap to
`{student, session-teacher, escrow}` (student-authored), `dek_wraps` `item_type='proctoring'`. Note
that the `students`-row *check booleans* sent at `registerStudent` are low-sensitivity flags and can
stay plaintext in v1, but any **content** (images, raw event streams) is encrypted from birth. This is
a forward constraint on the capture feature, not a change to shipped code.

## 6. Recipients, pin verification, and bootstrapping order

**Fetching recipients.** Read teacher + escrow pubkeys from `public_keys` via the existing
`SupabaseManager.rows<T>` (`:174`). The substrate's scoped SELECT (migration `:123`-ish) lets a
co-session student see the **session teacher's current keys** and the **escrow custodian's** key.
- **Teacher key:** for an essay/outline, the recipient teacher is the **session's** teacher
  (`sessions.teacher_user_id` — resolvable from the session the student joined; the single-teacher
  LOCKED decision means exactly one). Fetch their **identity** (ECDH) pubkey row; verify it is
  signed by their **signing** key, and verify that **signing key against the TOFU pin** (§1.3). On
  pin mismatch → `WeftCryptoError.pinMismatch` → **hard fail with a "key changed" alert**; do not
  silently wrap to a new key (this is the only real substitution detector).
- **Escrow key:** fetch the escrow-custodian row (`owner = escrow_custodian_uid()`,
  `key_kind='escrow'`). **Verify its kid is in the shipped allowlist** before wrapping; refuse
  otherwise. This converts escrow substitution into "requires shipping a malicious signed build."
- **Self (student):** the in-memory identity pubkey from bootstrap; its kid is already pinned.

**Pin verification placement.** Recipient fetch + pin/allowlist verification happens **once at exam
entry** (student side: alongside `registerStudent`, `SupabaseManager.swift:675`) and **once when a
grading session opens** (teacher side: when `ReviewGradingView` loads a roster), NOT on the autosave
tick (§2 constraint). Cache the verified recipient set for the session.

**Bootstrapping order (the make-or-break sequencing).**
1. **Escrow first, off-DB:** HSM-generate the escrow keypair; `publish_escrow_key` (service-role,
   migration `:358`) publishes the public key under the custodian principal; the kid is added to the
   **shipped client allowlist** (binary release). This precedes any student/teacher use.
2. **Teacher before student:** a student's first essay wrap needs the **teacher's published identity
   key to already exist**. The teacher's §1 bootstrap runs at *their* first login. **A student who
   joins a session whose teacher has never logged in / bootstrapped cannot complete a wrap.** Mitigation:
   gate session launch on "teacher has published keys" (a launch-time check in the teacher flow), and
   on the student side, if the teacher key is missing, **fall back to flagged plaintext + local cache**
   (§7) rather than block the exam — losing the exam is worse than a delayed encrypt-on-backfill.
3. **Pin on first sight:** the first time a student encrypts to a given teacher, TOFU-pin that
   teacher's signing kid. Subsequent sessions verify against it.

## 7. Sequenced, feature-flagged rollout

A single build-time/remote flag `e2eeMode ∈ {off, dualWrite, enforced}` gates everything; default
`off` so the shipped behavior is untouched until each stage is proven on real devices.

- **Stage 0 — package real-up (no app edits land yet).** Lift `spikes/e2ee-interop/envelope.swift`
  into `WeftCrypto` as a tested API (§8); add keygen, PBKDF2 privkey wrap/unwrap, ECDSA roster/grade
  signing, the TOFU pin store, the escrow allowlist, framed AEAD, and the per-(device,session) nonce
  counter. Unit-test against `weft-crypto-js` round-trips (extend `run.sh`). **Gate: byte-interop
  green both directions for every item type.**
- **Stage 1 — key bootstrap only (`e2eeMode=off` for content).** Wire §1: generate/publish keys,
  passphrase wrap, pin store, allowlist. No content is encrypted yet. Validates the substrate writes,
  the passphrase UX, and cross-device privkey unwrap. **Reversible** — keys are additive rows.
- **Stage 2 — dual-write (`dualWrite`).** Encrypt + wrap on the student essay path (§2) and teacher
  grade path (§3) **in addition to** the existing plaintext `content_html`/`feedback`. Readers still
  read plaintext. Proves wraps/DEKs/decryptability on real rosters with zero risk to live grading.
  Add outline (§4) here too. **Migration of existing plaintext:** a background **backfill** job
  (client-side, teacher- or student-initiated, never service-role) reads existing plaintext rows the
  user can already see, encrypts + wraps them to the now-published recipients, and writes ciphertext
  + `dek_wraps`; the plaintext column is retained until Stage 3.
- **Stage 3 — enforced (`enforced`).** Readers prefer ciphertext (decrypt via the reader's wrap);
  writers stop writing plaintext; a separate, later migration nulls/drops the plaintext columns
  **only after** a verified backfill + a window of dual-write confidence. `submitExam` and
  `saveGrade` now require a successful wrap (with the local-plaintext-cache still the crash-safety
  net on the student device).
- **Proctoring (§5)** is born-encrypted whenever the capture feature is built; it never has a
  plaintext stage.

## 8. `WeftCrypto` public API the wiring will call (to be added in Stage 0)

Today only `WeftConstants`/`B64`/`WeftCryptoError` exist. The wiring assumes these additions (names
indicative; lift bodies from `spikes/e2ee-interop/envelope.swift`):

- `WeftKeypair.generate() -> (identity, signing)` and `pubkeyX963 / kid` accessors.
- `WeftEnvelope.sealContent(_:dek:aad:nonce:) / openContent(...)` — AES-256-GCM with `ct‖tag` layout.
- `WeftWrap.wrap(dek:toRecipientPubX963:) -> (ephPub,nonce,wrappedDek)` and `unwrap(...)` —
  ECDH→HKDF(`hkdfSalt`,`wrapLabel‖ephPub‖recipPub`)→AES-GCM(`wrapAAD`); `recipientKid(pub)`.
- `WeftUserKey.wrap(identityD:signingD:passphrase:) -> blobJSON` / `unwrap(blob:passphrase:)` —
  PBKDF2(600000)→AES-GCM(`userKeyAAD`); emits/consumes the `{v,kdf,iters,salt,nonce,ct}` JSON.
- `WeftRoster.sign(...) / verify(...)` — the canonical-payload ECDSA over SHA-256 (signing self,
  identity by signing).
- ✅ `KeychainTofuPinStore` / `InMemoryTofuPinStore` — `verifyThrowing(ownerUserId:presentedSigningKid:)` (TOFU; fail-closed Keychain conformance).
- ✅ `WeftEscrowAllowlist.contains(_:) -> Bool` — compiled-in (empty in v1).
- ✅ `WeftDeviceKeyStore` — Secure Enclave + biometric (`.biometryCurrentSet`) device-key cache:
  `enroll(_:)` (after passphrase unlock), `unlock()` (Touch ID, no passphrase), `reset() throws`.
  ECIES-wraps the identity to a non-extractable SE key; AAD binds the account. Passphrase stays the
  cross-device recovery anchor.
- ⬜ Framed AEAD for large blobs (outline/proctoring) and the per-(device,session) nonce counter helper.

Each must be byte-identical to `weft-crypto-js` (extend `spikes/e2ee-interop/run.sh` to cover every
item type + the privkey-bundle round-trip), since native and portal both read every blob.

## 9. Risks

1. **Passphrase loss = data loss.** No Weft-side reset by design. Only escrow (M-of-N school quorum)
   recovers. UX must make this unmistakable at first login (§1). Mitigation: per-device Keychain/SE
   mirror so the passphrase is rarely re-entered, lowering "forgot it" odds.
2. **Teacher-not-bootstrapped-before-student** (§6 ordering). The hard dependency. Mitigation:
   launch-time teacher-key check + student-side flagged-plaintext fallback + backfill, never block an
   in-progress exam.
3. **Autosave latency / nonce reuse.** Naive per-tick recipient fetch would block the 0.8s path; a
   fresh random 96-bit nonce per autosave risks (DEK,nonce) collision over a long essay. Mitigated by
   resolve-once-at-entry caching + a per-(device,session) nonce-prefix counter (§2). Must be load-tested.
4. **Pin-store false positives.** Legitimate teacher key rotation trips `pinMismatch` and blocks
   student wraps. Need a defined, audited re-pin/rotation UX (substrate open decision #3,
   predecessor cross-signature) before `enforced`.
5. **Large-blob / framed-AEAD interop drift** (outline, future proctoring). Single-shot vs framed must
   match JS exactly or blobs won't round-trip; the spike only proved single-recipient single-shot.
   Hard interop test required before Stage 2 ships outlines.
6. **Operator can still forge a roster / drop triggers** (substrate residual #1). In-DB signatures are
   only tamper-evidence; the real defenses are the native pin store, the shipped allowlist, and the
   external transparency-log mirror — all of which are *this* native work. A bug here silently
   removes the only real boundary.
7. **Substrate not yet applicable.** `escrow_custodian_uid()` is a placeholder and the escrow key
   isn't HSM-provisioned. Stage 1+ cannot run end-to-end until the pre-apply checklist (substrate doc)
   is met. Native bootstrap is one of those three gates; treat them as a joint dependency.
8. **Dual-write divergence.** During `dualWrite` a row's plaintext and ciphertext can drift (one write
   succeeds, the other fails). Define ciphertext-authoritative-on-read at Stage 3 and reconcile via
   backfill; never let a half-written row be read as truth.

## 10. Cited call-site index (origin/phase2-native-wiring)

| Concern | File:line | Symbol |
|---|---|---|
| OAuth token exchange / setSession | `Weft/SupabaseManager.swift:983`, `:999` | `exchangeCode` |
| OAuth kickoff | `Weft/SupabaseManager.swift:919` | `signInWithGoogle` |
| Deep-link auth callback tail | `Weft/AppState.swift:1457` | `handleDeepLink` → `resumeAuthCallback` |
| App-level login completion (bootstrap hook) | `Weft/AppState.swift:339` | `signedIn = true` in `signInWithGoogle` |
| Autosave debounce (0.8s) | `Weft/ExamView.swift:468`, `:473` | `scheduleSave` |
| Autosave persist + 4s retry | `Weft/ExamView.swift:480`, `:488` | `persistNow` |
| Essay encrypt/wrap hook | `Weft/AppState.swift:1310` | `autosaveEssay` |
| Essay write (upsert content_html) | `Weft/SupabaseManager.swift:697` | `upsertEssaySubmission` |
| Final flush + lock | `Weft/AppState.swift:1330` | `submitExam` |
| Grade save UI | `Weft/ReviewGradingView.swift:841`, `:853` | `saveCurrentGrade` → `app.saveGrade` |
| Grade encrypt/sign/wrap hook | `Weft/AppState.swift:1120` | `saveGrade` |
| Grade write | `Weft/SupabaseManager.swift:638` | `upsertGrade` |
| Outline encrypt hook | `Weft/AppState.swift:482`, read at `:~513`, upload at `:515` | `uploadOutline` |
| Outline bytes upload | `Weft/SupabaseManager.swift:820` | `uploadOutlineFile` |
| Outline metadata row | `Weft/SupabaseManager.swift:762` | `upsertOutline` |
| Student register (recipient-resolve point) | `Weft/SupabaseManager.swift:675` | `registerStudent` |
| Proctoring (greenfield; born-encrypted later) | `Weft/ProctoringEngine.swift:50`, notes `:482` | `ProctoringReport` |
| Generic reads/writes | `Weft/SupabaseManager.swift:174` / `:190` / `:398` / `:237` | `rows` / `insert` / `upsert` / `rpc` |
| Crypto constants (only existing WeftCrypto source) | `packages/WeftCrypto/Sources/WeftCrypto/Constants.swift` | `WeftConstants`, `B64`, `WeftCryptoError` |
| Substrate migration | `Tessera/supabase/migrations/20260617050000_e2ee_key_substrate.sql` | `public_keys` / `user_keys` / `dek_wraps` / `publish_escrow_key:358` |
