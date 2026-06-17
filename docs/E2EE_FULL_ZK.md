<!--
Weft Full Zero-Knowledge E2EE — Addendum to E2EE_RESEARCH.md.
Generated 2026-06-16 via a multi-agent workflow (6 dimensions, adversarial zero-knowledge audit).
Founder decisions: full zero-knowledge target (encrypt everything); Weft is anti-AI (no server content processing).
Extends the base doc — does NOT re-derive the settled envelope/key-custody/escrow primitives.
-->

# Weft Full Zero-Knowledge E2EE — Addendum

> **Status of this document.** This is an *addendum* to the base E2EE design doc (`E2EE_RESEARCH.md`). It does **not** re-derive the settled primitives — the per-document envelope (random AES-256-GCM DEK + fresh nonce; DEK wrapped per recipient via **ECDH-P256 → HKDF-SHA256 → AES-GCM**; AAD-binding `submission_id‖version`; normalized wraps table; byte-exact versioned envelope shared native↔web, no browser HPKE), the key-custody model (Secure-Enclave/WebAuthn-PRF gate, Argon2id-passphrase-wrapped private key for cross-device sync, mandatory school-escrow co-recipient, signed-roster + TOFU), or the two-tier rollout mechanics. Those are **locked**; see the base doc. This addendum covers only what is **new** for the **full-ZK target**: encrypting *everything sensitive* (PII, roster, grades, join codes, proctoring), relocating the last plaintext server operations onto recipient clients, the irreducible residuals, and the claim language that survives a hostile district CTO.

---

> **Founder decision (2026-06-16) — the four residuals are ACCEPTED, not engineered away.** The four asterisks in §1 — (a) auth-layer/Google login identity, (b) structural metadata + membership graph, (c) Blackbaud grade writeback, (d) web-portal weaker than native — are too costly to eliminate and will be **disclosed as accepted limitations** rather than solved. Scope is therefore: **build the achievable full-ZK core** (envelope-encrypt all content/PII/grades/proctoring to {student, teacher, school-escrow}; key bootstrap; mandatory school escrow; the Phase-0 bucket fix; the §4 field fixes; join-code single-use + expire) and **disclose the four**. Resolves open decisions §11.1, §11.3, §11.5 (partial), §11.6, §11.8.

## 1. TL;DR

**Yes — with four named asterisks, stated up front.** Weft can truthfully claim that *all student-generated content, grades, feedback, uploaded outlines, proctoring media, and roster PII are end-to-end encrypted on the client to the student, that student's teacher, and a school-held escrow key, such that neither Weft nor Supabase can read any of it in plaintext — even under server compromise or a subpoena to the vendor.* This is credible **because** Weft is anti-AI: with no AI grading/embeddings/OCR/search and grading done teacher-side in the native client, the server has **zero functional need** for student plaintext, so full-ZK creates **zero feature conflict**. The four asterisks that a CTO *will* find on inspection — and that we therefore concede first — are: **(a)** hosted Google-OAuth/GoTrue necessarily knows the login identity (`auth.users.email` is plaintext, and Google sees every login); **(b)** structural metadata (the class-membership + timing graph, ciphertext sizes, counts, join codes, the per-row recipient set) is server-visible by design and is *not* encrypted; **(c)** the numeric grade leaves the ZK boundary at Blackbaud writeback (school-authorized, to the school's own SIS); **(d)** the **web portal's** "we can't read it" rests on the integrity of server-delivered JavaScript — a strictly weaker guarantee than the signed native app. **Never** claim "zero-knowledge" unqualified, "we don't know who your students are," or "fully anonymous": all four are falsifiable. The defensible claim is **content/grade/PII/proctoring confidentiality**, not metadata or identity anonymity.

---

## 2. What full-ZK changes vs the two-tier base doc

The base doc encrypted the obvious payloads (essay content, outlines, proctoring blobs) and left an explicitly-plaintext tier: `students.name/email`, `word_count`, `points`, `sessions.code`, and the relational/PII layer. **Full-ZK collapses that second tier.** The new posture:

