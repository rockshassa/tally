import SwiftUI

// The Trends tab's shared furniture: the glass card every chart sits in, the
// segmented control, the legend, and the tiles. Kept in one file so the screen
// reads as a list of sections rather than a pile of view modifiers.

// MARK: - Accessibility identifiers

/// Identifiers `tallyUITests/TrendsUITests.swift` drives.
///
/// These live here rather than in `Shared/AccessibilityIdentifiers.swift`
/// because that file belongs to the tab shell; Wave 2 agents add their own
/// namespace instead of editing a file three streams share.
enum TrendsA11y {

    static let screen = "trends.screen"
    static let empty = "trends.empty"

    static let insightsSlot = "trends.insightsSlot"

    static let granularityPicker = "trends.granularityPicker"
    static func granularityOption(_ raw: String) -> String { "trends.granularity.\(raw)" }

    static let drinksChart = "trends.drinksChart"
    static let statTiles = "trends.statTiles"
    static let ratioChart = "trends.ratioChart"
    static let venueChart = "trends.venueChart"
    static let heatmap = "trends.heatmap"
    static let sessionStats = "trends.sessionStats"

    enum ShareCard {
        static let button = "shareCard.button"
        static let sheet = "shareCard.sheet"
        static let card = "shareCard.card"
        static let shareLink = "shareCard.shareLink"
        static let done = "shareCard.doneButton"
    }
}

// MARK: - Card

/// One section of the Trends tab: a title, a quiet subtitle, and the content —
/// the mockups' `.glass .chart-card`.
struct TrendsCard<Content: View>: View {

    let title: String
    var subtitle: String?
    let identifier: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(TallyColor.ink)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(TallyColor.inkTertiary)
                }
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .tallyGlassCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Segmented control

/// Day / Week / Month (SPEC §4). Hand-rolled rather than `.pickerStyle(.segmented)`
/// so it wears the mockups' glass instead of the system chrome — and so each
/// option carries its own identifier for the UI suite.
struct TrendsGranularityPicker: View {

    @Binding var selection: TrendsGranularity

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TrendsGranularity.allCases) { option in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = option }
                } label: {
                    Text(option.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(option == selection ? TallyColor.ink : TallyColor.inkSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(option == selection ? TallyColor.glassStrong : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(TrendsA11y.granularityOption(option.rawValue))
                .accessibilityLabel("\(option.title) buckets")
                .accessibilityAddTraits(option == selection ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(TallyColor.line, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(TrendsA11y.granularityPicker)
    }
}

// MARK: - Legend

/// SPEC §4 needs the two series named. The rule the whole app rides on is that
/// amber is alcohol and aqua is not, so the legend is fixed copy, not a
/// generated colour scale.
struct TrendsLegend: View {

    var averageLabel: String?

    var body: some View {
        HStack(spacing: 12) {
            item(color: TallyColor.amber, label: "Alcoholic")
            item(color: TallyColor.aqua, label: "Non-alc")

            if let averageLabel {
                HStack(spacing: 5) {
                    Capsule()
                        .fill(TallyColor.inkSecondary)
                        .frame(width: 14, height: 2)
                    Text(averageLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(TallyColor.inkSecondary)
                }
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Legend: amber is alcoholic, aqua is non-alcoholic\(averageLabel.map { ", the neutral line is the \($0)" } ?? "")")
    }

    private func item(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(TallyColor.inkSecondary)
        }
    }
}

// MARK: - Stat tile

/// The mockups' `.stat-tile`: a small caps key, a tabular number, and a delta
/// line where aqua means "down", which on this screen is good news.
struct TrendsStatTile: View {

    let key: String
    let value: String
    var unit: String?
    var delta: String?
    var deltaTone: Tone = .neutral
    var valueSize: CGFloat = 17

    enum Tone {
        /// Movement the user would call an improvement — fewer drinks, longer streak.
        case good
        /// Movement the other way. Stated, never scolded (SPEC §5 tone rules).
        case rising
        case neutral

        var color: Color {
            switch self {
            case .good: TallyColor.aquaBright
            case .rising: TallyColor.amberBright
            case .neutral: TallyColor.inkSecondary
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key)
                .font(.system(size: 8.5, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.7)
                .foregroundStyle(TallyColor.inkTertiary)

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: valueSize, weight: .bold).monospacedDigit())
                    .foregroundStyle(TallyColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                if let unit {
                    Text(unit)
                        .font(.system(size: 10))
                        .foregroundStyle(TallyColor.inkSecondary)
                }
            }

            Text(delta ?? " ")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(deltaTone.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .tallyGlassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(key)
        .accessibilityValue([value, unit, delta].compactMap { $0 }.joined(separator: " "))
    }
}

// MARK: - Key/value row

/// The Session-stats rows: a label on the left, a tabular number on the right.
struct TrendsStatRow: View {

    let label: String
    let value: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(TallyColor.ink)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(TallyColor.inkTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(TallyColor.ink)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([value, detail].compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: - Empty state

/// PLAN Gate 2: Trends must render on an empty store. It says so plainly rather
/// than drawing empty axes, which is the honest version of "no data yet".
struct TrendsEmptyState: View {

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(TallyColor.inkTertiary)

            Text("Nothing to chart yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(TallyColor.ink)

            Text("Log a drink and this fills in — days, venues, and the 7-day average, all computed from the log itself.")
                .font(.system(size: 12.5))
                .multilineTextAlignment(.center)
                .foregroundStyle(TallyColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(26)
        .tallyGlassCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(TrendsA11y.empty)
    }
}
