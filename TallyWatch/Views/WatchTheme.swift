//
//  WatchTheme.swift
//  The night palette from design/ux-mockups.html, on the wrist.
//
//  The two-hue code is the whole visual language: **amber always means an
//  alcoholic drink, aqua always means a non-alcoholic one**, on every surface.
//  The watch inherits it unchanged so a glance reads the same as the phone.
//

import SwiftUI
import TallyKit

public enum WatchTheme {

    // MARK: Palette (hex values lifted verbatim from the mockups)

    public static let ink = Color(hex: 0xEEF0F5)
    public static let inkSecondary = Color(hex: 0x9AA3B4)
    public static let inkTertiary = Color(hex: 0x626C7E)

    public static let amber = Color(hex: 0xE8A53C)
    public static let aqua = Color(hex: 0x4FC9DE)

    /// `radial-gradient(120% 80% at 50% 0%, #1b2130, #0b0e15 70%)` from the
    /// mockup's watch screen — a drink counter lives in bars, so it commits to
    /// dark glass rather than following a light appearance.
    public static var background: some View {
        RadialGradient(
            colors: [Color(hex: 0x1B2130), Color(hex: 0x0B0E15)],
            center: .top,
            startRadius: 0,
            endRadius: 220
        )
        .ignoresSafeArea()
    }

    // MARK: Per-type styling

    public static func tint(for type: DrinkType) -> Color {
        type == .alcoholic ? amber : aqua
    }

    /// Row fill opacities, straight from `.watch-btn.amber` / `.watch-btn.aqua`.
    public static func rowFillOpacity(for type: DrinkType) -> Double {
        type == .alcoholic ? 0.16 : 0.13
    }

    public static func rowStrokeOpacity(for type: DrinkType) -> Double {
        type == .alcoholic ? 0.35 : 0.30
    }

    public static func caption(for type: DrinkType) -> String {
        type == .alcoholic ? "Drinks" : "Non-alc"
    }

    public static let rowCornerRadius: CGFloat = 18
}

// MARK: - Hex convenience

public extension Color {

    /// Keeps the palette literals identical to the mockup's CSS, so a design
    /// change is a one-token diff instead of a float conversion.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
