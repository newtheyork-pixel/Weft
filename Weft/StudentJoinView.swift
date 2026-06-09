//
//  StudentJoinView.swift
//  Weft — the student join-a-class screen. A single class-code field and a
//  Join button on a glass card. Students join a CLASS once (class code) and
//  their assignments appear automatically; there is no per-assignment code.
//  Ported from the Electron renderer's #stage-join (with auth-screen framing).
//  Mock action only — backend is a later wave.
//

import SwiftUI

struct StudentJoinView: View {
    @Environment(AppState.self) private var app

    @State private var code: String = ""
    @State private var joining: Bool = false
    @State private var joined: Bool = false
    @FocusState private var codeFocused: Bool

    /// A class code is letters + numbers, up to 6 characters.
    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canJoin: Bool { trimmedCode.count >= 4 && !joining }

    var body: some View {
        VStack(spacing: 0) {
            WeftTopBar(role: "Student")
            ScrollView {
                VStack(spacing: Theme.Space.lg) {
                    card
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .background(AmbientBackground())
    }

    // MARK: Card
    private var card: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                header
                field
                joinButton
                helper
                if joined {
                    Label("You're in. Your assignments will appear automatically.", systemImage: "checkmark.circle.fill")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.good)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                backLink
            }
        }
    }

    // MARK: Header
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Theme.Space.sm) {
                Image(systemName: "person.2.badge.key")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Kicker(text: "Student")
            }
            Text("Join a class to start writing")
                .font(Theme.serif(26, .semibold))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Text("Enter the class code your teacher shared. Once you're in, your assignments appear automatically.")
                .font(Theme.sans(14))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Code field
    private var field: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Label("Class code (letters and numbers, e.g. ABC234)", systemImage: "number")
                .font(Theme.sans(13, .medium))
                .foregroundStyle(Theme.inkSoft)
            TextField("ABC234", text: $code)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Theme.inkSoft)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled(true)
                .focused($codeFocused)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .weftGlass(Theme.Radius.md)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(codeFocused ? 0.45 : 0), lineWidth: 1.5)
                )
                .animation(.easeOut(duration: 0.15), value: codeFocused)
                .onChange(of: code) { _, newValue in
                    // Letters + numbers only, uppercased, max 6 — mirrors the
                    // Electron input (maxlength 6, text-transform: uppercase).
                    let filtered = newValue
                        .uppercased()
                        .filter { $0.isLetter || $0.isNumber }
                    let capped = String(filtered.prefix(6))
                    if capped != newValue { code = capped }
                    if joined { withAnimation(.easeOut(duration: 0.2)) { joined = false } }
                }
                .onSubmit { join() }
        }
    }

    // MARK: Join button
    private var joinButton: some View {
        Button(action: join) {
            HStack(spacing: Theme.Space.sm) {
                if joining {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(joining ? "Joining" : "Join class")
                    .font(Theme.sans(15, .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.accent)
        .disabled(!canJoin)
        .help("Join the class with this code")
    }

    // MARK: Helper copy
    private var helper: some View {
        Text("There's no code to type each time.")
            .font(Theme.sans(12.5))
            .foregroundStyle(Theme.muted2)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, Theme.Space.xs)
    }

    // MARK: Back link
    private var backLink: some View {
        Button {
            app.goToHome()
        } label: {
            Label("Back to your classes", systemImage: "chevron.left")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .linkPointer()
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, Theme.Space.xs)
    }

    // MARK: Join action
    private func join() {
        guard canJoin else { return }
        let entered = trimmedCode
        joining = true
        Task {
            let result = await app.joinClass(code: entered)
            joining = false
            if result != nil {
                withAnimation(.easeOut(duration: 0.2)) { joined = true }
                code = ""
                // Let the confirmation read, then return to the class home where
                // the newly joined class is selected and its work has loaded.
                try? await Task.sleep(for: .seconds(1.1))
                app.goToHome()
            }
        }
    }
}

#Preview {
    StudentJoinView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 460, height: 620)
}
