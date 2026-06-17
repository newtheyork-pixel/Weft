import { test } from "node:test";
import assert from "node:assert/strict";
import { generateUserKeys, importSigningPrivFromScalar } from "../src/keys.mjs";
import {
  canonicalPayload,
  signRosterRow,
  verifyRosterRow,
  buildSignedRoster,
  SIG_DOMAIN_DEFAULT,
} from "../src/roster.mjs";
import { b64 } from "../src/util.mjs";

test("roster: canonical payload uses single 0x00 separators in the documented field order", () => {
  const p = canonicalPayload({
    sigDomain: "weft-pubkey-v1",
    ownerUserId: "owner-1",
    keyKind: "identity",
    pubkeyB64: "PUB",
    kid: "KID",
    keyEpoch: 1,
    predecessorKid: null,
  });
  // expected: weft-pubkey-v1 \0 owner-1 \0 identity \0 PUB \0 KID \0 1 \0 (empty)
  const expected = "weft-pubkey-v1\x00owner-1\x00identity\x00PUB\x00KID\x001\x00";
  assert.equal(Buffer.from(p).toString("latin1"), expected);
});

test("roster: predecessorKid null and '' produce the same payload", () => {
  const base = { sigDomain: "d", ownerUserId: "o", keyKind: "identity", pubkeyB64: "p", kid: "k", keyEpoch: 1 };
  const a = canonicalPayload({ ...base, predecessorKid: null });
  const b = canonicalPayload({ ...base, predecessorKid: "" });
  assert.equal(Buffer.from(a).toString("base64"), Buffer.from(b).toString("base64"));
});

test("roster: sign then verify a single row", async () => {
  const u = await generateUserKeys();
  const row = {
    sigDomain: SIG_DOMAIN_DEFAULT,
    ownerUserId: "owner-xyz",
    keyKind: "signing",
    pubkeyB64: b64(u.signing.pubRaw),
    kid: u.signing.kid,
    keyEpoch: 1,
    predecessorKid: null,
  };
  const signature = await signRosterRow(u.signing.keyPair.privateKey, row);
  const ok = await verifyRosterRow(u.signing.pubRaw, { ...row, signature });
  assert.equal(ok, true);
});

test("roster: buildSignedRoster — signing self-signed, identity signed by signing key", async () => {
  const u = await generateUserKeys();
  const owner = "owner-abc";
  const rows = await buildSignedRoster(u, owner);

  // signing row is self-signed
  assert.equal(rows.signing.signer_kid, rows.signing.kid);
  assert.equal(rows.signing.key_kind, "signing");
  const signingOk = await verifyRosterRow(u.signing.pubRaw, {
    sigDomain: rows.signing.sig_domain,
    ownerUserId: rows.signing.owner_user_id,
    keyKind: rows.signing.key_kind,
    pubkeyB64: rows.signing.pubkey,
    kid: rows.signing.kid,
    keyEpoch: rows.signing.key_epoch,
    predecessorKid: rows.signing.predecessor_kid,
    signature: rows.signing.signature,
  });
  assert.equal(signingOk, true);

  // identity row is signed by the signing key (signer_kid = signing.kid)
  assert.equal(rows.identity.signer_kid, rows.signing.kid);
  assert.equal(rows.identity.key_kind, "identity");
  const identityOk = await verifyRosterRow(u.signing.pubRaw, {
    sigDomain: rows.identity.sig_domain,
    ownerUserId: rows.identity.owner_user_id,
    keyKind: rows.identity.key_kind,
    pubkeyB64: rows.identity.pubkey,
    kid: rows.identity.kid,
    keyEpoch: rows.identity.key_epoch,
    predecessorKid: rows.identity.predecessor_kid,
    signature: rows.identity.signature,
  });
  assert.equal(identityOk, true);
});

test("roster: tampered field fails verification", async () => {
  const u = await generateUserKeys();
  const rows = await buildSignedRoster(u, "owner-1");
  const tampered = {
    sigDomain: rows.identity.sig_domain,
    ownerUserId: "owner-EVIL", // swapped owner
    keyKind: rows.identity.key_kind,
    pubkeyB64: rows.identity.pubkey,
    kid: rows.identity.kid,
    keyEpoch: rows.identity.key_epoch,
    predecessorKid: rows.identity.predecessor_kid,
    signature: rows.identity.signature,
  };
  assert.equal(await verifyRosterRow(u.signing.pubRaw, tampered), false);
});

test("roster: signature verifies after re-importing signing key from raw scalar", async () => {
  // proves the wrapped-privkey -> re-import -> sign path produces verifiable signatures
  const u = await generateUserKeys();
  const reSigningPriv = await importSigningPrivFromScalar(u.signing.privD);
  const row = {
    sigDomain: SIG_DOMAIN_DEFAULT,
    ownerUserId: "owner-reimport",
    keyKind: "identity",
    pubkeyB64: b64(u.identity.pubRaw),
    kid: u.identity.kid,
    keyEpoch: 1,
    predecessorKid: null,
  };
  const sig = await signRosterRow(reSigningPriv, row);
  assert.equal(await verifyRosterRow(u.signing.pubRaw, { ...row, signature: sig }), true);
});
