//
//  SignInView.swift
//  Weft — the launcher / sign-in screen, native.
//

import SwiftUI

struct SignInView: View {
    @Environment(AppState.self) private var app

    private var busy: Bool { app.isLoading }
    @State private var googleHovering = false
    @State private var googlePressed = false

    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(spacing: Theme.Space.xl) {
                brand
                headline
                // Before sign-in: only Google. After: students are routed away
                // automatically, so a signed-in chooser here is a teacher/admin
                // picking a view (the Google card is gone).
                if !app.signedIn {
                    signInCard
                } else if app.role == nil {
                    resolvingCard
                } else {
                    roleCard
                }
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.vertical, Theme.Space.xxxl)
            .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.25), value: app.signedIn)
        .animation(.smooth(duration: 0.25), value: app.role)
    }

    // MARK: Brand
    private var brand: some View {
        HStack(spacing: 14) {
            WovenGlyph(size: 44)
            Text("Weft")
                .font(Theme.serif(42, .medium))
                .foregroundStyle(Theme.inkSoft)
                .tracking(-0.5)
        }
        .padding(.top, Theme.Space.lg)
    }

    private var headline: some View {
        VStack(spacing: Theme.Space.sm) {
            Text("Proctor with proof, not promises.")
                .font(Theme.serif(23))
                .foregroundStyle(Theme.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(app.signedIn
                 ? "Signed in as \(app.email.isEmpty ? app.displayName : app.email)."
                 : "A cross-device honesty layer for exam apps. Sign in to run, take, or grade an exam.")
                .font(Theme.sans(14))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Sign-in card (glass)
    private var signInCard: some View {
        VStack(spacing: Theme.Space.md) {
            Button {
                Task { await app.signInWithGoogle() }
            } label: {
                HStack(spacing: 10) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        GoogleG()
                    }
                    Text(busy ? "Finish signing in with your browser…" : "Sign in with Google")
                        .font(Theme.sans(15, .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(Color(red: 0.12, green: 0.13, blue: 0.15))
                .background(.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.black.opacity(googleHovering ? 0.20 : 0.12))
                )
                .shadow(color: Color.black.opacity(googleHovering ? 0.12 : 0.06),
                        radius: googleHovering ? 7 : 4, y: googleHovering ? 3 : 2)
                .scaleEffect((googlePressed && !busy) ? 0.98 : 1)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .onChange(of: busy) { _, b in if b { googlePressed = false } }
            .pointerStyle(.link)
            .onHover { googleHovering = $0 }
            .animation(.easeOut(duration: 0.14), value: googleHovering)
            .animation(.easeOut(duration: 0.12), value: googlePressed)
            .help("Sign in with your gcschool.org Google account")
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in googlePressed = true }
                    .onEnded { _ in googlePressed = false }
            )

            if let error = app.errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(error)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.bad)
                .transition(.opacity)
            } else if busy {
                // The flow now lives in the user's browser; if they closed that
                // tab, no callback ever arrives — give them a way back.
                Button("Cancel") { app.cancelSignIn() }
                    .buttonStyle(.plain)
                    .font(Theme.sans(12.5, .semibold))
                    .foregroundStyle(Theme.accent)
                    .pointerStyle(.link)
                    .transition(.opacity)
            } else {
                Text("Use your gcschool.org Google account")
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.muted)
                    .transition(.opacity)
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity)
        .weftGlass(Theme.Radius.lg)
        .animation(.easeOut(duration: 0.2), value: app.errorMessage)
        .animation(.easeOut(duration: 0.18), value: busy)
    }

    // MARK: Resolving (signed in, role not yet known)
    private var resolvingCard: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Checking your account…")
                .font(Theme.sans(13.5))
                .foregroundStyle(Theme.muted)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity)
        .weftGlass(Theme.Radius.lg)
    }

    // MARK: View chooser (glass) — signed-in teachers/admins only
    private var roleCard: some View {
        VStack(spacing: Theme.Space.lg) {
            Text(roleCardCopy)
                .font(Theme.sans(13))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Space.md) {
                VStack(spacing: 5) {
                    Button {
                        app.enterTeacher()
                    } label: {
                        Label("Teacher view", systemImage: "person.fill.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .pointerStyle(.link)
                    .help("Run and grade exams")
                    Text("RECOMMENDED")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.9)
                        .foregroundStyle(Theme.good)
                }
                Button {
                    app.enterStudent()
                } label: {
                    Label("Student view", systemImage: "square.and.pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .pointerStyle(.link)
                .help("Take an exam")
            }

            Button("Not you? Sign out") { app.signOut() }
                .buttonStyle(.plain)
                .font(Theme.sans(12))
                .foregroundStyle(Theme.muted)
                .pointerStyle(.link)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity)
        .weftGlass(Theme.Radius.lg)
    }

    /// Shown only to signed-in teachers/admins; students are routed straight to
    /// the portal and never see this card.
    private var roleCardCopy: String {
        "Choose how to continue. Teacher view runs and grades exams. Student view takes an exam."
    }

    private var footer: some View {
        Text("Proctoring you can prove. Privacy you can trust.")
            .font(Theme.sans(12))
            .foregroundStyle(Theme.muted2)
    }
}

// MARK: - Brand mark (the real Weft app logo asset). Used in the top bar on
// every screen, the sign-in lockup, and Settings. Name kept as `WovenGlyph` so
// all call sites are unchanged.
struct WovenGlyph: View {
    var size: CGFloat = 44
    var body: some View {
        Image("WeftLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

// MARK: - A simple recognizable Google "G"
struct GoogleG: View {
    var body: some View {
        Text("G")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Color(red: 0.259, green: 0.522, blue: 0.957))
    }
}

#Preview("Signed out (Google only)") {
    SignInView()
        .environment(AppState())
        .preferredColorScheme(.light)   // Weft's identity is light; matches the real app
        .frame(width: 480, height: 760)
}

#Preview("Signed in (teacher chooser)") {
    let app = AppState()
    app.signedIn = true
    app.accountRole = .teacher
    app.role = .teacher
    app.displayName = "Thomas Seirer"
    app.email = "tseirer@gcschool.org"
    return SignInView()
        .environment(app)
        .preferredColorScheme(.light)
        .frame(width: 480, height: 760)
}
