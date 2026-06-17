import { test } from "node:test";
import assert from "node:assert/strict";
import {
  seal,
  openWithKey,
  openText,
  kidForRawPub,
  sealToJwk,
  openWithJwk,
  rawFromJwk,
  importPrivJwk,
} from "../src/envelope.mjs";
import { generateUserKeys } from "../src/keys.mjs";
import { subtle } from "../src/util.mjs";

async function ecdhKeyPair() {
  const kp = await subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const raw = new Uint8Array(await subtle.exportKey("raw", kp.publicKey));
  return { kp, raw };
}

test("envelope: single-recipient round-trip", async () => {
  const r = await ecdhKeyPair();
  const env = await seal({
    recipientRawPubs: [r.raw],
    plaintext: "the quick brown fox jumps over the lazy dog",
    submissionId: "sub-123",
    version: 1,
  });
  assert.equal(env.suite, "P256-HKDF-SHA256-AES256GCM");
  assert.equal(env.content.aad, "sub-123|v1");
  assert.equal(env.wraps.length, 1);
  const pt = await openText(env, r.kp.privateKey, r.raw);
  assert.equal(pt, "the quick brown fox jumps over the lazy dog");
});

test("envelope: multi-recipient (student, teacher, escrow) — each opens", async () => {
  const student = await ecdhKeyPair();
  const teacher = await ecdhKeyPair();
  const escrow = await ecdhKeyPair();
  const env = await seal({
    recipientRawPubs: [student.raw, teacher.raw, escrow.raw],
    plaintext: "essay body",
    submissionId: "essay-9",
    version: 2,
  });
  assert.equal(env.wraps.length, 3);
  // distinct kids, each matching a recipient
  const kids = env.wraps.map((w) => w.recipient_kid);
  assert.equal(new Set(kids).size, 3);
  for (const r of [student, teacher, escrow]) {
    assert.equal(await openText(env, r.kp.privateKey, r.raw), "essay body");
  }
});

test("envelope: kid is base64(SHA-256(raw pubkey)) and matches wrap label", async () => {
  const r = await ecdhKeyPair();
  const env = await seal({ recipientRawPubs: [r.raw], plaintext: "x", submissionId: "s", version: 1 });
  assert.equal(env.wraps[0].recipient_kid, await kidForRawPub(r.raw));
});

test("envelope: wrong recipient cannot open (GCM tag fails)", async () => {
  const a = await ecdhKeyPair();
  const b = await ecdhKeyPair();
  const env = await seal({ recipientRawPubs: [a.raw], plaintext: "secret", submissionId: "s", version: 1 });
  await assert.rejects(() => openWithKey(env, b.kp.privateKey, b.raw));
});

test("envelope: AAD tamper (submissionId/version) is rejected", async () => {
  const r = await ecdhKeyPair();
  const env = await seal({ recipientRawPubs: [r.raw], plaintext: "secret", submissionId: "sub", version: 1 });
  env.content.aad = "sub|v2"; // rollback/row-swap attempt
  await assert.rejects(() => openWithKey(env, r.kp.privateKey, r.raw));
});

test("envelope: ciphertext bit-flip is rejected", async () => {
  const r = await ecdhKeyPair();
  const env = await seal({ recipientRawPubs: [r.raw], plaintext: "secret", submissionId: "s", version: 1 });
  const ct = Buffer.from(env.content.ct, "base64");
  ct[0] ^= 0x01;
  env.content.ct = ct.toString("base64");
  await assert.rejects(() => openWithKey(env, r.kp.privateKey, r.raw));
});

test("envelope: JWK dev path round-trips (spike-compatible)", async () => {
  const kp = await subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const pubJwk = await subtle.exportKey("jwk", kp.publicKey);
  const privJwk = await subtle.exportKey("jwk", kp.privateKey);
  const env = await sealToJwk(pubJwk, "jwk plaintext", "sub-jwk", 1);
  const pt = await openWithJwk(privJwk, env);
  assert.equal(new TextDecoder().decode(pt), "jwk plaintext");
});

test("envelope: identity key from generateUserKeys is a valid recipient", async () => {
  const u = await generateUserKeys();
  const env = await seal({
    recipientRawPubs: [u.identity.pubRaw],
    plaintext: "to my identity key",
    submissionId: "id-1",
    version: 1,
  });
  assert.equal(env.wraps[0].recipient_kid, u.identity.kid);
  const pt = await openText(env, u.identity.keyPair.privateKey, u.identity.pubRaw);
  assert.equal(pt, "to my identity key");
});
