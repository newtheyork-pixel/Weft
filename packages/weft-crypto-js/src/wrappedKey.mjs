// Weft WRAPPED PRIVATE KEY (user_keys.wrapped_privkey) — EXACT shared format.
//
// KEK = PBKDF2-HMAC-SHA256(passphrase_utf8, salt(16B), iterations=600000, dkLen=32)
// bundle = utf8(JSON {"identity_d": b64url(P256 identity privkey raw 32B),
//                     "signing_d":  b64url(P256 signing  privkey raw 32B)})
// blob   = AES-256-GCM(KEK, nonce(12B), bundle, AAD=utf8('weft-userkey/v1'))  -> ct = ct||tag
// stored = base64( JSON { "v":1, "kdf":"pbkdf2-sha256", "iters":600000,
//                         "salt":b64, "nonce":b64, "ct":b64(ct||tag) } )
//
// kdf_params jsonb mirrors {kdf, iters, salt}.
// PBKDF2 (not Argon2id) is the v1 choice for native cross-platform parity (CommonCrypto + Web Crypto
// both have it natively, zero deps). Argon2id is a documented future hardening.

import { subtle, utf8, fromUtf8, b64, ub64, b64url, ub64url, randomBytes } from "./util.mjs";

export const WRAPPED_KEY_AAD = utf8("weft-userkey/v1");
export const PBKDF2_ITERS = 600000;
export const PBKDF2_SALT_LEN = 16;
const NONCE_LEN = 12;

async function deriveKek(passphrase, salt, iters) {
  const baseKey = await subtle.importKey("raw", utf8(passphrase), "PBKDF2", false, ["deriveKey"]);
  return subtle.deriveKey(
    { name: "PBKDF2", hash: "SHA-256", salt, iterations: iters },
    baseKey,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

/**
 * Wrap a user's two private scalars under a passphrase.
 * @param {string} passphrase
 * @param {object} priv - { identityD: Uint8Array(32), signingD: Uint8Array(32) }
 * @returns {Promise<{blob: string, kdfParams: object}>}
 *   blob: the base64(JSON) string stored in user_keys.wrapped_privkey
 *   kdfParams: the object stored in user_keys.kdf_params jsonb
 */
export async function wrapPrivateKey(passphrase, priv) {
  if (priv.identityD.length !== 32 || priv.signingD.length !== 32) {
    throw new Error("wrapPrivateKey: identityD/signingD must be 32B raw scalars");
  }
  const salt = randomBytes(PBKDF2_SALT_LEN);
  const nonce = randomBytes(NONCE_LEN);
  const kek = await deriveKek(passphrase, salt, PBKDF2_ITERS);

  const bundle = utf8(
    JSON.stringify({
      identity_d: b64url(priv.identityD),
      signing_d: b64url(priv.signingD),
    }),
  );
  const ct = new Uint8Array(
    await subtle.encrypt(
      { name: "AES-GCM", iv: nonce, additionalData: WRAPPED_KEY_AAD, tagLength: 128 },
      kek,
      bundle,
    ),
  );

  const outer = {
    v: 1,
    kdf: "pbkdf2-sha256",
    iters: PBKDF2_ITERS,
    salt: b64(salt),
    nonce: b64(nonce),
    ct: b64(ct), // ct||tag
  };
  const blob = b64(utf8(JSON.stringify(outer)));

  const kdfParams = { kdf: "pbkdf2-sha256", iters: PBKDF2_ITERS, salt: b64(salt) };
  return { blob, kdfParams };
}

/**
 * Open a wrapped private key blob with a passphrase.
 * @param {string} passphrase
 * @param {string} blob - base64(JSON) string from user_keys.wrapped_privkey
 * @returns {Promise<{identityD: Uint8Array, signingD: Uint8Array}>}
 * @throws if the passphrase is wrong (AES-GCM tag verification fails)
 */
export async function openPrivateKey(passphrase, blob) {
  const outer = JSON.parse(fromUtf8(ub64(blob)));
  if (outer.v !== 1) throw new Error(`openPrivateKey: unsupported version ${outer.v}`);
  if (outer.kdf !== "pbkdf2-sha256") throw new Error(`openPrivateKey: unsupported kdf ${outer.kdf}`);

  const salt = ub64(outer.salt);
  const nonce = ub64(outer.nonce);
  const ct = ub64(outer.ct);
  const kek = await deriveKek(passphrase, salt, outer.iters ?? PBKDF2_ITERS);

  const bundleBytes = new Uint8Array(
    await subtle.decrypt(
      { name: "AES-GCM", iv: nonce, additionalData: WRAPPED_KEY_AAD, tagLength: 128 },
      kek,
      ct,
    ),
  );
  const bundle = JSON.parse(fromUtf8(bundleBytes));
  return {
    identityD: ub64url(bundle.identity_d),
    signingD: ub64url(bundle.signing_d),
  };
}
