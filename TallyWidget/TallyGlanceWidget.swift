import SwiftUI
import TallyKit
import WidgetKit

// MARK: - Widget

/// Lock-screen widget: today's count at a glance, tap opens the app (SPEC §6).
///
/// Deliberately *not* interactive. Accessory families render vibrant monochrome,
/// so a "+1" here would be an unlabelled grey pill on the lock screen with no
/// way to tell the two drink types apart — the two-hue code that makes the home
/// screen buttons unambiguous doesn't survive the rendering mode. Logging from
/// the lock screen is Bar Radar's notification action (SPEC §2 · §5).
///
/// No `widgetURL` on purpose: with none set, a tap launches the containing app,
/// which is exactly the required behaviour and doesn't depend on the app
/// registering a URL scheme.
struct TallyGlanceWidget: Widget {

    static let kind = "TallyGlanceWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TallyWidgetProvider()) { entry in
            TallyGlanceWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Tally Count")
        .description("Today's drink count on the Lock Screen. Tap to open Tally.")
        .supportedFamilies([.accessoryCircular, .accessoryInline])
    }
}

// MARK: - Root view

struct TallyGlanceWidgetView: View {

    @Environment(\.widgetFamily) private var family

    let entry: TallyWidgetEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            // Inline is a single line of system-styled text — no colour, no layout.
            Text(entry.inlineSummary)
                .accessibilityLabel(entry.spokenSummary)
        default:
            circular
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -2) {
                Text("\(entry.total)")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(entry.total == 1 ? "drink" : "drinks")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(2)
        }
        .widgetAccentable()
        .accessibilityElement()
        .accessibilityLabel("Drinks today")
        .accessibilityValue(entry.spokenSummary)
    }
}

// MARK: - Summaries

extension TallyWidgetEntry {

    /// "3 drinks · 2 NA" — the lock screen's inline line (SPEC §6).
    var inlineSummary: String {
        let drinks = counts.alcoholic == 1 ? "1 drink" : "\(counts.alcoholic) drinks"
        return "\(drinks) · \(counts.nonAlcoholic) NA"
    }

    /// Spelled out for VoiceOver, where "NA" reads as two letters.
    var spokenSummary: String {
        let drinks = counts.alcoholic == 1 ? "1 alcoholic drink" : "\(counts.alcoholic) alcoholic drinks"
        return "\(drinks), \(counts.nonAlcoholic) non-alcoholic"
    }
}

// MARK: - Gallery previews

#Preview("Circular", as: .accessoryCircular) {
    TallyGlanceWidget()
} timeline: {
    TallyWidgetEntry.sample()
    TallyWidgetEntry.empty()
}

#Preview("Inline", as: .accessoryInline) {
    TallyGlanceWidget()
} timeline: {
    TallyWidgetEntry.sample()
    TallyWidgetEntry.empty()
}
