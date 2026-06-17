// Weft key bootstrap — generate the two P-256 keypairs a user holds:
//   - identity:  ECDH (key agreement) — recipients wrap DEKs to this. Secure-Enclave-compatible curve.
//   - signing:   ECDSA (P-256/SHA-256) — signs the roster (self-signs the signing key; signs the identity key).
//
// All public keys travel as raw X9.63 (0x04||X||Y, 65B). kid = base64(SHA-256(raw pubkey)).
// Private scalars are exported as raw 32B (the `d` value) for the wrapped-privkey bundle.

import { subtle, b64, ub64url, concat, sha256 } from "./util.mjs";

/** raw X9.63 (65B) of any EC public CryptoKey */
export async function rawPub(pubKey) {
  return new Uint8Array(await subtle.exportKey("raw", pubKey));
}

/** kid = base64( SHA-256( raw X9.63 pubkey ) ) */
export async function kidOf(rawPubU8) {
  return b64(await sha256(rawPubU8));
}

/** raw 32B private scalar `d` of an EC private CryptoKey (via JWK export). */
export async function rawPrivD(privKey) {
  const jwk = await subtle.exportKey("jwk", privKey);
  return ub64url(jwk.d); // base64url-decoded 32B big-endian scalar
}

/** Reconstruct raw X9.63 (65B) from a P-256 private CryptoKey's JWK (0x04||X||Y). */
export async function rawPubFromPriv(privKey) {
  const jwk = await subtle.exportKey("jwk", privKey);
  return concat(new Uint8Array([4]), ub64url(jwk.x), ub64url(jwk.y));
}

// ---- import helpers from raw 32B scalar (used when opening a wrapped privkey) ----

/**
 * Import a P-256 private key from its raw 32B scalar `d`.
 * We need the matching public point; derive X,Y is not exposed by Web Crypto, so the caller
 * must supply the JWK x,y OR we re-import as a full JWK. For the wrapped-key path we only store `d`,
 * so we recover the public point by importing `d` as an ECDH JWK requires x,y... instead we use the
 * trick: import the scalar via PKCS8 is also unavailable. So: we import the key by reconstructing a
 * JWK with x,y computed from `d` using a scalar-mult — Web Crypto can't do that directly either.
 *
 * Practical approach (matches Swift, which stores only `d`): Web Crypto CAN import a JWK that has only
 * `d` for some impls, but the spec requires x,y. Node 22's webcrypto requires x,y. Therefore the
 * wrapped bundle stores ONLY `d` and we recover the public key by doing a raw P-256 base-point
 * multiply. Node exposes no scalar mult, so we instead recompute x,y via the `crypto` createPublicKey
 * path which DOES derive the public key from the private scalar.
 */
import { createPrivateKey, createPublicKey } from "node:crypto";

// DER prefix for a P-256 (prime256v1) PKCS#8 private key with a 32-byte scalar, no public key included.
// SEQUENCE { version 0, AlgId(ecPublicKey, prime256v1), OCTET STRING { SEQUENCE { 1, OCTET STRING d } } }
const P256_PKCS8_PREFIX = Uint8Array.from([
  0x30, 0x81, 0x87, 0x02, 0x01, 0x00, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
  0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x04, 0x6d, 0x30, 0x6b, 0x02,
  0x01, 0x01, 0x04, 0x20,
]);
// after the 32-byte scalar: [A1 44 03 42 00] then 65-byte point — but we DON'T have the point.
// Node can derive the public key from the private scalar, so we build a minimal PKCS8 WITHOUT the
// optional public key (the trailing [1] field), which Node accepts and completes.
const P256_PKCS8_MINIMAL_PREFIX = Uint8Array.from([
  0x30, 0x41, 0x02, 0x01, 0x00, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
  0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x04, 0x27, 0x30, 0x25, 0x02, 0x01,
  0x01, 0x04, 0x20,
]);

/** Build a JWK {x,y,d} for a P-256 private scalar by letting Node derive the public point. */
export function jwkFromScalar(dU8) {
  if (dU8.length !== 32) throw new Error(`jwkFromScalar: expected 32B scalar, got ${dU8.length}`);
  const pkcs8 = concat(P256_PKCS8_MINIMAL_PREFIX, dU8);
  const keyObj = createPrivateKey({ key: Buffer.from(pkcs8), format: "der", type: "pkcs8" });
  const jwk = keyObj.export({ format: "jwk" });
  return { kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y, d: jwk.d };
}

/** Import an ECDH (identity) private CryptoKey from a raw 32B scalar. */
export async function importIdentityPrivFromScalar(dU8, usages = ["deriveBits"]) {
  const jwk = jwkFromScalar(dU8);
  return subtle.importKey("jwk", { ...jwk, key_ops: undefined }, { name: "ECDH", namedCurve: "P-256" }, true, usages);
}

/** Import an ECDSA (signing) private CryptoKey from a raw 32B scalar. */
export async function importSigningPrivFromScalar(dU8, usages = ["sign"]) {
  const jwk = jwkFromScalar(dU8);
  return subtle.importKey("jwk", { ...jwk }, { name: "ECDSA", namedCurve: "P-256" }, true, usages);
}

/** Public ECDSA verify key from raw X9.63 pubkey. */
export async function importSigningPub(rawPubU8) {
  return subtle.importKey("raw", rawPubU8, { name: "ECDSA", namedCurve: "P-256" }, true, ["verify"]);
}

/** Public ECDH key from raw X9.63 pubkey. */
export async function importIdentityPub(rawPubU8) {
  return subtle.importKey("raw", rawPubU8, { name: "ECDH", namedCurve: "P-256" }, true, []);
}

/**
 * Bootstrap a fresh user: generate identity (ECDH) + signing (ECDSA) P-256 keypairs.
 * Returns an object with CryptoKeys, raw pubkeys, raw private scalars, and kids.
 */
export async function generateUserKeys() {
  const identity = await subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const signing = await subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);

  const identityPubRaw = await rawPub(identity.publicKey);
  const signingPubRaw = await rawPub(signing.publicKey);

  return {
    identity: {
      keyPair: identity,
      pubRaw: identityPubRaw,
      privD: await rawPrivD(identity.privateKey),
      kid: await kidOf(identityPubRaw),
    },
    signing: {
      keyPair: signing,
      pubRaw: signingPubRaw,
      privD: await rawPrivD(signing.privateKey),
      kid: await kidOf(signingPubRaw),
    },
  };
}
