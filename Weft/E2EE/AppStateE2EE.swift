//
//  AppStateE2EE.swift
//  Weft — AppState's E2EE Stage 1 hook (key bootstrap at sign-in).
//
//  ONE-TIME SETUP to activate this code: in Xcode, File > Add Package
//  Dependencies… > Add Local… > select `packages/WeftCrypto`, and add the
//  `WeftCrypto` library to the Weft app target. Until then `canImport(WeftCrypto)`
//  is false and every E2EE file compiles to nothing, so the app is unchanged.
//
#if canImport(WeftCrypto)
import Foundation
import WeftCrypto

extension AppState {
    /// E2EE Stage 1 key bootstrap, hung off the sign-in completion. A no-op while
    /// `E2EEMode.current == .off` (the shipped default), so sign-in is untouched
    /// until E2EE is turned on. Never blocks sign-in: a failure is recorded in
    /// `e2eeBootstrapError` and the app continues in plaintext mode.
    func ensureKeysBootstrapped(userId: String) async {
        guard E2EEMode.current != .off, !userId.isEmpty else { return }
        e2eeBootstrapError = nil
        do {
            let result = try await KeyBootstrap.ensure(
                userId: userId,
                supabase: .shared,
                passphrase: { [weak self] isNewKey in
                    guard let self else { throw CancellationError() }
                    return try await self.requestE2EEPassphrase(isNewKey: isNewKey)
                }
            )
            e2eeIdentity = result.identity
        } catch is CancellationError {
            // User dismissed the passphrase prompt — leave keys unloaded.
        } catch {
            e2eeBootstrapError = error.localizedDescription
        }
    }

    /// Present the passphrase sheet and await the user's input. Resumes when the
    /// sheet calls submit (returns the passphrase) or cancel (throws).
    func requestE2EEPassphrase(isNewKey: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            e2eePassphraseRequest = E2EEPassphraseRequest(
                isNewKey: isNewKey,
                submit: { [weak self] passphrase in
                    self?.e2eePassphraseRequest = nil
                    cont.resume(returning: passphrase)
                },
                cancel: { [weak self] in
                    self?.e2eePassphraseRequest = nil
                    cont.resume(throwing: CancellationError())
                }
            )
        }
    }
}
#endif
