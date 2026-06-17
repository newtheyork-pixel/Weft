// Weft E2EE envelope — Web Crypto reference impl, multi-recipient.
// Suite: P256-HKDF-SHA256-AES256GCM. Per-item random AES-256-GCM DEK encrypts content;
// DEK is wrapped per recipient via ephemeral ECDH-P256 -> HKDF-SHA256 -> AES-256-GCM (ECIES-style).
//
// Constants and byte-layout are FROZEN to match envelope.swift / the spike envelope.mjs and the
// E2EE_ENVELOPE_SPEC.md. Do not change any label/salt/info/AAD/x963 ordering — interop-verified.

import { subtle, utf8, b64, ub64, ub64url, concat, sha256 } from "./util.mjs";

// ---- Protocol constants (MUST match envelope.swift byte-for-byte) ----
export const SUITE = "P256-HKDF-SHA256-AES256GCM";
const SALT = utf8("weft-e2ee-v1"); // HKDF salt
const WRAP_LABEL = utf8("weft-dek-wrap/v1"); // HKDF info prefix
const WRAP_AAD = utf8("weft-wrap/v1"); // AAD for the DEK-wrap AES-GCM

// ---- public-key wire helpers ----

/** Import a raw X9.63 (0x04||X||Y, 65B) public key as an ECDH P-256 key. */
export async function importRawPub(rawU8) {
  return subtle.importKey("raw", rawU8, { name: "ECDH", namedCurve: "P-256" }, true, []);
}

/** Import a JWK (dev/test interchange) as an ECDH P-256 public key. */
export async function importPubJwk(jwk) {
  const j = { ...jwk };
  delete j.key_ops;
  delete j.ext;
  return subtle.importKey("jwk", j, { name: "ECDH", namedCurve: "P-256" }, true, []);
}

