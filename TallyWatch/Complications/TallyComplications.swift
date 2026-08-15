//
//  TallyComplications.swift
//  Accessory-family complications + Smart Stack (SPEC §7).
//
//  ── INTEGRATOR NOTE (deviation) ────────────────────────────────────────────
//  Complications ship in a **watchOS widget-extension target**, and creating a
//  target means editing `project.pbxproj`, which this agent is not allowed to
//  touch. So the code lives here and compiles into the watch app target, where
//  it is type-checked and previewable but not yet installed as a complication.
//
//  To finish the wiring, an agent that may edit the project:
//
//    1. Add a watchOS Widget Extension target (`TallyWatchComplications`),
//       embedded in `TallyWatch.app`, linking `TallyKit`.
//    2. Move this file into that target's synchronized folder.
//    3. Mark `TallyWatchComplicationBundle` with `@main` — it is intentionally
//       left off here, because the watch app already has an `@main` and two in
//       one module will not compile.
//    4. In that bundle's `init`, call
//       `TallyRuntime.configure(eventSource: .watch, storeConfiguration: ...)`.
//       ⚠️ The extension is a **separate process with its own sandbox**, so the
//       watch app's `StoreConfiguration.local` store would be invisible to it.
//       Both must move to the shared App Group:
//           StoreConfiguration(appGroupIdentifier: TallyStore.appGroupIdentifier)
//       (`Entitlements/TallyWatch.entitlements` already grants it, and this
//       stays a watch-only store — App Groups do not cross devices.)
//  ───────────────────────────────────────────────────────────────────────────
//

#if canImport(WidgetKit)

import SwiftData
import SwiftUI
import TallyKit
import WidgetKit

// MARK: - Timeline

nonisolated struct TallyComplicationEntry: TimelineEntry {
    let date: Date
    let counts: TodayCounts
}

/// `nonisolated` because `TimelineProvider` is called off the main actor.
nonisolated struct TallyComplicationProvider: TimelineProvider {

    func placeholder(in context: Context) -> TallyComplicationEntry {
        TallyComplicationEntry(date: Date(), counts: TodayCounts(alcoholic: 3, nonAlcoholic: 2))
    }

    func getSnapshot(in context: Context, completion: @escaping (TallyComplicationEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TallyComplicationEntry>) -> Void) {
        // Counts only change when the user logs — and the app reloads timelines
        // itself on every log and undo. The one change that happens on its own
        // is midnight, when today's tally resets, so that is the only scheduled
        // refresh this needs.
        let calendar = Calendar.current
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
            ?? Date().addingTimeInterval(86_400)

        completion(Timeline(entries: [currentEntry()], policy: .after(startOfTomorrow)))
    }

    private func currentEntry() -> TallyComplicationEntry {
        guard let container = try? TallyRuntime.container() else {
            return TallyComplicationEntry(date: Date(), counts: .zero)
        }
        let context = ModelContext(container)
        let counts = (try? TodayCounts.load(in: context)) ?? .zero
        return TallyComplicationEntry(date: Date(), counts: counts)
    }
}

// MARK: - Views

struct TallyComplicationView: View {

    @Environment(\.widgetFamily) private var family

    let entry: TallyComplicationEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryInline:
            inline
        case .accessoryRectangular:
            rectangular
        default:
            #if os(watchOS)
            if family == .accessoryCorner {
                corner
            } else {
                circular
            }
            #else
            circular
            #endif
        }
    }

    /// Today's total, the one number worth a glance.
    private var circular: some View {
        VStack(spacing: -1) {
            Text("\(entry.counts.alcoholic)")
                .font(.system(size: 24, weight: .heavy))
                .monospacedDigit()
                .widgetAccentable()
            Text("DRINKS")
                .font(.system(size: 8, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(.secondary)
        }
    }

    private var inline: some View {
        Text("\(entry.counts.alcoholic) drinks · \(entry.counts.nonAlcoholic) NA")
            .monospacedDigit()
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("TALLY")
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
                .widgetAccentable()
            HStack(spacing: 10) {
                countPair(entry.counts.alcoholic, label: "Drinks")
                countPair(entry.counts.nonAlcoholic, label: "Non-alc")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    #if os(watchOS)
    /// Corner puts the number in the bezel and the label on the curve.
    private var corner: some View {
        Text("\(entry.counts.alcoholic)")
            .font(.system(size: 18, weight: .heavy))
            .monospacedDigit()
            .widgetLabel("Tally")
    }
    #endif

    private func countPair(_ value: Int, label: String) -> some View {
        HStack(spacing: 3) {
            Text("\(value)")
                .font(.system(size: 16, weight: .bold))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Widget

struct TallyTotalComplication: Widget {

    static let kind = "TallyTotalComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: TallyComplicationProvider()) { entry in
            TallyComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Tally")
        .description("Today's drinks at a glance. Tap to log.")
        .supportedFamilies(Self.families)
    }

    static var families: [WidgetFamily] {
        #if os(watchOS)
        [.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular]
        #else
        [.accessoryCircular, .accessoryInline, .accessoryRectangular]
        #endif
    }
}

/// Intentionally **not** `@main` — see the integrator note at the top of the
/// file. Adding `@main` here is the last step of moving this into its own
/// widget-extension target.
struct TallyWatchComplicationBundle: WidgetBundle {

    var body: some Widget {
        TallyTotalComplication()
    }
}

#endif
