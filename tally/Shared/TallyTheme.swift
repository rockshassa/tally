import SwiftUI

/// The app's night palette (SPEC §9 visual identity, `design/ux-mockups.html`).
///
/// Two rules the whole product rides on:
/// * **amber is alcohol, aqua is not** — the same two hues in the counter, the
///   charts, the widget, and the watch;
/// * **dark-first** — the app renders on the night ground whatever the system
///   appearance is, so a bar at 11 pm never flashes white.
///
/// Constants rather than an asset catalog on purpose: the same literals are
/// quoted in the mockups and reused by later waves' charts, and a Swift constant
/// is the one place a diff shows up.
enum TallyColor {

    // MARK: Ground

    /// Page background.
    static let background = Color(hex: 0x141821)

    /// Deeper ground used behind the counter for a subtle vertical falloff.
    static let backgroundDeep = Color(hex: 0x0E1118)

    /// Fill for glass cards.
    static let glass = Color.white.opacity(0.055)

    /// Fill for the stronger glass used by interactive cards.
    static let glassStrong = Color.white.opacity(0.09)

    /// Hairline separators and card borders.
    static let line = Color.white.opacity(0.10)

    // MARK: Ink

    static let ink = Color(hex: 0xEEF0F5)
    static let inkSecondary = Color(hex: 0x9AA3B4)
    static let inkTertiary = Color(hex: 0x626C7E)

    // MARK: Drink identity

    /// Alcoholic. The validated chart amber.
    static let amber = Color(hex: 0xC07E1B)

    /// Amber for buttons and glows — brighter than the chart value.
    static let amberBright = Color(hex: 0xE8A53C)

    /// Non-alcoholic. The validated chart aqua.
    static let aqua = Color(hex: 0x2FA3BA)

    /// Aqua for buttons and glows.
    static let aquaBright = Color(hex: 0x4FC9DE)

    /// The identity colour for a drink type — the single lookup every surface
    /// should use rather than reaching for `amber`/`aqua` directly.
    static func tint(for type: TallyDrinkTint) -> Color {
        switch type {
        case .alcoholic: amber
        case .nonAlcoholic: aqua
        }
    }

    static func brightTint(for type: TallyDrinkTint) -> Color {
        switch type {
        case .alcoholic: amberBright
        case .nonAlcoholic: aquaBright
        }
    }
}

/// Which of the two identity colours applies. Mirrors `TallyKit.DrinkType`
/// without importing it, so the palette stays usable from anywhere.
enum TallyDrinkTint: Hashable, Sendable {
    case alcoholic
    case nonAlcoholic
}

// MARK: - Gradients

extension TallyColor {

    /// The counter's ground: deep at the top, slightly lifted at the bottom
    /// where the buttons live.
    static var pageGradient: LinearGradient {
        LinearGradient(
            colors: [backgroundDeep, background],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func buttonGradient(for type: TallyDrinkTint) -> LinearGradient {
        LinearGradient(
            colors: [brightTint(for: type), tint(for: type)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Metrics

/// Shared spacing/radius values so every screen in the app agrees.
enum TallyMetrics {
    static let screenPadding: CGFloat = 20
    static let cardRadius: CGFloat = 18
    static let primaryButtonHeight: CGFloat = 132
    static let secondaryButtonHeight: CGFloat = 72
    static let undoDiameter: CGFloat = 44
    static let undoDiameterSmall: CGFloat = 34
}

// MARK: - Hex helper

extension Color {
    /// `Color(hex: 0xC07E1B)` — the literals in `design/ux-mockups.html`.
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

// MARK: - Card styling

extension View {
    /// The glass card treatment used by the live Session card and the
    /// placeholder screens.
    func tallyGlassCard(strong: Bool = false) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: TallyMetrics.cardRadius, style: .continuous)
                    .fill(strong ? TallyColor.glassStrong : TallyColor.glass)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TallyMetrics.cardRadius, style: .continuous)
                    .stroke(TallyColor.line, lineWidth: 1)
            )
    }
}
