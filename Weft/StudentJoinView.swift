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
                    Text("You're in. Your assignments will appear automatically.")
                        .font(Theme.sans(13, .semibold))
                        .foregroundStyle(Theme.good)
                        .transition(.opacity)
                }
                backLink
            }
        }
    }

    // MARK: Header
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker(text: "Student")
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
            Text("Class code (letters & numbers, e.g. ABC234)")
                .font(Theme.sans(13, .medium))
                .foregroundStyle(Theme.inkSoft)
            TextField("ABC234", text: $code)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Theme.inkSoft)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled(true)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .weftGlass(Theme.Radius.md)
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
            Text(joining ? "Joining…" : "Join class")
                .font(Theme.sans(15, .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.accent)
        .disabled(!canJoin)
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
            // Mock: return to the class home.
        } label: {
            Text("Back to your classes")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, Theme.Space.xs)
    }

    // MARK: Mock action
    private func join() {
        guard canJoin else { return }
        joining = true
        // No backend yet — simulate the join, then show the confirmation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            joining = false
            withAnimation(.easeOut(duration: 0.2)) { joined = true }
            code = ""
        }
    }
}

#Preview {
    StudentJoinView()
        .environment(AppState())
        .preferredColorScheme(.light)
        .frame(width: 460, height: 620)
}
