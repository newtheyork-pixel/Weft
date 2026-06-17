import { test } from "node:test";
import assert from "node:assert/strict";
import { wrapPrivateKey, openPrivateKey, PBKDF2_ITERS } from "../src/wrappedKey.mjs";
import { generateUserKeys } from "../src/keys.mjs";
import { b64, ub64, fromUtf8 } from "../src/util.mjs";

test("wrappedKey: wrap then open round-trips both scalars", async () => {
  const u = await generateUserKeys();
  const { blob, kdfParams } = await wrapPrivateKey("correct horse battery staple", {
    identityD: u.identity.privD,
    signingD: u.signing.privD,
  });
  const opened = await openPrivateKey("correct horse battery staple", blob);
  assert.equal(b64(opened.identityD), b64(u.identity.privD));
  assert.equal(b64(opened.signingD), b64(u.signing.privD));
  // kdf_params mirrors {kdf, iters, salt}
  assert.equal(kdfParams.kdf, "pbkdf2-sha256");
  assert.equal(kdfParams.iters, PBKDF2_ITERS);
  assert.ok(typeof kdfParams.salt === "string");
});

test("wrappedKey: outer blob has the exact documented shape", async () => {
  const u = await generateUserKeys();
  const { blob, kdfParams } = await wrapPrivateKey("pw", {
    identityD: u.identity.privD,
    signingD: u.signing.privD,
  });
  const outer = JSON.parse(fromUtf8(ub64(blob)));
  assert.equal(outer.v, 1);
  assert.equal(outer.kdf, "pbkdf2-sha256");
  assert.equal(outer.iters, 600000);
  assert.equal(ub64(outer.salt).length, 16);
  assert.equal(ub64(outer.nonce).length, 12);
  // ct = ciphertext||tag(16); bundle JSON is well over 0 bytes, tag adds 16
  assert.ok(ub64(outer.ct).length > 16);
  // kdf_params salt matches outer salt
  assert.equal(kdfParams.salt, outer.salt);
});

test("wrappedKey: wrong passphrase fails (GCM tag)", async () => {
  const u = await generateUserKeys();
  const { blob } = await wrapPrivateKey("right-pw", {
    identityD: u.identity.privD,
    signingD: u.signing.privD,
  });
  await assert.rejects(() => openPrivateKey("wrong-pw", blob));
});

test("wrappedKey: re-imported scalars are usable (identity opens an envelope, signing signs)", async () => {
  const { generateUserKeys: gen } = await import("../src/keys.mjs");
  const { importIdentityPrivFromScalar, importSigningPrivFromScalar, rawPubFromPriv } = await import(
    "../src/keys.mjs"
  );
  const { seal, openText } = await import("../src/envelope.mjs");

  const u = await gen();
  const { blob } = await wrapPrivateKey("pw", {
    identityD: u.identity.privD,
    signingD: u.signing.privD,
  });
  const opened = await openPrivateKey("pw", blob);

  // identity: re-import, must open an envelope sealed to the original pubkey
  const idPriv = await importIdentityPrivFromScalar(opened.identityD);
  const idPubRaw = await rawPubFromPriv(idPriv);
  assert.equal(b64(idPubRaw), b64(u.identity.pubRaw));
  const env = await seal({
    recipientRawPubs: [u.identity.pubRaw],
    plaintext: "round-trip via wrapped key",
    submissionId: "s",
    version: 1,
  });
  assert.equal(await openText(env, idPriv, idPubRaw), "round-trip via wrapped key");

  // signing: re-import, must produce a signature verifiable by the original signing pubkey
  const sgPriv = await importSigningPrivFromScalar(opened.signingD);
  const msg = new TextEncoder().encode("sign me");
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, sgPriv, msg);
  const ver = await crypto.subtle.importKey("raw", u.signing.pubRaw, { name: "ECDSA", namedCurve: "P-256" }, true, [
    "verify",
  ]);
  assert.equal(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, ver, sig, msg), true);
});
