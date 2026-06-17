// Weft E2EE envelope — Apple CryptoKit reference implementation (native macOS client stand-in).
// MUST interoperate byte-for-byte with envelope.mjs (Web Crypto).
// Suite: P256-HKDF-SHA256-AES256GCM. ECIES-style: ephemeral ECDH-P256 -> HKDF-SHA256 -> AES-256-GCM wraps a per-item DEK.
//
// CLI:
//   swift envelope.swift encrypt <pub.jwk> <plaintext> <submissionId> <version>   -> envelope JSON on stdout
//   swift envelope.swift decrypt <priv.jwk> <envelope.json>                       -> plaintext on stdout

import Foundation
import CryptoKit

// ---- Protocol constants (MUST match envelope.mjs byte-for-byte) ----
let SUITE = "P256-HKDF-SHA256-AES256GCM"
let SALT = Data("weft-e2ee-v1".utf8)         // HKDF salt
let WRAP_LABEL = Data("weft-dek-wrap/v1".utf8) // HKDF info prefix
let WRAP_AAD = Data("weft-wrap/v1".utf8)       // AAD for the DEK-wrap AES-GCM

func die(_ msg: String) -> Never { FileHandle.standardError.write(Data((msg + "\n").utf8)); exit(1) }

// base64url (JWK) and standard base64 (envelope) helpers
func b64urlDecode(_ s: String) -> Data {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    guard let d = Data(base64Encoded: t) else { die("bad base64url") }
    return d
}
func b64Decode(_ s: String) -> Data { guard let d = Data(base64Encoded: s) else { die("bad base64") }; return d }
func b64(_ d: Data) -> String { d.base64EncodedString() }

func readJSON(_ path: String) -> [String: Any] {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { die("cannot read JSON: \(path)") }
    return obj
}

// HKDF-SHA256 over the ECDH shared secret -> 32-byte AES key. Matches Web Crypto deriveBits(ECDH)->HKDF.
func deriveKek(shared: SharedSecret, ephPubRaw: Data, recipPubRaw: Data) -> SymmetricKey {
    let info = WRAP_LABEL + ephPubRaw + recipPubRaw
    return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: SALT, sharedInfo: info, outputByteCount: 32)
}

func sha256(_ d: Data) -> Data { Data(SHA256.hash(data: d)) }

// ---- encrypt ----
func encrypt(pubJwkPath: String, plaintext: String, sid: String, ver: String) {
    let jwk = readJSON(pubJwkPath)
    guard let x = jwk["x"] as? String, let y = jwk["y"] as? String else { die("pub jwk missing x/y") }
    let recipPubRaw = Data([0x04]) + b64urlDecode(x) + b64urlDecode(y)            // 0x04||X||Y (65)
    guard let recipPub = try? P256.KeyAgreement.PublicKey(x963Representation: recipPubRaw) else { die("bad recipient pubkey") }

    // 1) content: random DEK + AES-256-GCM, AAD = sid|v<ver>
    let dekKey = SymmetricKey(size: .bits256)
    let dek = dekKey.withUnsafeBytes { Data($0) }
    let aadStr = "\(sid)|v\(ver)"
    let cbox = try! AES.GCM.seal(Data(plaintext.utf8), using: dekKey, nonce: AES.GCM.Nonce(), authenticating: Data(aadStr.utf8))
    let contentNonce = Data(cbox.nonce)
    let contentCt = cbox.ciphertext + cbox.tag                                    // match Web Crypto ct||tag

    // 2) wrap DEK to recipient via ephemeral ECDH
    let eph = P256.KeyAgreement.PrivateKey()
    let ephPubRaw = eph.publicKey.x963Representation
    guard let shared = try? eph.sharedSecretFromKeyAgreement(with: recipPub) else { die("ECDH failed") }
    let kek = deriveKek(shared: shared, ephPubRaw: ephPubRaw, recipPubRaw: recipPubRaw)
    let wbox = try! AES.GCM.seal(dek, using: kek, nonce: AES.GCM.Nonce(), authenticating: WRAP_AAD)
    let wrapNonce = Data(wbox.nonce)
    let wrappedDek = wbox.ciphertext + wbox.tag

    let env: [String: Any] = [
        "v": 1, "suite": SUITE,
        "content": ["aad": aadStr, "nonce": b64(contentNonce), "ct": b64(contentCt)],
        "wraps": [["recipient_kid": b64(sha256(recipPubRaw)), "eph_pub": b64(ephPubRaw),
                   "nonce": b64(wrapNonce), "wrapped_dek": b64(wrappedDek)]],
    ]
    let out = try! JSONSerialization.data(withJSONObject: env)
    FileHandle.standardOutput.write(out)
}

