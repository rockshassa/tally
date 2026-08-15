import SwiftUI
import TallyKit

// The widget's slice of the app's night palette (design/ux-mockups.html).
//
// The whole design rests on one invariant: **amber always means an alcoholic
// drink, aqua always means a non-alcoholic one**. Every count, button, and
// sparkline series below inherits its colour from that rule and nothing else.

extension Color {
    /// `Color(tallyHex: 0xe8a53c)` — keeps the palette readable against the
    /// hex values in the mockups instead of a wall of decimal components.
    init(tallyHex hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum TallyPalette {

    // Ink
    static let ink = Color(tallyHex: 0xEE_F0F5)
    static let ink2 = Color(tallyHex: 0x9A_A3B4)
    static let ink3 = Color(tallyHex: 0x62_6C7E)

    // Alcoholic — amber
    static let amber = Color(tallyHex: 0xC0_7E1B)
    static let amberBright = Color(tallyHex: 0xE8_A53C)

    // Non-alcoholic — aqua
    static let aqua = Color(tallyHex: 0x2F_A3BA)
    static let aquaBright = Color(tallyHex: 0x4F_C9DE)

    // Ground
    static let groundHighlight = Color(tallyHex: 0x23_2C3E)
    static let ground = Color(tallyHex: 0x12_161F)
    static let hairline = Color.white.opacity(0.10)

    /// The dark glass the mockups' widgets sit on.
    static var widgetGround: some ShapeStyle {
        RadialGradient(
            colors: [groundHighlight, ground],
            center: UnitPoint(x: 0.2, y: 0),
            startRadius: 0,
            endRadius: 260
        )
    }
}

extension DrinkType {

    /// The tint that carries this drink type everywhere in the UI.
    var tint: Color {
        switch self {
        case .alcoholic: TallyPalette.amberBright
        case .nonAlcoholic: TallyPalette.aquaBright
        }
    }

    /// Chart-validated (slightly deeper) variant used for strokes and fills.
    var chartTint: Color {
        switch self {
        case .alcoholic: TallyPalette.amber
        case .nonAlcoholic: TallyPalette.aqua
        }
    }

    /// Label under the count, per the mockups: "DRINKS" / "NA".
    var countLabel: String {
        switch self {
        case .alcoholic: "Drinks"
        case .nonAlcoholic: "NA"
        }
    }

    /// Spoken by VoiceOver on the widget's log buttons.
    var logAccessibilityLabel: String {
        switch self {
        case .alcoholic: "Log an alcoholic drink"
        case .nonAlcoholic: "Log a non-alcoholic drink"
        }
    }
}
