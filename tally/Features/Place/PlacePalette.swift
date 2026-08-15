import SwiftUI
import TallyKit

/// The app's night palette, fixed (design/ux-mockups.html).
///
/// "A drink counter lives in bars, so the UI commits to dark glass." Amber
/// always means an alcoholic drink; aqua always means a non-alcoholic one —
/// that two-hue code carries through every surface here.
public enum PlacePalette {

    public static let background = Color(red: 0.078, green: 0.094, blue: 0.129)      // #141821
    public static let backgroundDeep = Color(red: 0.055, green: 0.067, blue: 0.094)  // #0e1118

    public static let ink = Color(red: 0.933, green: 0.941, blue: 0.961)             // #eef0f5
    public static let ink2 = Color(red: 0.604, green: 0.639, blue: 0.706)            // #9aa3b4
    public static let ink3 = Color(red: 0.384, green: 0.424, blue: 0.494)            // #626c7e

    /// Validated chart amber / the brighter UI variant.
    public static let amber = Color(red: 0.753, green: 0.494, blue: 0.106)           // #c07e1b
    public static let amberBright = Color(red: 0.910, green: 0.647, blue: 0.235)     // #e8a53c

    /// Validated chart aqua / the brighter UI variant.
    public static let aqua = Color(red: 0.184, green: 0.639, blue: 0.729)            // #2fa3ba
    public static let aquaBright = Color(red: 0.310, green: 0.788, blue: 0.871)      // #4fc9de

    public static let glass = Color.white.opacity(0.055)
    public static let glassStrong = Color.white.opacity(0.09)
    public static let line = Color.white.opacity(0.10)

    /// The hue for a drink type. The only place this mapping is written down.
    public static func tint(for type: DrinkType) -> Color {
        type == .alcoholic ? amberBright : aquaBright
    }
}

// MARK: - Glass surfaces

/// The card treatment used by Session rows, the check-in sheet, and the
/// reconciliation prompt.
struct PlaceGlassCard: ViewModifier {

    var tint: Color?
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(PlacePalette.glass)
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(tint.opacity(0.10))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(tint?.opacity(0.28) ?? PlacePalette.line, lineWidth: 1)
                    }
            }
    }
}

extension View {

    func placeGlassCard(tint: Color? = nil, cornerRadius: CGFloat = 16) -> some View {
        modifier(PlaceGlassCard(tint: tint, cornerRadius: cornerRadius))
    }

    /// Night ground + forced dark rendering for system controls. Applied by the
    /// top-level views this feature owns, so they look right no matter which
    /// shell hosts them.
    func placeNightSurface() -> some View {
        self
            .background(PlacePalette.background.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
            .tint(PlacePalette.amberBright)
    }
}

// MARK: - Small shared pieces

/// The pill under a venue name: "Bar · 40 m away".
struct PlaceChip: View {

    var systemImage: String?
    var text: String
    var tint: Color = PlacePalette.ink2

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            }
            Text(text)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(PlacePalette.glassStrong))
        .overlay(Capsule().strokeBorder(PlacePalette.line, lineWidth: 1))
    }
}

/// The 8-point dot that encodes drink type everywhere in the app.
struct PlaceDrinkSwatch: View {

    var type: DrinkType
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(PlacePalette.tint(for: type))
            .frame(width: size, height: size)
    }
}
