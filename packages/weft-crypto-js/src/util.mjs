// Weft crypto — shared low-level helpers. Zero-dep, Web Crypto + Node Buffer for base64.
// NOTE: these encodings must be byte-identical to the Swift core (CryptoKit) so blobs round-trip.

export const subtle = crypto.subtle;

const _enc = new TextEncoder();
const _dec = new TextDecoder();

/** UTF-8 string -> Uint8Array */
export const utf8 = (s) => _enc.encode(s);
/** Uint8Array -> UTF-8 string */
export const fromUtf8 = (u8) => _dec.decode(u8);

/** standard base64 (NOT base64url) — used for envelope fields, kids, wrapped-key JSON */
export const b64 = (u8) => Buffer.from(u8).toString("base64");
export const ub64 = (s) => new Uint8Array(Buffer.from(s, "base64"));

/** base64url (no padding in output) — used inside the wrapped-privkey bundle (identity_d/signing_d) */
export const b64url = (u8) => Buffer.from(u8).toString("base64url");
export const ub64url = (s) => new Uint8Array(Buffer.from(s, "base64url"));

/** concat any number of Uint8Arrays */
export function concat(...arrs) {
  let total = 0;
  for (const a of arrs) total += a.length;
  const out = new Uint8Array(total);
  let o = 0;
  for (const a of arrs) {
    out.set(a, o);
    o += a.length;
  }
  return out;
}

/** constant-time-ish byte compare (not timing-critical here, but avoids early-exit surprises) */
export function bytesEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/** SHA-256 of bytes -> Uint8Array(32) */
export async function sha256(u8) {
  return new Uint8Array(await subtle.digest("SHA-256", u8));
}

export const randomBytes = (n) => crypto.getRandomValues(new Uint8Array(n));