- **Roster PII is encrypted-to-teacher.** `students.name`/`students.email` move from base-doc plaintext to ciphertext wrapped to `{teacher, school-escrow}`. The teacher is a legitimate recipient (must see the roster to grade), so roster *display/sort/search* relocates client-side. RLS is unaffected — it gates on the opaque `auth.uid()` UUID, which never needed PII.
- **Grades and `word_count` are encrypted.** `essay_grades.feedback`/`points`, `essay_comments.{body,quote,prefix,suffix}` (the **live** feedback channel — see §4), and `word_count` upgrade to ciphertext. Server-side `ORDER BY`/aggregation/gradebook math is **lost** and must be recomputed on the teacher client (a real UX/scale cost — disclosed in §11, not hand-waved).
- **Join codes become a peppered hash** — but this is **obfuscation against an external attacker, NOT zero-knowledge against the operator** (the auditor was emphatic; see §4).
- **Everything that stays plaintext is now *deliberate structural plaintext*** (PKs/FKs/`auth.uid`/timestamps/Storage path prefixes) required for RLS and routing, and is **disclosed as metadata**, not silently retained.

Net change in the trust story: under the base doc, a server breach yielded plaintext PII + grades + codes. Under full-ZK (post-cutover), a breach yields **ciphertext + the membership/timing graph + identity-from-auth** — nothing more.

---

## 3. The two irreducible residuals

State these bluntly in every district conversation. No app-layer crypto removes either.

