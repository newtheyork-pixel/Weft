// Weft E2EE envelope — Web Crypto (SubtleCrypto) reference implementation.
// Node's webcrypto is the SAME API the browser portal uses, so this stands in for the web client.
// Suite: P256-HKDF-SHA256-AES256GCM. Envelope: per-item AES-256-GCM DEK, DEK wrapped per recipient
// via ephemeral ECDH-P256 -> HKDF-SHA256 -> AES-256-GCM (ECIES-style).
//
// CLI:
//   node envelope.mjs genkeys <dir>
//   node envelope.mjs encrypt <pub.jwk> <plaintext> <submissionId> <version>   -> envelope JSON on stdout
//   node envelope.mjs decrypt <priv.jwk> <envelope.json>                       -> plaintext on stdout

import { readFileSync, writeFileSync } from 'node:fs';

const subtle = crypto.subtle;
const enc = (s) => new TextEncoder().encode(s);
const b64 = (u8) => Buffer.from(u8).toString('base64');
const ub64 = (s) => new Uint8Array(Buffer.from(s, 'base64'));
const ub64url = (s) => new Uint8Array(Buffer.from(s, 'base64url'));
function concat(...arrs) {
  const total = arrs.reduce((n, a) => n + a.length, 0);
  const out = new Uint8Array(total);
  let o = 0;
  for (const a of arrs) { out.set(a, o); o += a.length; }
  return out;
}

// ---- Protocol constants (MUST match envelope.swift byte-for-byte) ----
const SUITE = 'P256-HKDF-SHA256-AES256GCM';
const SALT = enc('weft-e2ee-v1');        // HKDF salt
const WRAP_LABEL = enc('weft-dek-wrap/v1'); // HKDF info prefix
const WRAP_AAD = enc('weft-wrap/v1');     // AAD for the DEK-wrap AES-GCM

async function importPub(jwk) {
  const j = { ...jwk }; delete j.key_ops; delete j.ext;
  return subtle.importKey('jwk', j, { name: 'ECDH', namedCurve: 'P-256' }, true, []);
}
async function importPriv(jwk) {
  const j = { ...jwk }; delete j.key_ops; delete j.ext;
  return subtle.importKey('jwk', j, { name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
}
async function rawOf(pubKey) { return new Uint8Array(await subtle.exportKey('raw', pubKey)); } // 0x04||X||Y (65)

async function deriveKek(privKey, peerPubKey, ephPubRaw, recipPubRaw) {
  const shared = await subtle.deriveBits({ name: 'ECDH', public: peerPubKey }, privKey, 256); // 32-byte X coord
  const info = concat(WRAP_LABEL, ephPubRaw, recipPubRaw);
  const hk = await subtle.importKey('raw', shared, 'HKDF', false, ['deriveBits']);
  const kekBits = await subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt: SALT, info }, hk, 256);
  return subtle.importKey('raw', kekBits, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
}

async function encrypt(pubJwk, plaintext, submissionId, version) {
  const recipPub = await importPub(pubJwk);
  const recipPubRaw = await rawOf(recipPub);

  // 1) content: random DEK, AES-256-GCM with AAD = submissionId|v<version>
  const dek = crypto.getRandomValues(new Uint8Array(32));
  const dekKey = await subtle.importKey('raw', dek, { name: 'AES-GCM' }, false, ['encrypt']);
  const contentNonce = crypto.getRandomValues(new Uint8Array(12));
  const aadStr = `${submissionId}|v${version}`;
  const contentCt = new Uint8Array(await subtle.encrypt(
    { name: 'AES-GCM', iv: contentNonce, additionalData: enc(aadStr), tagLength: 128 }, dekKey, enc(plaintext)));

  // 2) wrap DEK to recipient via ephemeral ECDH
  const eph = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const ephPubRaw = await rawOf(eph.publicKey);
  const kek = await deriveKek(eph.privateKey, recipPub, ephPubRaw, recipPubRaw);
  const wrapNonce = crypto.getRandomValues(new Uint8Array(12));
  const wrappedDek = new Uint8Array(await subtle.encrypt(
    { name: 'AES-GCM', iv: wrapNonce, additionalData: WRAP_AAD, tagLength: 128 }, kek, dek));

  const kid = new Uint8Array(await subtle.digest('SHA-256', recipPubRaw));
  return {
    v: 1, suite: SUITE,
    content: { aad: aadStr, nonce: b64(contentNonce), ct: b64(contentCt) },
    wraps: [{ recipient_kid: b64(kid), eph_pub: b64(ephPubRaw), nonce: b64(wrapNonce), wrapped_dek: b64(wrappedDek) }],
  };
}

async function decrypt(privJwk, env) {
  const recipPriv = await importPriv(privJwk);
  const recipPubRaw = concat(new Uint8Array([4]), ub64url(privJwk.x), ub64url(privJwk.y)); // 0x04||X||Y

  const kid = b64(new Uint8Array(await subtle.digest('SHA-256', recipPubRaw)));
  const w = env.wraps.find((x) => x.recipient_kid === kid) ?? env.wraps[0];

  const ephPubRaw = ub64(w.eph_pub);
  const ephPub = await subtle.importKey('raw', ephPubRaw, { name: 'ECDH', namedCurve: 'P-256' }, true, []);
  const kek = await deriveKek(recipPriv, ephPub, ephPubRaw, recipPubRaw);
  const dek = new Uint8Array(await subtle.decrypt(
    { name: 'AES-GCM', iv: ub64(w.nonce), additionalData: WRAP_AAD, tagLength: 128 }, kek, ub64(w.wrapped_dek)));

  const dekKey = await subtle.importKey('raw', dek, { name: 'AES-GCM' }, false, ['decrypt']);
  const pt = await subtle.decrypt(
    { name: 'AES-GCM', iv: ub64(env.content.nonce), additionalData: enc(env.content.aad), tagLength: 128 },
    dekKey, ub64(env.content.ct));
  return new TextDecoder().decode(pt);
}

// ---- CLI ----
const [cmd, a1, a2, a3, a4] = process.argv.slice(2);
if (cmd === 'genkeys') {
  const kp = await subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits']);
  const priv = await subtle.exportKey('jwk', kp.privateKey);
  const pub = await subtle.exportKey('jwk', kp.publicKey);
  for (const j of [priv, pub]) { delete j.key_ops; delete j.ext; }
  writeFileSync(`${a1}/recipient.priv.jwk`, JSON.stringify(priv, null, 2));
  writeFileSync(`${a1}/recipient.pub.jwk`, JSON.stringify(pub, null, 2));
  console.error('wrote recipient.priv.jwk + recipient.pub.jwk');
} else if (cmd === 'encrypt') {
  const pub = JSON.parse(readFileSync(a1, 'utf8'));
  process.stdout.write(JSON.stringify(await encrypt(pub, a2, a3, a4)));
} else if (cmd === 'decrypt') {
  const priv = JSON.parse(readFileSync(a1, 'utf8'));
  const env = JSON.parse(readFileSync(a2, 'utf8'));
  process.stdout.write(await decrypt(priv, env));
} else {
  console.error('usage: genkeys <dir> | encrypt <pub.jwk> <pt> <sid> <ver> | decrypt <priv.jwk> <env.json>');
  process.exit(2);
}