// ---- decrypt ----
func decrypt(privJwkPath: String, envPath: String) {
    let jwk = readJSON(privJwkPath)
    guard let x = jwk["x"] as? String, let y = jwk["y"] as? String, let d = jwk["d"] as? String else { die("priv jwk missing x/y/d") }
    let recipPubRaw = Data([0x04]) + b64urlDecode(x) + b64urlDecode(y)
    guard let recipPriv = try? P256.KeyAgreement.PrivateKey(rawRepresentation: b64urlDecode(d)) else { die("bad recipient privkey") }

    let env = readJSON(envPath)
    guard let content = env["content"] as? [String: Any],
          let wraps = env["wraps"] as? [[String: Any]] else { die("bad envelope") }
    let myKid = b64(sha256(recipPubRaw))
    let w = wraps.first(where: { ($0["recipient_kid"] as? String) == myKid }) ?? wraps.first!

    guard let ephB64 = w["eph_pub"] as? String,
          let wNonce = w["nonce"] as? String, let wDek = w["wrapped_dek"] as? String else { die("bad wrap") }
    let ephPubRaw = b64Decode(ephB64)
    guard let ephPub = try? P256.KeyAgreement.PublicKey(x963Representation: ephPubRaw) else { die("bad eph pubkey") }
    guard let shared = try? recipPriv.sharedSecretFromKeyAgreement(with: ephPub) else { die("ECDH failed") }
    let kek = deriveKek(shared: shared, ephPubRaw: ephPubRaw, recipPubRaw: recipPubRaw)

    // unwrap DEK
    let wrapped = b64Decode(wDek)
    let wct = wrapped.prefix(wrapped.count - 16), wtag = wrapped.suffix(16)
    guard let wsb = try? AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: b64Decode(wNonce)), ciphertext: wct, tag: wtag),
          let dek = try? AES.GCM.open(wsb, using: kek, authenticating: WRAP_AAD) else { die("DEK unwrap auth failed") }

    // decrypt content
    guard let aad = content["aad"] as? String, let cNonce = content["nonce"] as? String, let cCt = content["ct"] as? String else { die("bad content") }
    let cbytes = b64Decode(cCt)
    let cct = cbytes.prefix(cbytes.count - 16), ctag = cbytes.suffix(16)
    guard let csb = try? AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: b64Decode(cNonce)), ciphertext: cct, tag: ctag),
          let pt = try? AES.GCM.open(csb, using: SymmetricKey(data: dek), authenticating: Data(aad.utf8)) else { die("content auth failed") }

    FileHandle.standardOutput.write(pt)
}

// ---- dispatch ----
let args = CommandLine.arguments
guard args.count >= 2 else { die("usage: encrypt <pub.jwk> <pt> <sid> <ver> | decrypt <priv.jwk> <env.json>") }
switch args[1] {
case "encrypt":
    guard args.count == 6 else { die("encrypt needs <pub.jwk> <pt> <sid> <ver>") }
    encrypt(pubJwkPath: args[2], plaintext: args[3], sid: args[4], ver: args[5])
case "decrypt":
    guard args.count == 4 else { die("decrypt needs <priv.jwk> <env.json>") }
    decrypt(privJwkPath: args[2], envPath: args[3])
default:
    die("unknown command \(args[1])")
}
