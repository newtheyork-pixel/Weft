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
                Color(red: 0.86, green: 0.89, blue: 0.94), Color(red: 0.93, green: 0.90, blue: 0.84), Color(red: 0.84, green: 0.88, blue: 0.94),
                Color(red: 0.82, green: 0.86, blue: 0.93), Color(red: 0.95, green: 0.95, blue: 0.97), Color(red: 0.91, green: 0.87, blue: 0.80),
                Color(red: 0.60, green: 0.70, blue: 0.85), Color(red: 0.66, green: 0.74, blue: 0.86), Color(red: 0.56, green: 0.67, blue: 0.83),
            ]
        )
        .ignoresSafeArea()
        .overlay(
            // a faint vignette for depth
            RadialGradient(
                colors: [.clear, Color.black.opacity(0.035)],
                center: .center, startRadius: 240, endRadius: 760
            )
            .ignoresSafeArea()
            .blendMode(.multiply)
        )
    }
}
