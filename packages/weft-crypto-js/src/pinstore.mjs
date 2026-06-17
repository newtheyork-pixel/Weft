// Weft TOFU pin store — the ONLY real key-substitution detector (per E2EE_KEY_SUBSTRATE.md).
//
// Trust-on-first-use: the first signing-key kid we see for an owner is pinned. Every later roster
// row for that owner MUST present the pinned signing kid, or we hard-fail with a "key changed" alert
// (Signal-style safety number). service_role bypasses RLS server-side, so in-DB signatures are only
// tamper-evidence; this client-side pin is what actually catches a forged roster.
//
// This module defines the interface + an in-memory implementation (for tests / ephemeral use).
// A persistent IndexedDB (web) / OS-keychain (native bridge) implementation is a documented TODO.

/**
 * @typedef {Object} PinStore
 * @property {(ownerUserId: string) => Promise<?string>} getPinnedSigningKid
 * @property {(ownerUserId: string, signingKid: string) => Promise<void>} pin
 * @property {(ownerUserId: string) => Promise<void>} unpin   // for explicit, user-confirmed rotation
 */

export class KeyChangedError extends Error {
  constructor(ownerUserId, pinnedKid, seenKid) {
    super(
      `TOFU pin mismatch for owner ${ownerUserId}: pinned signing kid ${pinnedKid} but roster presented ${seenKid}. ` +
        `Refusing to trust — possible key substitution.`,
    );
    this.name = "KeyChangedError";
    this.ownerUserId = ownerUserId;
    this.pinnedKid = pinnedKid;
    this.seenKid = seenKid;
  }
}

/** In-memory PinStore. Pins are lost on process exit — fine for tests, NOT for production trust. */
export class InMemoryPinStore {
  constructor() {
    /** @type {Map<string, string>} ownerUserId -> pinned signing kid */
    this._pins = new Map();
  }
  async getPinnedSigningKid(ownerUserId) {
    return this._pins.has(ownerUserId) ? this._pins.get(ownerUserId) : null;
  }
  async pin(ownerUserId, signingKid) {
    this._pins.set(ownerUserId, signingKid);
  }
  async unpin(ownerUserId) {
    this._pins.delete(ownerUserId);
  }
}

/**
 * TOFU gate: given an owner and the signing kid presented by the current roster, either pin it
 * (first use) or assert it matches the pin (subsequent uses). Throws KeyChangedError on mismatch.
 * @param {PinStore} store
 * @param {string} ownerUserId
 * @param {string} presentedSigningKid - the signer_kid of the owner's *signing* row (self-signed)
 * @returns {Promise<{firstUse: boolean}>}
 */
export async function tofuCheck(store, ownerUserId, presentedSigningKid) {
  const pinned = await store.getPinnedSigningKid(ownerUserId);
  if (pinned == null) {
    await store.pin(ownerUserId, presentedSigningKid);
    return { firstUse: true };
  }
  if (pinned !== presentedSigningKid) {
    throw new KeyChangedError(ownerUserId, pinned, presentedSigningKid);
  }
  return { firstUse: false };
}

// TODO(indexeddb): persistent web PinStore backed by IndexedDB (object store keyed by ownerUserId).
//   class IndexedDbPinStore { ... open db 'weft-tofu', store 'pins' ... } — same interface as above.
// TODO(native): an OS-keychain-backed PinStore bridged from the native app shares the same interface.
