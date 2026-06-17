<!--
Weft E2EE key/wrap substrate — design notes for migration 20260617050000_e2ee_key_substrate.sql.
Produced 2026-06-17 via a draft → 4-lens adversarial red-team → hardened-synthesis workflow.
Reviewable-only; the migration is NOT applied. This doc holds the reasoning + open decisions; the
SQL file holds the threat model + per-object comments.
-->

# Weft E2EE Key/Wrap Substrate — Design Notes

Companion to **`Tessera/supabase/migrations/20260617050000_e2ee_key_substrate.sql`** (reviewable, **not applied**). This is the *substrate* only — the key directory, wrapped-private-key store, per-item DEK wraps, escrow routing, and a key-transparency log. It does **not** migrate any content to ciphertext (that's a later phase).

Built by drafting the full migration, then **red-teaming it from four independent angles** (RLS bypass, key-substitution/trust, escrow/service-role boundary, Postgres correctness). The red-team returned **"serious-holes" on the RLS and trust lenses** — those holes are now fixed. The fixes are summarized below because they encode the real lessons.

## The one truth that reframes everything

**Zero-knowledge against the operator cannot be enforced in Postgres.** Anything holding `service_role` bypasses RLS, and an operator who controls the DB can mint a fully self-consistent forged key roster. The draft's central claim — "in-DB signatures make server substitution detectable" — was **circular and false**. So the substitution defense is **relocated out of the database**, and the SQL is honest about it:

- **Client-side TOFU pin store** (OS keychain / IndexedDB), keyed `owner → first-seen signing key`; hard-fail + "key changed" alert on mismatch (Signal-style safety number). **This is the only real detector.**
- **A hard-coded escrow-key allowlist shipped in the client binary** — the client refuses to wrap to any escrow key it doesn't recognize. This converts escrow substitution from a *silent single-RPC operator backdoor* into *"requires shipping a malicious signed client build"* — auditable.
- In-DB aids (signatures, immutability triggers, `key_epoch`/`predecessor_kid` continuity chain, append-only **`key_transparency_log`**) are **tamper-evidence only** — they make split-view/silent-rotation attacks costlier and externally auditable, not impossible. Documented as such, so no reviewer mistakes them for a boundary.

Practically: the security of this whole scheme lives in **the native/web client code and the HSM**, with Postgres as an honest-but-untrusted store. That's the correct shape for E2EE — but it means the client work (pin store + allowlist + signature verification) is *mandatory*, not optional.

## Escrow decision: per-teacher routing, custody decoupled from the teacher

There is no school/org entity in the schema, so escrow is scoped **per-teacher (interim approach B)** — but the red-team killed the draft's naive version (which wrapped escrow to a key the *teacher* controlled — i.e. just a second teacher copy, no real custodian). The hardened model:

- Every escrow public key is owned by a **single fixed HSM-backed custodian principal** (`escrow_custodian_uid()`), **never a teacher**.
- `escrow_custodians(teacher → escrow_kid)` only *routes*; the **escrow private key is generated in and never leaves an HSM/KMS** — there is no column for it and no human/teacher holds it.
- Path to **per-school escrow (A)** needs **no `dek_wraps` schema change** (rows key off `recipient_kid`): add `schools`/`school_members`, publish a school custodian key, repoint routing, update the client allowlist. (Widens trust — any school custodian can recover any in-school item — so it's a disclosed change.)

## What the red-team fixed (the headline holes)

- **`recipient_kid` is now bound on insert** to the routed recipient's *current published* key — the routing label and the actual crypto target can no longer diverge (closed the key-substitution / victim-routing hole).
- **`DELETE` is escrow- and peer-protected** — an author can delete only *their own* recipient wrap to re-key themselves; a student can no longer strip the teacher's or escrow's access.
- **Mandatory escrow is enforced** by a `DEFERRABLE INITIALLY DEFERRED` constraint trigger (every item with wraps must carry a valid escrow wrap), reading sibling rows from a trigger — **not** a `dek_wraps` RLS policy — so it's non-recursive (avoids the prior `classes`-RLS-recursion class of bug).
- **`public_keys` SELECT was scoped** — the draft's `USING(true)` leaked the entire roster + revocation timelines to every account; now you see your own keys, your co-session peers' current keys, and the escrow custodian.
- **Helper functions can't be used as a uid oracle** — raw resolvers aren't granted to `authenticated`; only boolean gates are.
- Plus append-only envelopes, domain-separated signatures, per-item GC triggers, and `ON DELETE RESTRICT` so the escrow custodian row can't be cascade-destroyed.

## Residual limitations (honest)

1. An operator who can `DROP` triggers / alter schema still defeats in-DB tamper-evidence — only the **client pin + allowlist + an external mirror of the transparency log** catch them.
2. `publish_escrow_key` verifies nothing cryptographically in-DB (it can't); safety rests on the shipped client allowlist.
3. Content/DEK migration (turning `content_html`, grades, outlines, proctoring into DEK-encrypted blobs) is **out of scope** — substrate only.
4. A wrap issued to a key that is later revoked becomes undecryptable until a client re-wraps it (re-wrap/backfill is a client operation).

## Before this can be applied (pre-apply checklist)

This is **not** ready to apply like Phase 0 was — it depends on off-DB pieces:
1. **Set `escrow_custodian_uid()`** — it returns a placeholder literal (`00000000-…-0000000e5c70`) that must be replaced with a real provisioned custodian `auth.users` id.
2. **Provision the HSM/KMS** and generate the escrow keypair there; publish the public key via `publish_escrow_key` (service-role).
3. **Build the client side** — key bootstrap at OAuth login (identity + signing keypairs, Argon2id-passphrase-wrapped private key in `user_keys`), the TOFU pin store, signature verification, and the shipped escrow allowlist. Without this, the schema is inert.

## Open decisions for the founder

1. **HSM/KMS choice** for escrow custody + provision the custodian uid (CloudHSM was the red-team's lean, for single-tenant + M-of-N quorum).
2. **Approve the client-side pin + escrow allowlist** as the substitution boundary, and pick an **external transparency-log mirror** cadence/channel (e.g. a signed daily Git commit).
3. **Predecessor cross-signature on rotation** — hard client gate now, or later?
4. **Timing of the separate content/DEK blob migration.**
5. **(B)→(A) school-escrow widening** — acceptable when schools land?

See also: [`E2EE_FULL_ZK.md`](E2EE_FULL_ZK.md), [`E2EE_ENVELOPE_SPEC.md`](E2EE_ENVELOPE_SPEC.md), [`E2EE_RESEARCH.md`](E2EE_RESEARCH.md).
