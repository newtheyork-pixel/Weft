//
//  Components.swift
//  Weft — shared SwiftUI building blocks used across screens.
//

import SwiftUI

// MARK: - Native interaction helpers

/// A subtle, native-feeling hover highlight for clickable rows/cards — the
/// macOS list-row behaviour. Pairs a faint accent wash with the link pointer.
struct RowHover: ViewModifier {
    var corner: CGFloat = Theme.Radius.sm
    var strength: Double = 0.06
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Theme.accent.opacity(hovering ? strength : 0))
            )
            .pointerStyle(.link)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// Subtle hover wash + link cursor for a clickable row or card.
    func rowHover(corner: CGFloat = Theme.Radius.sm, strength: Double = 0.06) -> some View {
        modifier(RowHover(corner: corner, strength: strength))
    }

    /// Link pointer on hover, for inline text buttons that don't get a wash.
    func linkPointer() -> some View { pointerStyle(.link) }
}

/// Small uppercase section label.
struct Kicker: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Theme.muted)
    }
}

/// A status pill.
struct Chip: View {
    enum Kind { case neutral, good, warn, bad, accent }
    let text: String
    var kind: Kind = .neutral

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch kind {
        case .neutral: Theme.muted
        case .good: Theme.good
        case .warn: Theme.warn
        case .bad: Theme.bad
        case .accent: Theme.accent
        }
    }
}

/// A Liquid Glass surface card with consistent padding.
struct GlassCard<Content: View>: View {
    var corner: CGFloat = Theme.Radius.lg
    var padding: CGFloat = Theme.Space.xl
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .weftGlass(corner)
    }
}

/// The slim brand bar at the top of teacher/student windows. Shows an account
/// menu (with Sign out) once the user is past the sign-in screen.
struct WeftTopBar: View {
    var role: String
    var trailing: AnyView?

    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            WovenGlyph(size: 22)
            Text("Weft")
                .font(Theme.serif(18, .medium))
                .foregroundStyle(Theme.inkSoft)
            Spacer()
            if let trailing { trailing }
            if app.role != nil {
                accountMenu
            } else {
                roleLabel
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.md)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
        }
    }

    private var roleLabel: some View {
        Text(role.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.0)
            .foregroundStyle(Theme.muted)
    }

    private var accountMenu: some View {
        Menu {
            if !app.displayName.isEmpty {
                Text(app.displayName)
                if !app.email.isEmpty { Text(app.email) }
                Divider()
            }
            Button("Sign out") { app.signOut() }
        } label: {
            HStack(spacing: 6) {
                roleLabel
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.muted)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