/** Import a JWK private key as an ECDH P-256 key (deriveBits). */
export async function importPrivJwk(jwk) {
  const j = { ...jwk };
  delete j.key_ops;
  delete j.ext;
  return subtle.importKey("jwk", j, { name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
}

/** raw X9.63 (65B) of an ECDH public key */
export async function rawOf(pubKey) {
  return new Uint8Array(await subtle.exportKey("raw", pubKey));
}

/** raw X9.63 (65B) reconstructed from a JWK (0x04 || X || Y) */
export function rawFromJwk(jwk) {
  return concat(new Uint8Array([4]), ub64url(jwk.x), ub64url(jwk.y));
}

/** recipient_kid = base64( SHA-256( raw X9.63 pubkey ) ) */
export async function kidForRawPub(rawU8) {
  return b64(await sha256(rawU8));
}

// ---- core ECIES KEK derivation (HPKE-style: eph+recip bound into HKDF info) ----

async function deriveKek(privKey, peerPubKey, ephPubRaw, recipPubRaw) {
  const shared = await subtle.deriveBits({ name: "ECDH", public: peerPubKey }, privKey, 256); // 32B X coord
  const info = concat(WRAP_LABEL, ephPubRaw, recipPubRaw);
  const hk = await subtle.importKey("raw", shared, "HKDF", false, ["deriveBits"]);
  const kekBits = await subtle.deriveBits(
    { name: "HKDF", hash: "SHA-256", salt: SALT, info },
    hk,
    256,
  );
  return subtle.importKey("raw", kekBits, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

/**
 * Wrap an already-generated DEK (Uint8Array(32)) to a single recipient raw pubkey.
 * Returns one `wraps[]` entry { recipient_kid, eph_pub, nonce, wrapped_dek }.
 */
export async function wrapDekToRaw(dek, recipPubRaw) {
  const recipPub = await importRawPub(recipPubRaw);
  const eph = await subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const ephPubRaw = await rawOf(eph.publicKey);
  const kek = await deriveKek(eph.privateKey, recipPub, ephPubRaw, recipPubRaw);
  const wrapNonce = crypto.getRandomValues(new Uint8Array(12));
  const wrappedDek = new Uint8Array(
    await subtle.encrypt(
      { name: "AES-GCM", iv: wrapNonce, additionalData: WRAP_AAD, tagLength: 128 },
      kek,
      dek,
    ),
  );
  return {
    recipient_kid: await kidForRawPub(recipPubRaw),
    eph_pub: b64(ephPubRaw),
    nonce: b64(wrapNonce),
    wrapped_dek: b64(wrappedDek),
  };
}

/**
 * Seal plaintext to one or more recipients.
 * @param {object} args
 * @param {Uint8Array[]} args.recipientRawPubs - raw X9.63 (65B) pubkeys, e.g. [student, teacher, escrow]
 * @param {string|Uint8Array} args.plaintext
 * @param {string} args.submissionId  - bound into content AAD
 * @param {number|string} args.version - bound into content AAD ("v<version>")
 * @returns {Promise<object>} envelope { v, suite, content:{aad,nonce,ct}, wraps:[...] }
 */
export async function seal({ recipientRawPubs, plaintext, submissionId, version }) {
  if (!Array.isArray(recipientRawPubs) || recipientRawPubs.length === 0) {
    throw new Error("seal: at least one recipient pubkey required");
  }
  const pt = typeof plaintext === "string" ? utf8(plaintext) : plaintext;

  // 1) content: random DEK, AES-256-GCM with AAD = "<submissionId>|v<version>"
  const dek = crypto.getRandomValues(new Uint8Array(32));
  const dekKey = await subtle.importKey("raw", dek, { name: "AES-GCM" }, false, ["encrypt"]);
  const contentNonce = crypto.getRandomValues(new Uint8Array(12));
  const aadStr = `${submissionId}|v${version}`;
  const contentCt = new Uint8Array(
    await subtle.encrypt(
      { name: "AES-GCM", iv: contentNonce, additionalData: utf8(aadStr), tagLength: 128 },
      dekKey,
      pt,
    ),
  );

  // 2) wrap DEK to each recipient (fresh ephemeral key per wrap)
  const wraps = [];
  for (const recipPubRaw of recipientRawPubs) {
    wraps.push(await wrapDekToRaw(dek, recipPubRaw));
  }

  return {
    v: 1,
    suite: SUITE,
    content: { aad: aadStr, nonce: b64(contentNonce), ct: b64(contentCt) },
    wraps,
  };
}

/**
 * Open an envelope with a recipient ECDH private key (CryptoKey) and its raw pubkey.
 * Selects the matching wrap by kid (falls back to first wrap, mirroring the spike).
 * @returns {Promise<Uint8Array>} plaintext bytes
 */
export async function openWithKey(env, recipPrivKey, recipPubRaw) {
  const kid = await kidForRawPub(recipPubRaw);
  const w = env.wraps.find((x) => x.recipient_kid === kid) ?? env.wraps[0];
  if (!w) throw new Error("open: no wrap for this recipient");

  const ephPubRaw = ub64(w.eph_pub);
  const ephPub = await importRawPub(ephPubRaw);
  const kek = await deriveKek(recipPrivKey, ephPub, ephPubRaw, recipPubRaw);
  const dek = new Uint8Array(
    await subtle.decrypt(
      { name: "AES-GCM", iv: ub64(w.nonce), additionalData: WRAP_AAD, tagLength: 128 },
      kek,
      ub64(w.wrapped_dek),
    ),
  );

  const dekKey = await subtle.importKey("raw", dek, { name: "AES-GCM" }, false, ["decrypt"]);
  const pt = await subtle.decrypt(
    { name: "AES-GCM", iv: ub64(env.content.nonce), additionalData: utf8(env.content.aad), tagLength: 128 },
    dekKey,
    ub64(env.content.ct),
  );
  return new Uint8Array(pt);
}

/** Convenience: open and decode as UTF-8 string. */
export async function openText(env, recipPrivKey, recipPubRaw) {
  const { fromUtf8 } = await import("./util.mjs");
  return fromUtf8(await openWithKey(env, recipPrivKey, recipPubRaw));
}

// ---- JWK-based dev helpers (mirror the spike CLI for cross-language interop tests) ----

/** Seal to a single recipient JWK pubkey (dev interchange path). */
export async function sealToJwk(pubJwk, plaintext, submissionId, version) {
  const recipPub = await importPubJwk(pubJwk);
  const recipPubRaw = await rawOf(recipPub);
  return seal({ recipientRawPubs: [recipPubRaw], plaintext, submissionId, version });
}

/** Open an envelope with a recipient private JWK (dev interchange path). */
export async function openWithJwk(privJwk, env) {
  const recipPriv = await importPrivJwk(privJwk);
  const recipPubRaw = rawFromJwk(privJwk);
  return openWithKey(env, recipPriv, recipPubRaw);
}
