//
//  E2EEMode.swift
//  Weft — staged E2EE rollout flag (E2EE_NATIVE_INTEGRATION §7).
//
//  Default OFF: the shipped plaintext behavior is untouched until each stage is
//  proven on real devices. Gated behind `canImport(WeftCrypto)` so the app
//  compiles identically until the WeftCrypto package is linked (see the file
//  header note in AppStateE2EE.swift for the one-time link step).
//
#if canImport(WeftCrypto)
import Foundation

enum E2EEMode {
    /// No E2EE; plaintext only (shipped behavior).
    case off
    /// Encrypt + wrap in addition to plaintext (Stage 2).
    case dualWrite
    /// Ciphertext authoritative; stop writing plaintext (Stage 3).
    case enforced

    /// Build-time default. Stage 1 wires key bootstrap but keeps content OFF.
    static let current: E2EEMode = .off
}
#endif
