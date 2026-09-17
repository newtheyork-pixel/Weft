//
//  StudentJoinView.swift
//  Weft — the student join-a-class screen. A single class-code field and a
//  Join button on a glass card. Students join a CLASS once (class code) and
//  their assignments appear automatically; there is no per-assignment code.
//

import SwiftUI

struct StudentJoinView: View {
    @Environment(AppState.self) private var app

    @State private var code: String = ""
    @State private var joining: Bool = false
    @State private var joinedName: String?
    @FocusState private var codeFocused: Bool

    /// A class code is letters + numbers, up to 6 characters.
    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canJoin: Bool { trimmedCode.count >= 4 && !joining && joinedName == nil }

    var body: some View {
        VStack(spacing: 0) {
            WeftTopBar(role: "Student")
            ScrollView {
                VStack(spacing: Theme.Space.lg) {
                    if let name = joinedName {
                        successCard(name)
                    } else {
                        card
                    }
                }
                .padding(Theme.Space.xl)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
                .animation(.easeOut(duration: 0.2), value: joinedName)
                .animation(.easeOut(duration: 0.2), value: app.errorMessage)
            }
        }
        .background(AmbientBackground())
        .onAppear { consumePrefill() }
        .onChange(of: app.prefilledJoinCode) { _, _ in consumePrefill() }
    }

    /// Pull a `weft://join?code=…` deep-link code into the field and consume it.
    /// Driven by both appear and state-change so a link that arrives while the
    /// join screen is already visible still pre-fills.
    private func consumePrefill() {
        guard joinedName == nil else { return }
        guard let pre = app.prefilledJoinCode, !pre.isEmpty else { return }
        code = String(pre.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6))
        app.prefilledJoinCode = nil
        codeFocused = true
    }

    // MARK: Card
    private var card: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                header
                field
                joinButton
                helper
                if let error = app.errorMessage { errorBanner(error) }
                backLink
            }
        }
    }

    private func successCard(_ name: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.good)
                    Kicker(text: "You're in")
                }
                Text("Joined \(name)")
                    .font(Theme.serif(26, .semibold))
                    .foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Your assignments will appear on your class home. Taking you there now.")
                    .font(Theme.sans(14))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warn)
            Text(message)
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.md)
        .background(Theme.warn.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.sm))
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
        .linkPointer()
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
            if let result {
                joinedName = result.name
                try? await Task.sleep(for: .seconds(1.2))
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
