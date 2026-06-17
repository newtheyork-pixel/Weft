// weft-crypto-js — public surface.
// Suite: P256-HKDF-SHA256-AES256GCM. Zero-dep ESM, Web Crypto. Mirrors the Swift WeftCrypto core
// so blobs/keys round-trip cross-platform. See E2EE_ENVELOPE_SPEC.md and E2EE_KEY_SUBSTRATE.md.

export * as util from "./util.mjs";
export * as envelope from "./envelope.mjs";
export * as keys from "./keys.mjs";
export * as roster from "./roster.mjs";
export * as wrappedKey from "./wrappedKey.mjs";
export * as pinstore from "./pinstore.mjs";

// flat re-exports of the most-used entry points
export { seal, openWithKey, openText, SUITE, kidForRawPub } from "./envelope.mjs";
export { generateUserKeys, kidOf } from "./keys.mjs";
export { buildSignedRoster, signRosterRow, verifyRosterRow, canonicalPayload } from "./roster.mjs";
export { wrapPrivateKey, openPrivateKey } from "./wrappedKey.mjs";
export { InMemoryPinStore, tofuCheck, KeyChangedError } from "./pinstore.mjs";
