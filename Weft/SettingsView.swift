//
//  SettingsView.swift
//  Weft — the native macOS Settings window (⌘,). Account, writing preferences,
//  and an About pane. Real, wired preferences via @AppStorage that the exam
//  workspace reads.
//

import SwiftUI

/// Shared preference keys so views and Settings agree on the same storage.
enum Prefs {
    static let referenceDefaultMode = "weft.referenceDefaultMode" // "split"|"pdf"|"web"
    static let confirmBeforeSubmit  = "weft.confirmBeforeSubmit"  // Bool
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 360)
        .preferredColorScheme(.light)
    }
}

private struct GeneralSettings: View {
    @Environment(AppState.self) private var app
    @AppStorage(Prefs.referenceDefaultMode) private var referenceMode = "split"
    @AppStorage(Prefs.confirmBeforeSubmit) private var confirmSubmit = true

    var body: some View {
        Form {
            if app.signedIn {
                Section("Account") {
                    LabeledContent("Signed in as", value: app.displayName.isEmpty ? "Not signed in" : app.displayName)
                    if !app.email.isEmpty { LabeledContent("Email", value: app.email) }
                    if let role = app.role {
                        LabeledContent("Role", value: role.rawValue.capitalized)
                    }
                    if app.canChooseView {
                        Button("Switch view") { app.switchView() }
                    }
                    Button("Sign Out", role: .destructive) { app.signOut() }
                }
            } else if app.role != nil {
                Section("Preview") {
                    LabeledContent("Mode", value: "Previewing as \(app.role?.rawValue.capitalized ?? "")")
                    Button("Exit preview") { app.signOut() }
                }
            }

            Section("Writing") {
                Picker("Default reference layout", selection: $referenceMode) {
                    Text("Split (PDF + web)").tag("split")
                    Text("PDF only").tag("pdf")
                    Text("Web only").tag("web")
                }
                Toggle("Confirm before submitting an exam", isOn: $confirmSubmit)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: Theme.Space.lg) {
            WovenGlyph(size: 64)
            VStack(spacing: 4) {
                Text("Weft")
                    .font(Theme.serif(34, .medium))
                    .foregroundStyle(Theme.inkSoft)
                Text("Proctor with proof, not promises.")
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.muted)
            }
            Text(version)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.muted2)
            Text("Native macOS build")
                .font(Theme.sans(11))
                .foregroundStyle(Theme.muted2)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.xxl)
    }
}
