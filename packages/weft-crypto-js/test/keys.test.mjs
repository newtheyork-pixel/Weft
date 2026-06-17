import { test } from "node:test";
import assert from "node:assert/strict";
import {
  generateUserKeys,
  kidOf,
  jwkFromScalar,
  importIdentityPrivFromScalar,
  importSigningPrivFromScalar,
  rawPubFromPriv,
} from "../src/keys.mjs";
import { b64, ub64 } from "../src/util.mjs";

test("keys: bootstrap produces identity(ECDH)+signing(ECDSA), 65B raw pubs, 32B scalars", async () => {
  const u = await generateUserKeys();
  assert.equal(u.identity.pubRaw.length, 65);
  assert.equal(u.identity.pubRaw[0], 0x04);
  assert.equal(u.signing.pubRaw.length, 65);
  assert.equal(u.signing.pubRaw[0], 0x04);
  assert.equal(u.identity.privD.length, 32);
  assert.equal(u.signing.privD.length, 32);
});

test("keys: kid = base64(SHA-256(raw pubkey)), 32B digest", async () => {
  const u = await generateUserKeys();
  const k = await kidOf(u.identity.pubRaw);
  assert.equal(k, u.identity.kid);
  assert.equal(ub64(k).length, 32);
  assert.notEqual(u.identity.kid, u.signing.kid);
});

test("keys: scalar -> JWK derivation recovers the same public point", async () => {
  const u = await generateUserKeys();
  // re-import identity private scalar, derive its public, compare to original raw pub
  const jwk = jwkFromScalar(u.identity.privD);
  const reImportedPriv = await importIdentityPrivFromScalar(u.identity.privD);
  const reRaw = await rawPubFromPriv(reImportedPriv);
  assert.equal(b64(reRaw), b64(u.identity.pubRaw));
  // jwk has x,y populated
  assert.ok(jwk.x && jwk.y && jwk.d);
});

test("keys: re-imported signing scalar can sign (round-trips via verify in roster test)", async () => {
  const u = await generateUserKeys();
  const reSign = await importSigningPrivFromScalar(u.signing.privD);
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    reSign,
    new TextEncoder().encode("hello"),
  );
  // verify with original public key
  const ver = await crypto.subtle.importKey(
    "raw",
    u.signing.pubRaw,
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["verify"],
  );
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    ver,
    sig,
    new TextEncoder().encode("hello"),
  );
  assert.equal(ok, true);
});
