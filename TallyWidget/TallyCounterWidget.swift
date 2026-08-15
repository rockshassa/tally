import AppIntents
import SwiftUI
import TallyKit
import WidgetKit

// MARK: - Widget

/// Home-screen widget: today's counts plus two interactive log buttons, and on
/// the medium family a 7-day sparkline (SPEC §6).
///
/// The buttons run `LogDrinkIntent` in this extension's process, which
/// `TallyWidgetBundle` has stamped `source = .widget`. The write happens
/// immediately and *never* waits on a location fix — the app reconciles venues
/// for recent untagged widget events on next open.
struct TallyCounterWidget: Widget {

    static let kind = "TallyCounterWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TallyWidgetProvider()) { entry in
            TallyCounterWidgetView(entry: entry)
                .containerBackground(TallyPalette.widgetGround, for: .widget)
        }
        .configurationDisplayName("Tally")
        .description("Today's drinks, one tap away — logs without opening the app.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Root view

struct TallyCounterWidgetView: View {

    @Environment(\.widgetFamily) private var family

    let entry: TallyWidgetEntry

    var body: some View {
        Group {
            switch family {
            case .systemMedium:
                HStack(alignment: .top, spacing: 12) {
                    counterColumn
                        .frame(maxWidth: 132, alignment: .leading)
                    sparklineColumn
                }
            default:
                counterColumn
            }
        }
        .padding(14)
        .foregroundStyle(TallyPalette.ink)
    }

    /// Counts on top, the two log buttons pinned to the bottom — identical on
    /// small and on the medium family's left half.
    private var counterColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            CountsRow(entry: entry)
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                LogButton(drink: .alcoholic)
                LogButton(drink: .nonAlcoholic)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var sparklineColumn: some View {
        VStack(alignment: .leading, spacing: 3) {
            Spacer(minLength: 0)
            Text("Last 7 days")
                .font(.system(size: 8, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(TallyPalette.ink3)
            SparklineView(history: entry.history)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

// MARK: - Counts

private struct CountsRow: View {

    let entry: TallyWidgetEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CountColumn(drink: .alcoholic, count: entry.counts.alcoholic, isPrimary: true)
            CountColumn(drink: .nonAlcoholic, count: entry.counts.nonAlcoholic, isPrimary: false)
        }
        // Redacts the number while a button's intent is in flight, so the
        // widget reads as "working" instead of briefly stale.
        .invalidatableContent()
    }
}

private struct CountColumn: View {

    let drink: DrinkType
    let count: Int
    /// The alcoholic count is the headline; NA sits a step back in the hierarchy.
    let isPrimary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isPrimary ? TallyPalette.ink : TallyPalette.ink2)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            HStack(spacing: 3) {
                Circle()
                    .fill(drink.tint)
                    .frame(width: 6, height: 6)
                Text(drink.countLabel)
                    .font(.system(size: 8, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.5)
                    .foregroundStyle(TallyPalette.ink2)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(drink == .alcoholic ? "Alcoholic drinks today" : "Non-alcoholic drinks today")
        .accessibilityValue("\(count)")
    }
}

// MARK: - Interactive log button

/// One tap → one event. `LogDrinkIntent` writes and reloads timelines itself.
private struct LogButton: View {

    let drink: DrinkType

    var body: some View {
        Button(intent: LogDrinkIntent(drink: drink)) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(drink.tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(drink.tint.opacity(0.18), in: .rect(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(drink.tint.opacity(0.35), lineWidth: 1)
                )
                .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(drink.logAccessibilityLabel)
        .accessibilityHint("Saves immediately without opening Tally")
    }
}

// MARK: - Gallery previews

#Preview("Small", as: .systemSmall) {
    TallyCounterWidget()
} timeline: {
    TallyWidgetEntry.sample()
    TallyWidgetEntry.empty()
}

#Preview("Medium", as: .systemMedium) {
    TallyCounterWidget()
} timeline: {
    TallyWidgetEntry.sample()
    TallyWidgetEntry.empty()
}
