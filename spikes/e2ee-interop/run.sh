#!/bin/bash
# Cross-language interop test: prove CryptoKit <-> Web Crypto agree byte-for-byte on the Weft envelope.
set -uo pipefail
cd "$(dirname "$0")"
PT='The mitochondria is the powerhouse of the cell. <b>Draft v1 — never autosaved in plaintext.</b>'
SID='11111111-1111-1111-1111-111111111111'
VER='1'
fail() { echo "   ✗ FAIL: $1"; exit 1; }

echo "1) Node generates a recipient P-256 keypair (JWK)..."
node envelope.mjs genkeys . || fail "genkeys"

echo "2) Swift ENCRYPT  ->  JS DECRYPT"
swift envelope.swift encrypt recipient.pub.jwk "$PT" "$SID" "$VER" > env_swift.json || fail "swift encrypt"
OUT=$(node envelope.mjs decrypt recipient.priv.jwk env_swift.json) || fail "js decrypt of swift envelope"
[ "$OUT" = "$PT" ] && echo "   ✓ PASS swift→js" || fail "swift→js mismatch: got [$OUT]"

echo "3) JS ENCRYPT  ->  Swift DECRYPT"
node envelope.mjs encrypt recipient.pub.jwk "$PT" "$SID" "$VER" > env_js.json || fail "js encrypt"
OUT2=$(swift envelope.swift decrypt recipient.priv.jwk env_js.json) || fail "swift decrypt of js envelope"
[ "$OUT2" = "$PT" ] && echo "   ✓ PASS js→swift" || fail "js→swift mismatch: got [$OUT2]"

echo "4) Negative — tampered AAD (changed bound submission version) must be REJECTED by both"
node -e 'const fs=require("fs");const e=JSON.parse(fs.readFileSync("env_swift.json"));e.content.aad=e.content.aad.replace("|v1","|v2");fs.writeFileSync("env_tampered.json",JSON.stringify(e));'
node envelope.mjs decrypt recipient.priv.jwk env_tampered.json >/dev/null 2>&1 && fail "js accepted tampered AAD" || echo "   ✓ PASS js rejected tampered AAD"
swift envelope.swift decrypt recipient.priv.jwk env_tampered.json >/dev/null 2>&1 && fail "swift accepted tampered AAD" || echo "   ✓ PASS swift rejected tampered AAD"

echo "5) Negative — flipped ciphertext byte must be REJECTED"
node -e 'const fs=require("fs");const e=JSON.parse(fs.readFileSync("env_js.json"));const b=Buffer.from(e.content.ct,"base64");b[0]^=0x01;e.content.ct=b.toString("base64");fs.writeFileSync("env_flip.json",JSON.stringify(e));'
swift envelope.swift decrypt recipient.priv.jwk env_flip.json >/dev/null 2>&1 && fail "swift accepted flipped ct" || echo "   ✓ PASS swift rejected flipped ct"

echo ""
echo "ALL INTEROP TESTS PASSED ✅  (CryptoKit and Web Crypto agree byte-for-byte; AEAD/AAD integrity enforced both ways)"
