import { test } from "node:test";
import assert from "node:assert/strict";
import { InMemoryPinStore, tofuCheck, KeyChangedError } from "../src/pinstore.mjs";

test("pinstore: first use pins; same kid passes; different kid throws KeyChangedError", async () => {
  const store = new InMemoryPinStore();
  const owner = "owner-1";

  const first = await tofuCheck(store, owner, "SIGNING_KID_A");
  assert.equal(first.firstUse, true);
  assert.equal(await store.getPinnedSigningKid(owner), "SIGNING_KID_A");

  const again = await tofuCheck(store, owner, "SIGNING_KID_A");
  assert.equal(again.firstUse, false);

  await assert.rejects(
    () => tofuCheck(store, owner, "SIGNING_KID_B"),
    (e) => {
      assert.ok(e instanceof KeyChangedError);
      assert.equal(e.pinnedKid, "SIGNING_KID_A");
      assert.equal(e.seenKid, "SIGNING_KID_B");
      return true;
    },
  );
});

test("pinstore: different owners are independent", async () => {
  const store = new InMemoryPinStore();
  await tofuCheck(store, "a", "KA");
  await tofuCheck(store, "b", "KB");
  assert.equal(await store.getPinnedSigningKid("a"), "KA");
  assert.equal(await store.getPinnedSigningKid("b"), "KB");
});

test("pinstore: explicit unpin allows re-pin (user-confirmed rotation)", async () => {
  const store = new InMemoryPinStore();
  await tofuCheck(store, "o", "OLD");
  await store.unpin("o");
  const r = await tofuCheck(store, "o", "NEW");
  assert.equal(r.firstUse, true);
  assert.equal(await store.getPinnedSigningKid("o"), "NEW");
});
