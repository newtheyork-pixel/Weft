//
//  EssayPasswordView.swift
//  Weft — pick the essay password (first time), or type it once on a new
//  Mac. Covers the app until the key is on this Mac.
//

import SwiftUI

struct EssayPasswordView: View {
    @Environment(AppState.self) private var app
    @State private var password = ""
    @State private var confirm = ""
    @State private var problem: String?
    @State private var working = false
    /// Unlock screen: the person chose "Forgot it?" and is picking a new one.
    @State private var resetting = false

    private var isStudent: Bool { app.accountRole == .student }
    private var picking: Bool { app.essayKeyState == .needsSetup || resetting }

    var body: some View {
        ZStack {
            AmbientBackground()
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                HStack(spacing: Theme.Space.sm) {
                    Image(systemName: "lock.fill").foregroundStyle(Theme.accent)
                    Text(title)
                        .font(Theme.serif(24, .semibold))
                        .foregroundStyle(Theme.inkSoft)
                }
                Text(explainer)
                    .font(Theme.sans(13.5))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                SecureField(picking ? "Essay password (at least \(WeftContentSeal.minPasswordLength) characters)"
                                    : "Essay password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                if picking {
                    SecureField("Type it again", text: $confirm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                }
                if let problem {
                    Text(problem)
                        .font(Theme.sans(12.5))
                        .foregroundStyle(Theme.bad)
                }

                HStack {
                    Button(action: submit) {
                        HStack(spacing: 8) {
                            if working { ProgressView().controlSize(.small) }
                            Text(picking ? "Save password" : "Unlock")
                        }
                        .frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || password.isEmpty)
                    Spacer()
                    if app.essayKeyState == .needsUnlock {
                        Button(resetting ? "Back" : "Forgot it?") {
                            resetting.toggle(); problem = nil; password = ""; confirm = ""
                        }
                        .buttonStyle(.plainHit)
                        .foregroundStyle(Theme.accent)
                    }
                    Button("Sign out") { app.signOut() }
                        .buttonStyle(.plainHit)
                        .foregroundStyle(Theme.muted)
                        .padding(.leading, Theme.Space.md)
                }
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: 460)
            .weftGlass(Theme.Radius.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        if resetting { return "Pick a new essay password" }
        return app.essayKeyState == .needsSetup ? "Pick an essay password" : "Enter your essay password"
    }

    private var explainer: String {
        if resetting {
            return isStudent
                ? "Essays you wrote with your old password can't be opened by you anymore. Your teacher can still read and grade them."
                : "Essays your students wrote before now can't be opened anymore. Only use this if the old password is really lost."
        }
        if app.essayKeyState == .needsSetup {
            return (isStudent
                ? "Your essays are locked with this password, so only you and your teacher can read them."
                : "Your students' essays are locked with this password, so only you and each student can read them.")
                + " You'll type it once on each Mac. Nobody can reset it, not even Weft, so write it down."
        }
        return "You only need to type it once on this Mac."
    }

    private func submit() {
        guard !working, !password.isEmpty else { return }
        if picking {
            guard password.count >= WeftContentSeal.minPasswordLength else {
                problem = "Use at least \(WeftContentSeal.minPasswordLength) characters."; return
            }
            guard password == confirm else { problem = "The two passwords don't match."; return }
        }
        working = true; problem = nil
        let pw = password
        Task {
            let result: String?
            if app.essayKeyState == .needsSetup { result = await app.setEssayPassword(pw) }
            else if resetting { result = await app.resetEssayPassword(pw) }
            else { result = await app.unlockEssays(pw) }
            working = false
            if let result { problem = result } else { password = ""; confirm = ""; resetting = false }
        }
    }
}