**(a) Hosted Google-OAuth / GoTrue identity.** Weft uses Google OAuth via Supabase Auth (GoTrue). Two parties structurally learn who logged in: **Google** (the IdP authenticates the real account and sees every login event for Weft's `client_id`) and **GoTrue** (`auth.users.email` is stored **plaintext**; `email`+`phone` are **required, non-removable JWT claims**). *Minimize, don't claim to erase:* stop duplicating identity into app tables (encrypt `students.name/email` to the teacher, or drop `email` as redundant with `auth.users`); key **everything** — schema, RLS, edge functions, Storage paths — on `auth.uid()`; **never persist Google's `sub` or email anywhere in app schema/`user_metadata`**; deploy a Custom Access Token Hook to **blank** the `email`/`phone` claims to `""`. **Honesty correction (auditor):** the hook only blanks the **Supabase access token** consumed by PostgREST/RLS/edge-fns/logs — a real *backend* reduction — but the **client still receives the real email** in **Google's `id_token`** at the PKCE callback before any hook runs, so "the client never sees the email" is false. Pairwise/pseudonymous `sub` is a **dead end on Google** (`subject_types_supported: ["public"]` only, verified at the discovery endpoint). `auth.users.email` is protected only by **transparent at-rest disk encryption, which gives no ZK property** (the running DB, Supabase staff, a subpoena, or a DB-read compromise see it) — say exactly that, so the CTO can't catch us conflating disk encryption with zero-knowledge. Self-hosting GoTrue only **moves the custodian** (Supabase → Weft); it does not erase the residual and never blinds Google. **Live-code caveat:** the current `signup` edge function accepts `{email, password}` and `createUser` with a password — contradicting "Google-OAuth-only / no Weft password." Reconcile (delete the password path) or disclose that the edge fn transiently handles a plaintext password.

**(b) Structural metadata + the membership graph.** RLS authorizes on plaintext FKs (`students.user_id=auth.uid()`, `students.session_id`, `sessions.class_id/teacher_user_id`, `essay_submissions.student_id+timestamps`, `class_enrollments`). Therefore the **student↔teacher↔session graph, join times, exam duration, autosave cadence, submission counts, ciphertext sizes (≈ word count), and the per-row recipient/grader set** are permanently server-visible. *Minimize, don't claim to erase:* coarsen/batch timestamps, Padme-pad ciphertext sizes, drop/encrypt `word_count`, use opaque object paths. Hiding the graph itself, decoys, and cover traffic are **theater** — do not promise them. The honest ceiling: *the server can tell that real-person X (known via auth) produced ~N words during the proctored window of class Y* — it just cannot read what X wrote.

---

## 4. Encrypt-everything: per-field map (live schema)

`ENC{r…}` = client-side per-item envelope wrapped to those recipients (always incl. mandatory **escrow**). "Structural plaintext" = required for RLS/routing, disclosed as metadata.

| Field / blob (live table) | Disposition | Recipients / why plaintext | Client-side op replacing lost server capability |
|---|---|---|---|
| `essay_submissions.content_html` (autosaved) | **ENC** | `{student, teacher, escrow}` | autosave writes ciphertext; teacher decrypts to grade |
| `essay_submissions.word_count` | **ENC** (was plaintext) | `{student, teacher, escrow}` | recompute client-side; **also Padme-pad `content_html` ciphertext** or size still leaks the count |
| `essay_comments.{body, quote, prefix, suffix}` ⚠️ **live, was missing from base list** | **ENC** | `{student, teacher, escrow}` | live teacher-feedback channel + verbatim student excerpts — must encrypt |
| `essay_comments.doc_hash` ⚠️ | **DROP or keyed-MAC** | content-equality oracle today | replace with MAC under the DEK so server can't compute/compare |
| `students.answers` (jsonb) ⚠️ **live student content, was missing** | **ENC** | `{student, teacher, escrow}` | treat as content, not metadata |
| `essay_grades.feedback` | **ENC + P256-ECDSA sign** | `{student, teacher, escrow}` | grade authenticity verified on student client |
| `essay_grades.points / points_possible` | **ENC** (was plaintext) | `{student, teacher, escrow}` | gradebook aggregation client-side. **Asterisk:** numeric score still leaves to Blackbaud (§5) |
| `outline_uploads` blob (private `outlines` bucket) | **ENC** (chunked/framed AES-GCM, byte-exact native↔web) | `{student, teacher, escrow}` | path keeps `uid/sessionId` prefix for Storage RLS |
| `outline_uploads.{original_name, display_name, mime_type}` ⚠️ | **ENC** | filenames leak topic/identity — encrypt, don't just pad | display real name only after client decrypt |
| `student_screenshots.url` / `students.webcam_snapshot` | **ENC + MOVE to PRIVATE bucket + signed URLs** | `{student, teacher, proctoring-escrow}` | teacher client fetches blob, decrypts; **URGENT — public today** |
| `students.name / students.email` | **ENC** (was plaintext) | `{teacher, escrow}` | roster sort/search client-side; **does NOT hide identity** — `auth.users.email` still has it (§3a) |
| `students.ip / teacher_ip`, `sessions.teacher_ip` ⚠️ **persisted PII, was missing** | **DROP** (preferred) or disclose | not needed for ZK service | — |
| `sessions.code` (join code) | **Hashed lookup — NOT ZK** (see below) | low-entropy shared secret server must match | — |
| `test_files` / `test-media` test content | Plaintext **by design** (teacher-broadcast) | distributed to all students | — |
| `blackbaud_connections.access_token/refresh_token` | **ENC** `{teacher, escrow}` | server becomes dumb blob store | teacher client decrypts to call SKY |
| PKs, FKs, `user_id=auth.uid()`, timestamps, bucket path prefixes | **Structural plaintext** | RLS/routing require them; opaque | disclosed as membership/timing graph |

**Hashed join codes — the explicit asterisk (trust the auditor over the research).** The base research proposed `HMAC-SHA256(server pepper, code) → indexed hashed_code` and claimed rate-limiting fixes the entropy problem. **That is an overclaim.** `lookup_session_by_code` is **anon-callable pre-auth**, so the pepper must live **inside Supabase's own trust boundary** and be computable on every join — meaning the **operator (or a DB+pepper breach) can brute-force the entire small code space offline and recover every plaintext code.** Rate-limit/lockout are **online** controls and give **zero** protection in the offline post-breach scenario the rest of the design defends against. Therefore: codes are **NOT zero-knowledge against the operator** — only obfuscated against an *external* attacker lacking the pepper. Real mitigations: **(1)** make codes single-use and expire on session close (a recovered code is worthless post-exam), **(2)** move the pepper into a **KMS/edge-secret the DB role cannot read** (so a pure Postgres breach lacks it), **(3)** use 8–10 chars to raise external cost. Even then a service-role/edge compromise recovers it. **Do not claim rate-limiting mitigates the offline case.**

---

## 5. Server-op relocation map (live RPCs / edge fns)

Verdicts: **survives** (opaque) · **ciphertext-router** (data columns become envelopes; logic unchanged) · **moves client-side** · **dies**.

| Server op | Verdict | Notes |
|---|---|---|
| `lookup_session_by_code`, `start_essay`, `submit_essay`, `server_now`, `set_heartbeat_last_seen`, `create/consume_blackbaud_oauth_state`, `check_signup_rate_limit` | **Survives as-is** | touch only UUIDs/status/timestamps/nonces; RLS on `auth.uid()` |
| `join_class_by_code` | **Survives** | `display_name` param → ciphertext-to-teacher. **Sequencing dep:** teacher's pubkey must be published (signed roster) *before* a student can wrap to it; handle join-before-teacher-key |
| `register_student`/`students`, `get_my_submission`, `get_my_returned_work`, `list_class_work`, autosave, `outline_uploads`, proctoring writes | **Ciphertext-routers** | data columns → envelopes; RLS unchanged. ⚠️ **Pre-impl audit still owed:** dump these RPC bodies + the `supabase_realtime` publication to confirm none parse/filter `content_html`/`feedback` server-side. "No server flow needs plaintext" is **contingent on that audit**, not yet established |
| Supabase **Realtime** proctoring grid | **Ciphertext-router (fully ZK)** | Realtime delivers the **row** (with object path) after RLS row-check; it does **not** inspect payloads and does **not** ship the blob. Teacher client receives the row event → **fetches the encrypted blob from the private bucket → decrypts** |
| `blackbaud-callback` | **Dies (native) / transient router (portal)** | currently **confidential** flow (Basic auth, `CLIENT_SECRET`). Native does PKCE code↔token itself; portal may relay transiently, never persisting plaintext |
| `blackbaud-sections`, `blackbaud-assignments` | **Die (native) / relay-or-defer (portal)** | native calls SKY directly (CORS is browser-only; native exempt) |
| `blackbaud-write-grade` | **Dies (native) / thin relay (portal)** — **and must be RE-TIMED** | see verdict below |
| `signup` | **Survives but reconcile** | live code is email+**password** — contradicts OAuth-only; transiently sees plaintext password (§3a) |

**Blackbaud-from-teacher-client verdict.** The writeback fn is the **one true plaintext consumer**: it reads the teacher's stored token + subscription key (service-role), resolves a SKY `user_id` by searching `/school/v1/users?search_text=<student-email>`, and POSTs the grade. **Relocate to the teacher's native macOS app:** CORS is browser-only so native calls `api.sky.blackbaud.com` directly; SKY supports a **PKCE public-app flow (no `client_secret`)**; the token is decrypted from `blackbaud_connections` (now `ENC{teacher,escrow}`) locally. **Three honest asterisks the research glossed (trust the auditor):**
- **Re-timing, not just relocation.** The live fn is "called by the student app right after submit." In the ZK design grading is **teacher-done later** (`essay_grades` isn't even built). Writeback must become **teacher-initiated post-grading** — a behavioral redesign.
- **Student email leaves the ZK boundary to a *third party*.** Resolving the SKY `user_id` sends the student's real email to Blackbaud. This is a school-authorized SIS flow (the district already has a Blackbaud relationship), but it is a real **identity disclosure to an external processor** and belongs in the residual list. *Mitigation:* cache the resolved `sky_user_id` **encrypted-to-teacher** so the email is sent to SKY at most once per student.
- **SKY-API CORS reality + portal residual.** Browser→SKY is **not reliably feasible** (CORS for `api.sky.blackbaud.com` is undocumented; the working Blackbaud PKCE sample runs in a *Chrome-extension* context exempt from page-origin CORS, so it does **not** prove an SPA can call SKY directly). **Portal therefore defers to native** (true ZK), or uses a **thin stateless relay**. That relay is **not** "token+score" — it carries `{teacher bearer token, subscription key, stable per-student sky_user_id, section/assignment ids, grade}` = **identified per-student grade data in transit through Weft infra**. Acceptable only if stateless, non-persisting, and disclosed.
- **Subscription key:** schema stores it **per-teacher**, not as an embeddable app secret — keep it per-teacher (re-encrypted if sensitive); do not bake it into the client binary.

---

## 6. Escrow super-honeypot spec

Escrow is the **dominant residual** — a single key per scope can decrypt a whole school's corpus, *larger* than the OAuth-email surface. Lead the questionnaire with: *"only the student, that student's teacher, and the **school's own** escrow custodian can decrypt — and the escrow key is held by the **school**, in an HSM under M-of-N quorum, **not by Weft**."* If Weft ever held escrow, the ZK claim is materially weaker — say so.

- **Scope:** **per-school root**, never a global key. Within a school, **three separate P-256 keypairs by data class** — `esc-identity`, `esc-content`, `esc-proctoring` (strictest). Per-class **re-wrap** rotation (DEKs unchanged; never touches plaintext).
- **Custody:** non-exportable keys in **AWS CloudHSM**, unwrapped only under **Shamir M-of-N quorum** (e.g., 2-of-3 for content/identity, 3-of-5 for proctoring) held by **named school admins**. Weft hosts the HSM but **cannot meet quorum alone** → preserves FERPA "direct control" by the school.
  - ⚠️ **Auditor correction — drop the "FIPS L3 vs KMS L2" justification: it's stale.** AWS KMS reached FIPS 140-2 L3 (2023) and 140-3 L3 (2024); KMS is no longer Level 2. Both KMS and CloudHSM are FIPS 140-3 L3 today. Justify CloudHSM on **custody model**: dedicated **single-tenant** hardware + **native quorum (M-of-N) auth that KMS lacks** + **school-held quorum operators**. A reviewer who knows AWS will otherwise discount the whole section.
- **Envelope:** reuse the locked design — random AES-256-GCM DEK+nonce, ECDH-P256→HKDF-SHA256→AES-GCM wrap to `{student/teacher, class-escrow}`, AAD-bound `submission_id‖version`, normalized recipient-wraps table with an `escrow_class` discriminator.
- **Break-glass:** **append-only, audited** unwrap, requiring school sign-off + documented reason; logs surfaced to the district.
- **Escrow-pubkey substitution is a covert-backdoor vector** (auditor addition): the escrow pubkey is fetched from the same server; if swapped, Weft silently becomes a recipient on **every future write**. **TOFU pinning must cover the escrow key, verified out-of-band by the district at onboarding** — not just teacher keys. This is mandatory, not optional.
- **Tokens vs escrow (open):** decide whether `blackbaud_connections` tokens are escrow co-recipients or escrow-exempt.

---

## 7. Residual metadata leak table (ranked)

| # | Leak (live source) | Reveals | Worth-it mitigation | Verdict |
|---|---|---|---|---|
| 1 | **Membership + timing graph** (`class_enrollments`, `students.{session_id,user_id}`, `sessions.{class_id,teacher}`, `essay_submissions.{student_id,timestamps}`) | student↔teacher↔session links, join time, exam duration, write cadence | coarsen/batch timestamps | **Coarsen YES; hiding the graph = theater (NO)** |
| 2 | **`auth.users.email` + Google OAuth** | real identity to GoTrue + Google | stop duplicating into app tables; key on `auth.uid()`; blank JWT email claim (backend only) | **De-dup YES; GoTrue/Google copy irreducible** |
| 3 | **Proctoring image presence** (`student_screenshots`, `webcam_snapshot`) + **currently PUBLIC bucket** | capture occurred; **images of minors world-readable today** | **PRIVATE bucket + per-image DEK to `{student,teacher,proctoring-escrow}`** | **YES — URGENT, Phase 0** |
| 4 | **Ciphertext size** (AES-GCM len = plaintext+16; `word_count`; `outline_uploads.size_bytes`) | ≈ essay/outline length & word count | **Padme size-bucketing**; encrypt/drop `word_count` & `size_bytes` | **YES — and required if claiming "metadata minimized"** |
| 5 | **Per-row recipient/grader set** (`dek_wraps`) | who can read each item (co-teacher/TA grader graph) | none structural | **Disclose** |
| 6 | **Join codes** (`sessions.code`) | shared secret operator can brute-force offline | single-use + expire; pepper in KMS | **NOT ZK vs operator (§4)** |
| 7 | **Row counts** (classes/sessions/students/submissions) | class size | none real | **Theater (NO)** |
| 8 | **Blackbaud writeback** | numeric score + student email to SKY (3rd party) | cache `sky_user_id` enc-to-teacher; teacher-client SKY call | **School-authorized residual** |
| 9 | **Persisted IPs** (`students.ip/teacher_ip`, `sessions.teacher_ip`) | network/location PII | **DROP columns** | **YES** |
| 10 | **`essay_comments.doc_hash`** | document-equality oracle | DROP or keyed-MAC | **YES** |
| 11 | **Edge IP / logs** | location/network | log retention policy | **Policy YES** |

**Operational invariant (auditor, mandatory):** every edge fn runs with `SERVICE_ROLE_KEY` and *could* read any plaintext column. The ZK guarantee holds **only if no server-side function ever reads an encrypted-payload column in plaintext form.** Scope service-role functions to non-payload columns and state this invariant explicitly — it is exactly the boundary a CTO probes.

---

## 8. Precedent reality check

**No mainstream E2EE product encrypts user identity — a plaintext auth layer is universal.** Bitwarden stores account email unencrypted as administrative data (and additionally uses it as the master-key KDF salt — *a mechanic Weft does **not** share*, being OAuth-only with no password; cite Bitwarden only for "identity at the auth layer is unencrypted everywhere"). Proton's account/recovery email is not zero-access. **Signal/WhatsApp keep the phone number plaintext at the service layer** while E2EE-ing content. So Weft's `auth.users.email` residual is **the industry norm, not a Weft weakness** — this makes the concession bulletproof.

**Where Weft beats precedent:** Proton encrypts contact names/emails at rest but **not zero-access** (Proton can read them). Weft *can* exceed this for the roster by wrapping `students.name/email` **to the teacher** (a legitimate recipient the server isn't). **Escrow has a real precedent:** Proton's **org-key + non-private-users** model lets admins access user data while Proton stays zero-access — exactly Weft's mandatory school-escrow co-recipient. **Lean on the survivor:** the 2024 ETH/CCS paper broke Sync, pCloud, Icedrive, Seafile (unauthenticated encryption/chunking, key substitution); **Tresorit survived** with authenticated encryption + proper key binding — *Weft's AES-GCM + AAD + fresh nonces + signed-roster/TOFU mirror precisely what let Tresorit survive*. (Correct the research's loose claims: cite the metadata-residual point to Tresorit's own docs, not the break paper; and **MEGA fell to an RSA-CRT key-recovery oracle + unauthenticated AES-ECB malleability**, *not* "RSA reuse" — a crypto-literate CTO will catch the latter. The precise version *strengthens* us: GCM-not-ECB, no RSA-CRT signing.)

**The honest gap:** there is essentially **no mainstream precedent for an app that must bind real student identity to records (roster/grading/SIS writeback) AND claim full ZK.** Every cited precedent (password managers, mail, file sync) has *weaker* identity-binding requirements than a gradebook. The precedent is **thinnest exactly where Weft is hardest.** Don't imply precedent fully covers us. **What Weft can claim:** "content/grade/PII/proctoring E2EE to recipient keys + school escrow, matching or exceeding the strongest consumer E2EE, with a survivor-grade authenticated design." **What Weft cannot claim:** identity anonymity, metadata privacy, or that this is a well-trodden path for identity-bound education records.

---

## 9. The defensible claim

**Tense guardrail (most important, auditor):** the language below is **present-tense and becomes literally true only at Phase-6 hard cutover** for each data class — and is **false during the dual-write window**. **Do not publish a present-tense claim for any data class until its cutover is complete.** Until then the honest statement is *"in active rollout to E2EE; proctoring/grades/outlines are E2EE-at-capture (greenfield); essay content E2EE ships at [date]."* Shipping the present-tense claim early is a contractual/legal exposure, not just embarrassment. Legal/counsel should review the FERPA "direct control" phrasing before it goes in writing.

### 9a. Security-questionnaire / DPA security-exhibit language (paste-ready, with asterisks)

> All student-generated content (essay submissions and autosaved drafts), teacher grades and feedback, proctoring media (webcam and screen captures), uploaded outlines, and roster PII are encrypted **on the client device** (native macOS app and web portal) using **AES-256-GCM with per-item keys** before transmission. Per-item content keys are wrapped to the public keys of **authorized recipients only** — the student, the student's teacher, and a **school-controlled escrow key** — using **ECDH P-256 + HKDF-SHA256**. Decryption keys never leave authorized client devices in usable form. As a result, **Weft and our infrastructure subprocessor (Supabase) cannot read student content, grades, feedback, roster names, or proctoring media in plaintext at any time, including under server compromise or a subpoena to the vendor.**
>
> We disclose the following residuals explicitly:
> **(1) Authentication identity.** Sign-in uses Google OAuth via Supabase Auth (GoTrue). The authentication provider and Google necessarily process the user's login identity (account email) to authenticate. This email is stored by the auth layer protected by transparent at-rest disk encryption only — **this is not zero-knowledge** — and is **not** covered by the content encryption above. We store no student names in readable form in our application database; records are keyed to an opaque identifier.
> **(2) Structural metadata.** To operate the service, our servers can see record counts, encrypted-object sizes, timestamps, the per-item set of authorized recipients, and class-membership relationships. Content is never readable; metadata is.
> **(3) Grade writeback to your SIS.** When a teacher posts a grade to your Blackbaud/SKY gradebook, the numeric score and a Blackbaud student identifier are transmitted to Blackbaud (your existing processor) at the teacher's instruction, as required by the SKY API. The essay text is never transmitted.
> **(4) Web-portal integrity model.** The web portal performs encryption in the browser; its guarantee depends on the integrity of the application code we serve (mitigated by Subresource Integrity, a strict Content-Security-Policy, and a pinned/audited crypto bundle). The **signed, notarized native macOS app provides the strongest guarantee**; the browser client is strictly weaker against a code-supply-chain adversary.
> **(5) Escrow.** A **school-controlled** escrow key is a mandatory co-recipient so the **school** (not Weft) can recover data if a student/teacher loses device access. Weft holds no key that can unilaterally decrypt student content. *(State only once the escrow key-management spec in §6 exists and is auditable — until then this is aspirational and must not be put in writing.)*

### 9b. Contrast line (pre-empt the CTO comparison)

> Unlike vendors who encrypt data at rest while retaining the decryption keys themselves — letting the provider decrypt for search, AI processing, content scanning, or legal requests — Weft is built so the keys to student content reside only on authorized client devices and a **school-held** escrow. We can produce ciphertext of student work, but not plaintext.

### 9c. Pitch line (anti-AI + ZK synergy)

> **Weft is the proctored, provably-human writing platform that even we cannot read or train an AI on — student work is end-to-end encrypted to the student, their teacher, and your school, never to us.** *(Sales expansion: the absence of any server-side AI is **why** no feature needs plaintext, which is **why** the ZK claim is credible rather than aspirational.)*

### 9d. Procurement checklist mapped to the design

| Requirement (NDPA v2.1 / NY Ed Law 2-d / SOPIPA / Pledge) | Weft answer |
|---|---|
| Encryption in transit | TLS via Supabase/PostgREST **+ payloads already ciphertext** — exceeded |
| Encryption at rest | **Exceeded** — recipient-keyed E2EE, not vendor-keyed disk encryption |
| Access controls | RLS on opaque `auth.uid()` + cryptographic access limited to recipient key-holders |
| No secondary use / no sale / no ads / no AI training | **Structurally guaranteed** — server cannot read content |
| Subprocessor list | Supabase (Postgres/Storage/Edge/Auth) + Google OAuth + Blackbaud SKY (teacher-initiated). Each handles only ciphertext or identity/score tokens |
| Breach notification (2-d: 7 calendar days) | Met by policy; **a breach yields only ciphertext + metadata** — *true only post-Phase-6; do not assert pre-cutover* |
| Data deletion / right to be forgotten | **Crypto-shred** — destroy wrapped DEKs + class keys → ciphertext is noise. **NIST SP 800-88 Rev.1 Cryptographic Erase (Purge-level)**. **Conditional:** valid only when **all** key copies are destroyed — server wraps, **all PITR/backup snapshots**, escrow, and relevant client private keys. Specify backup/PITR purge in the shred runbook; do not claim "provable deletion" until that runbook exists |
| Parents' Bill of Rights (NY 2-d) | Publishable, with the five asterisks |
| Audit logs | Access/decryption-attempt logging at client/RLS layer + audited escrow break-glass |

---

## 10. Revised full-ZK rollout (sequenced on the live schema)

- **Phase 0 — Fix the live exposure (pre-crypto).** Make `test-media` **PRIVATE**; serve proctoring images via short-TTL signed URLs; tighten RLS so only the owning teacher's `auth.uid()` mints URLs; revoke existing public URLs. Fixes a current world-readable exposure of minors' images, independent of the ZK program.
- **Phase 1 — Identity-surface minimization.** Stop duplicating `auth.users.email`; plan `students.name/email` as encrypt-to-teacher columns; **drop** persisted IP columns; deploy + branch-test the Custom Access Token Hook (verify it doesn't break GoTrue email-change/recovery); reconcile the password `signup` path; refactor Blackbaud writeback to not read email from the JWT. Keep all RPCs/RLS/Storage paths on `auth.uid()`; never persist Google `sub`/email.
- **Phase 2 — Key bootstrap at next OAuth login (both clients).** Per locked custody: P-256 keypair, Secure-Enclave/WebAuthn-PRF gate + Argon2id-passphrase wrap + **mandatory escrow wrap**; publish pubkeys in a **signed roster**, **TOFU-pin teacher *and* escrow keys** (escrow verified out-of-band by the district).
- **Phase 3 — Greenfield-encrypted-first (no migration window).** Proctoring capture (native, not yet built — encrypt at capture), `essay_grades`/`essay_comments` (born encrypted to `{student,teacher,escrow}`), `outline_uploads` (chunked-AES-GCM client-side). Build the teacher-initiated, re-timed SKY writeback here.
- **Phase 4 — Dual-write migrate (HAS an exposure window — disclose).** `essay_submissions.content_html` + `word_count`, then roster PII, `students.answers`, `essay_comments` legacy. **During dual-write the data is exactly as exposed as today;** encryption confers no benefit until cutover. Keep the window short and gated.
- **Phase 5 — Encrypt remaining relational PII** + implement Padme size-padding, timestamp coarsening, `doc_hash` → keyed-MAC, join-code single-use/expiry + KMS-held pepper.
- **Phase 6 — Hard cutover.** Drop/zero plaintext columns = **crypto-shred the legacy path** (incl. purging backups/PITR of plaintext). **The present-tense claim becomes true — per data class — only here.**

*Pre-implementation gate before any "no server reads plaintext" claim:* dump and confirm the bodies of `get_my_submission`/`get_my_returned_work`/`list_class_work` and the `supabase_realtime` publication are opaque pass-throughs.

---

## 11. Open decisions for the founder

1. **Identity ceiling — RESOLVED, ACCEPT (2026-06-16): stay Google-OAuth-only; vendor-knows-the-account is a disclosed residual, not to be solved.** The honestly-scoped claim ("data ZK, identity minimized but auth provider + Google know the account") is founder-compatible. If procurement *demands* "vendor cannot identify users," that forces a custom IdP (salted-hash) or Apple Hide-My-Email — **reopening the locked Google-OAuth-only + email-recovery-anchor decisions** (note: Apple relay has a known Supabase duplicate-`user_id` bug). *Auditor clarification:* app-layer **key** recovery (Argon2id wrap + escrow) does **not** depend on `auth.users.email`; the real account anchor is the **Google account**, so option (a) is not blocked by key-recovery.
2. **Escrow staffing.** Will districts staff an M-of-N quorum (FERPA "direct control"), or demand Weft-held escrow (materially weaker ZK)? The §6 spec, and the whole "school holds the keys" claim, is only credible once a concrete, auditable escrow key-management + out-of-band-verification + break-glass runbook exists. **This must exist before the escrow sentence ships in any DPA.**
3. **Metadata strength — RESOLVED, ACCEPT (2026-06-16): disclose metadata as visible; do not ship Padme padding / timestamp coarsening unless trivially cheap.** "Metadata visible" (honest minimum) vs "metadata minimized via Padme padding + timestamp coarsening" (stronger). The latter requires actually shipping padding — engineering cost vs claim strength.
4. **Gradebook UX regression.** Encrypting `word_count`/`points`/roster forfeits server-side `ORDER BY`/pagination/aggregation; the teacher client must fetch+decrypt all rows to sort/aggregate at class scale. Accept the regression, or design client-side indices?
5. **Blackbaud minimization — PARTIAL (2026-06-16): disclosure accepted as a school-authorized residual; still relocate writeback to native and cache `sky_user_id` enc-to-teacher (cheap wins). Open only: whether to permit the portal thin-relay.** Mandate teacher-client SKY calls (full ZK for native), or permit the thin portal relay (identified per-student grade in transit)? Cache `sky_user_id` enc-to-teacher to send student email to SKY at most once?
6. **Length disclosure — RESOLVED, ACCEPT (2026-06-16): approximate essay length is a disclosed residual; aggressive padding deferred.** Is approximate essay length an acceptable disclosed residual, or must content ciphertext be aggressively Padme-padded?
7. **Co-teacher/TA grading graph.** Fixed recipient set vs lazy re-wrap — and disclosed as the per-row grader graph either way.
8. **Web-portal trust tier — RESOLVED, ACCEPT (2026-06-16): native = strong-guarantee tier, portal = disclosed weaker (convenience) tier; no reproducible-build investment now.** Position native as the strong-guarantee client and the portal as "convenience, code-integrity-dependent," or invest in reproducible-build attestation / SRI hardening to narrow the gap?
