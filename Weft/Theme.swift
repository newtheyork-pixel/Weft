//
//  Theme.swift
//  Weft design system — palette, type scale, spacing.
//  Mirrors the Electron app's warm-navy identity so the native app reads as
//  the same product.
//

import SwiftUI

enum Theme {

    // MARK: Palette (warm navy + cream)
    static let ink         = Color(red: 0.102, green: 0.153, blue: 0.267) // #1a2744 deep ink
    static let inkSoft     = Color(red: 0.133, green: 0.125, blue: 0.110) // #22201c body text
    static let accent      = Color(red: 0.137, green: 0.322, blue: 0.486) // #23527c navy accent
    static let accentHover = Color(red: 0.184, green: 0.400, blue: 0.600) // #2f6699
    static let accentSoft  = Color(red: 0.290, green: 0.435, blue: 0.647) // #4a6fa5
    static let gold        = Color(red: 0.722, green: 0.525, blue: 0.306) // #b8864e
    static let good        = Color(red: 0.016, green: 0.471, blue: 0.341) // #047857
    static let warn        = Color(red: 0.706, green: 0.325, blue: 0.035) // #b45309
    static let bad         = Color(red: 0.863, green: 0.149, blue: 0.149) // #dc2626
    static let muted       = Color(red: 0.353, green: 0.333, blue: 0.314) // #5a5550
    static let muted2      = Color(red: 0.482, green: 0.439, blue: 0.400) // #7b7066

    // MARK: Type
    /// Editorial serif (New York) for the brand + headlines.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    /// Default sans (SF Pro) for everything else.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    // MARK: Spacing (8pt rhythm)
    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 44
    }

    // MARK: Radii
    enum Radius {
        static let sm: CGFloat = 10
        static let md: CGFloat = 14
        static let lg: CGFloat = 20
        static let xl: CGFloat = 26
    }
}
