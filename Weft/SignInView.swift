//
//  SignInView.swift
//  Weft — the launcher / sign-in screen, native.
//

import SwiftUI

struct SignInView: View {
    @Environment(AppState.self) private var app
    @State private var busy = false

    var body: some View {
        ZStack {
            AmbientBackground()

            VStack(spacing: Theme.Space.xl) {
                brand
                headline
                signInCard
                roleCard
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, Theme.Space.xxl)
            .padding(.vertical, Theme.Space.xxxl)
            .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text("A cross-device honesty layer for exam apps. Sign in to run, take, or grade an exam.")
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
                app.enterTeacher()
            } label: {
                HStack(spacing: 10) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        GoogleG()
                    }
                    Text(busy ? "Opening Google…" : "Sign in with Google")
                        .font(Theme.sans(15, .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(Color(red: 0.12, green: 0.13, blue: 0.15))
                .background(.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .disabled(busy)

            Text("Use your gcschool.org Google account")
                .font(Theme.sans(12.5))
                .foregroundStyle(Theme.muted)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity)
        .weftGlass(Theme.Radius.lg)
    }

    // MARK: Role chooser (glass)
    private var roleCard: some View {
        VStack(spacing: Theme.Space.lg) {
            Text("You're an admin. Most users skip this. Teacher view runs and grades exams. Student view takes an exam (for testing).")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Theme.Space.md) {
                VStack(spacing: 5) {
                    Button("Teacher view") { app.enterTeacher() }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                    Text("RECOMMENDED")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.9)
                        .foregroundStyle(Theme.good)
                }
                Button("Student view") { app.enterStudent() }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity)
        .weftGlass(Theme.Radius.lg)
    }

    private var footer: some View {
        Text("Proctoring you can prove. Privacy you can trust.")
            .font(Theme.sans(12))
            .foregroundStyle(Theme.muted2)
    }
}

// MARK: - Brand glyph (a small woven tile; real logo asset swaps in later)
struct WovenGlyph: View {
    var size: CGFloat = 44
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [Theme.accentSoft, Theme.accent],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                GeometryReader { geo in
                    Path { p in
                        let n = 4
                        for i in 1..<n {
                            let x = geo.size.width * CGFloat(i) / CGFloat(n)
                            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: geo.size.height))
                            let y = geo.size.height * CGFloat(i) / CGFloat(n)
                            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(0.28), lineWidth: 1)
                }
            )
            .frame(width: size, height: size)
            .shadow(color: Theme.accent.opacity(0.30), radius: 8, y: 3)
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

#Preview {
    SignInView()
        .environment(AppState())
        .preferredColorScheme(.light)   // Weft's identity is light; matches the real app
        .frame(width: 480, height: 760)
}
