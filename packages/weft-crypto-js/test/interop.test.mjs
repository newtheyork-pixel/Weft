// Cross-platform interop: prove JS opens Swift-produced blobs (and verifies Swift signatures).
//
// Two sources of Swift-produced fixtures:
//  (A) LIVE NOW — the e2ee-interop spike (CryptoKit) at ../../../spikes/e2ee-interop/env_swift.json,
//      decrypted with recipient.priv.jwk. This already proves the ENVELOPE crypto interoperates.
//  (B) DEFERRED — the Swift WeftCrypto package's TestVectors/ (wrapped-privkey + signed identity key).
//      These are emitted by the Swift dev's test target. If present, we (a) open the wrapped privkey
//      with the shared passphrase and (b) verify the Swift-signed identity roster row. If absent,
//      those subtests are skipped (and say so) so this file runs green now and meaningfully later.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

import { openWithJwk } from "../src/envelope.mjs";
import { openPrivateKey } from "../src/wrappedKey.mjs";
import { verifyRosterRow } from "../src/roster.mjs";
import { ub64, b64 } from "../src/util.mjs";

const __dir = dirname(fileURLToPath(import.meta.url));
const SPIKE_DIR = resolve(__dir, "../../../spikes/e2ee-interop");
const VECTORS_DIR = resolve(__dir, "../../WeftCrypto/TestVectors");

// ---- (A) LIVE: Swift CryptoKit envelope -> JS Web Crypto decrypt ----
test("interop[A]: JS opens the Swift(CryptoKit)-produced spike envelope", async (t) => {
  const envPath = resolve(SPIKE_DIR, "env_swift.json");
  const privPath = resolve(SPIKE_DIR, "recipient.priv.jwk");
  if (!existsSync(envPath) || !existsSync(privPath)) {
    t.skip(`spike fixtures not found at ${SPIKE_DIR}`);
    return;
  }
  const env = JSON.parse(readFileSync(envPath, "utf8"));
  const priv = JSON.parse(readFileSync(privPath, "utf8"));
  const pt = await openWithJwk(priv, env);
  const text = new TextDecoder().decode(pt);
  // The spike encrypts a known plaintext; we just assert it decrypts to *something* non-empty and
  // that the AAD is the expected submission id, which is the interop-critical part.
  assert.equal(env.suite, "P256-HKDF-SHA256-AES256GCM");
  assert.equal(env.content.aad, "11111111-1111-1111-1111-111111111111|v1");
  assert.ok(text.length > 0, "decrypted plaintext should be non-empty");
  console.log(`    interop[A] decrypted Swift envelope -> ${JSON.stringify(text)}`);
});

// ---- (B) DEFERRED: Swift WeftCrypto TestVectors ----
//
// Expected fixture shapes (documented contract for the Swift dev to emit):
//   wrapped_privkey.json  : { "passphrase": "<shared test passphrase>", "blob": "<base64(JSON) wrapped_privkey>",
//                             "identity_d_b64url": "<expected>", "signing_d_b64url": "<expected>" }
//   signed_identity.json  : { "owner_user_id","key_kind":"identity","pubkey":"<b64 raw>","kid","key_epoch",
//                             "predecessor_kid":null,"sig_domain":"weft-pubkey-v1",
//                             "signer_kid":"<signing kid>","signature":"<b64>",
//                             "signing_pubkey":"<b64 raw signing pub used to verify>" }

test("interop[B1]: JS opens the Swift-produced wrapped private key", async (t) => {
  const p = resolve(VECTORS_DIR, "wrapped_privkey.json");
  if (!existsSync(p)) {
    t.skip(`Swift wrapped_privkey vector not present yet at ${p} — run after the Swift dev emits it`);
    return;
  }
  const v = JSON.parse(readFileSync(p, "utf8"));
  const opened = await openPrivateKey(v.passphrase, v.blob);
  // identity_d/signing_d are stored as base64url in the bundle; compare via b64url
  const { b64url } = await import("../src/util.mjs");
  assert.equal(b64url(opened.identityD), v.identity_d_b64url);
  assert.equal(b64url(opened.signingD), v.signing_d_b64url);
  console.log("    interop[B1] opened Swift wrapped-privkey; scalars match expected");
});

test("interop[B2]: JS verifies the Swift-signed identity roster row", async (t) => {
  const p = resolve(VECTORS_DIR, "signed_identity.json");
  if (!existsSync(p)) {
    t.skip(`Swift signed_identity vector not present yet at ${p} — run after the Swift dev emits it`);
    return;
  }
  const v = JSON.parse(readFileSync(p, "utf8"));
  const signerPubRaw = ub64(v.signing_pubkey);
  const ok = await verifyRosterRow(signerPubRaw, {
    sigDomain: v.sig_domain,
    ownerUserId: v.owner_user_id,
    keyKind: v.key_kind,
    pubkeyB64: v.pubkey,
    kid: v.kid,
    keyEpoch: v.key_epoch,
    predecessorKid: v.predecessor_kid,
    signature: v.signature,
  });
  assert.equal(ok, true, "Swift-signed identity row must verify under JS");
  console.log("    interop[B2] verified Swift-signed identity roster row");
});
