// Weft signed-roster signatures (public_keys.signature).
// ECDSA P-256 over SHA-256 of a canonical, domain-separated payload. Fields joined by single 0x00
// bytes, UTF-8. signing keys are self-signed (signer_kid=kid); identity keys are signed by the
// user's signing key. The signature is tamper-evidence in-DB; the REAL trust check is the client
// TOFU pin (see pinstore.mjs) — this just lets a pinned verifier confirm a roster row.
//
// Canonical payload (must match the SQL comment + Swift core byte-for-byte):
//   sig_domain 0x00 owner_user_id 0x00 key_kind 0x00 pubkey_b64 0x00 kid 0x00 key_epoch 0x00
//   coalesce(predecessor_kid,'')

import { subtle, utf8, b64, concat } from "./util.mjs";
import { importSigningPub } from "./keys.mjs";

export const SIG_DOMAIN_DEFAULT = "weft-pubkey-v1";

/**
 * Build the canonical signing payload bytes for a roster row.
 * @param {object} row
 * @param {string} row.sigDomain        - default 'weft-pubkey-v1'
 * @param {string} row.ownerUserId      - uuid string
 * @param {string} row.keyKind          - 'identity' | 'signing' | 'escrow'
 * @param {string} row.pubkeyB64        - base64 of raw X9.63 pubkey (the value stored in public_keys.pubkey)
 * @param {string} row.kid              - base64 SHA-256 of raw pubkey
 * @param {number|string} row.keyEpoch  - integer epoch
 * @param {?string} row.predecessorKid  - or null/undefined -> '' in payload
 * @returns {Uint8Array}
 */
export function canonicalPayload(row) {
  const SEP = new Uint8Array([0x00]);
  const f = (s) => utf8(String(s));
  const pred = row.predecessorKid == null ? "" : row.predecessorKid;
  return concat(
    f(row.sigDomain ?? SIG_DOMAIN_DEFAULT), SEP,
    f(row.ownerUserId), SEP,
    f(row.keyKind), SEP,
    f(row.pubkeyB64), SEP,
    f(row.kid), SEP,
    f(row.keyEpoch), SEP,
    f(pred),
  );
}

/**
 * Sign a roster row. ECDSA P-256 / SHA-256. Returns base64 signature (raw r||s, 64B — Web Crypto's
 * native ECDSA output; matches CryptoKit's rawRepresentation).
 * @param {CryptoKey} signingPriv  - ECDSA private key (the user's signing key)
 * @param {object} row             - see canonicalPayload
 */
export async function signRosterRow(signingPriv, row) {
  const payload = canonicalPayload(row);
  const sig = new Uint8Array(
    await subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signingPriv, payload),
  );
  return b64(sig);
}

/**
 * Verify a roster row signature against a signer's raw X9.63 pubkey.
 * @param {Uint8Array} signerPubRaw - raw X9.63 of the signing key
 * @param {object} row              - see canonicalPayload (must include .signature b64)
 * @returns {Promise<boolean>}
 */
export async function verifyRosterRow(signerPubRaw, row) {
  const payload = canonicalPayload(row);
  const verifyKey = await importSigningPub(signerPubRaw);
  const sig = Uint8Array.from(Buffer.from(row.signature, "base64"));
  return subtle.verify({ name: "ECDSA", hash: "SHA-256" }, verifyKey, sig, payload);
}

/**
 * Convenience: produce the full set of public_keys rows for a freshly bootstrapped user.
 * - signing key row: self-signed (signer_kid = signing.kid)
 * - identity key row: signed by the signing key (signer_kid = signing.kid)
 *
 * @param {object} userKeys - result of keys.generateUserKeys()
 * @param {string} ownerUserId
 * @param {object} [opts] - { keyEpoch=1, sigDomain }
 * @returns {Promise<{signing: object, identity: object}>} rows ready for INSERT into public_keys
 */
export async function buildSignedRoster(userKeys, ownerUserId, opts = {}) {
  const keyEpoch = opts.keyEpoch ?? 1;
  const sigDomain = opts.sigDomain ?? SIG_DOMAIN_DEFAULT;

  const signingPubB64 = b64(userKeys.signing.pubRaw);
  const identityPubB64 = b64(userKeys.identity.pubRaw);

  const signingRowBase = {
    sigDomain,
    ownerUserId,
    keyKind: "signing",
    pubkeyB64: signingPubB64,
    kid: userKeys.signing.kid,
    keyEpoch,
    predecessorKid: null,
  };
  const signingSig = await signRosterRow(userKeys.signing.keyPair.privateKey, signingRowBase);

  const identityRowBase = {
    sigDomain,
    ownerUserId,
    keyKind: "identity",
    pubkeyB64: identityPubB64,
    kid: userKeys.identity.kid,
    keyEpoch,
    predecessorKid: null,
  };
  const identitySig = await signRosterRow(userKeys.signing.keyPair.privateKey, identityRowBase);

  return {
    signing: {
      owner_user_id: ownerUserId,
      key_kind: "signing",
      pubkey: signingPubB64,
      kid: userKeys.signing.kid,
      key_epoch: keyEpoch,
      predecessor_kid: null,
      sig_domain: sigDomain,
      signer_kid: userKeys.signing.kid, // self-signed
      signature: signingSig,
    },
    identity: {
      owner_user_id: ownerUserId,
      key_kind: "identity",
      pubkey: identityPubB64,
      kid: userKeys.identity.kid,
      key_epoch: keyEpoch,
      predecessor_kid: null,
      sig_domain: sigDomain,
      signer_kid: userKeys.signing.kid, // signed by the user's signing key
      signature: identitySig,
    },
  };
}
