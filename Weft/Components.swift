//
//  Components.swift
//  Weft — shared SwiftUI building blocks used across screens.
//

import SwiftUI

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

/// The slim brand bar at the top of teacher/student windows.
struct WeftTopBar: View {
    var role: String
    var trailing: AnyView?

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            WovenGlyph(size: 22)
            Text("Weft")
                .font(Theme.serif(18, .medium))
                .foregroundStyle(Theme.inkSoft)
            Spacer()
            if let trailing { trailing }
            Text(role.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.md)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
        }
    }
}
