//
//  Glass.swift
//  Weft — real macOS 26 Liquid Glass material + the ambient field it floats on.
//

import SwiftUI

extension View {
    /// Apply the real Liquid Glass material as a rounded surface. The whole
    /// point of going native: this is the genuine refractive material, not a
    /// CSS approximation.
    func weftGlass(_ corner: CGFloat = Theme.Radius.lg,
                   tint: Color? = nil,
                   interactive: Bool = false) -> some View {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return self.glassEffect(glass, in: .rect(cornerRadius: corner))
    }
}

/// A soft, deep mesh-gradient field. Glass needs vibrant content behind it to
/// refract; this is Weft's "wallpaper" in the navy + warm palette.
struct AmbientBackground: View {
    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                .init(0.0, 0.0), .init(0.5, 0.0), .init(1.0, 0.0),
                .init(0.0, 0.5), .init(0.5, 0.5), .init(1.0, 0.5),
                .init(0.0, 1.0), .init(0.5, 1.0), .init(1.0, 1.0),
            ],
            colors: [
                Color(red: 0.80, green: 0.86, blue: 0.95), Color(red: 0.87, green: 0.83, blue: 0.76), Color(red: 0.76, green: 0.83, blue: 0.92),
                Color(red: 0.58, green: 0.69, blue: 0.86), Color(red: 0.92, green: 0.94, blue: 0.98), Color(red: 0.85, green: 0.79, blue: 0.68),
                Color(red: 0.137, green: 0.322, blue: 0.486), Color(red: 0.46, green: 0.59, blue: 0.78), Color(red: 0.29, green: 0.435, blue: 0.647),
            ]
        )
        .ignoresSafeArea()
        .overlay(
            // a faint vignette for depth
            RadialGradient(
                colors: [.clear, Color.black.opacity(0.06)],
                center: .center, startRadius: 200, endRadius: 700
            )
            .ignoresSafeArea()
            .blendMode(.multiply)
        )
    }
}
