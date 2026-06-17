//
//  PassphrasePromptView.swift
//  Weft — the E2EE encryption-passphrase sheet (E2EE_NATIVE_INTEGRATION §1).
//
//  Dormant until E2EE Stage 1 is enabled (E2EEMode.current != .off). Presented
//  by RootView via the `.e2eePassphraseSheet(_:)` modifier below.
//
import SwiftUI

#if canImport(WeftCrypto)

/// A pending passphrase prompt. The root view presents it as a sheet; `submit`
/// or `cancel` resumes the awaiting key bootstrap. The closures are `@MainActor`
/// because they mutate AppState.
struct E2EEPassphraseRequest: Identifiable {
    let id = UUID()
    /// true => "create a passphrase" (first login, with the cannot-reset warning);
    /// false => "unlock" (returning device).
    let isNewKey: Bool
    let submit: @MainActor (String) -> Void
    let cancel: @MainActor () -> Void
}

/// The passphrase sheet. Intentionally minimal — it only collects the passphrase
/// the wrapped-private-key (un)wrap needs.
struct PassphrasePromptView: View {
    let request: E2EEPassphraseRequest

    @State private var passphrase = ""
    @State private var confirm = ""

    private var isValid: Bool {
        if request.isNewKey {
            return passphrase.count >= 8 && passphrase == confirm
        }
        return !passphrase.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.isNewKey ? "Create your encryption passphrase"
                                  : "Enter your encryption passphrase")
                .font(.title3).bold()

            if request.isNewKey {
                Text("Weft cannot reset this passphrase. If you lose it, only your "
                     + "school's recovery can restore your encrypted work.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SecureField("Passphrase", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            if request.isNewKey {
                SecureField("Confirm passphrase", text: $confirm)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel", role: .cancel) { request.cancel() }
                Spacer()
                Button(request.isNewKey ? "Create" : "Unlock") {
                    request.submit(passphrase)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

#endif

extension View {
    /// Presents the E2EE passphrase sheet when one is pending. A no-op (returns
    /// self) until the WeftCrypto package is linked, so RootView can call it
    /// unconditionally.
    @ViewBuilder
    func e2eePassphraseSheet(_ app: AppState) -> some View {
        #if canImport(WeftCrypto)
        @Bindable var app = app
        self.sheet(item: $app.e2eePassphraseRequest) { req in
            PassphrasePromptView(request: req)
        }
        #else
        self
        #endif
    }
}
