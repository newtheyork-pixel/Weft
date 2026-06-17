// Weft E2EE — compiled-in escrow-key allowlist.
//
// The client refuses to wrap a DEK to any escrow public key whose kid is not in
// this shipped allowlist. This converts escrow-key substitution from a silent
// single-RPC operator backdoor into "requires shipping a malicious signed client
// build" — auditable. The allowlist is a TRUST ANCHOR baked into the binary, on
// par with the TOFU pin store (see docs/E2EE_KEY_SUBSTRATE.md, decision §6.3).
import Foundation

/// Escrow-kid allowlist. `contains(_:)` gates every escrow wrap.
public struct WeftEscrowAllowlist {
    /// The escrow signing-key kids shipped in this build.
    ///
    /// EMPTY in v1 — there is no provisioned escrow key yet (the HSM/KMS has not
    /// published one; see the substrate "pre-apply checklist"). Until a real
    /// `kid = base64(SHA-256(escrow_pub_x963))` is added here, the client wraps
    /// to NO escrow key, which is the correct fail-closed state for keys-only
    /// Stage 1 (no content is wrapped yet).
    public static let shipped: Set<String> = []

    public let kids: Set<String>

    public init(kids: Set<String> = WeftEscrowAllowlist.shipped) {
        self.kids = kids
    }

    /// True iff `kid` is an escrow key this build is willing to wrap to.
    public func contains(_ kid: String) -> Bool {
        kids.contains(kid)
    }
}
