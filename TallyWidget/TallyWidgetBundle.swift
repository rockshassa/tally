import SwiftUI
import TallyKit
import WidgetKit

/// Wave 0 placeholder so the target is complete and links.
///
/// The Wave 1 `widget` agent owns this directory and fills in SPEC §6: small
/// (counts + two interactive buttons), medium (plus a 7-day sparkline), and lock
/// screen accessory families. `LogDrinkIntent` from TallyKit is already the
/// button intent — nothing here needs a new one.
@main
struct TallyWidgetBundle: WidgetBundle {

    init() {
        // Everything logged from this process is a widget event (SPEC §6), and
        // reconciliation on next app open keys off exactly that.
        TallyRuntime.configure(eventSource: .widget)
    }

    var body: some Widget {
        TallyWidget()
    }
}

struct TallyWidgetEntry: TimelineEntry {
    let date: Date
    let counts: TodayCounts

    static let placeholder = TallyWidgetEntry(date: .now, counts: .zero)
}

struct TallyWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> TallyWidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (TallyWidgetEntry) -> Void) {
        completion(.placeholder)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TallyWidgetEntry>) -> Void) {
        completion(Timeline(entries: [.placeholder], policy: .after(Date.now.addingTimeInterval(900))))
    }
}

struct TallyWidgetEntryView: View {

    let entry: TallyWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tally")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(entry.counts.alcoholic)")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
            Text("\(entry.counts.nonAlcoholic) NA")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TallyWidget: Widget {

    let kind = "TallyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TallyWidgetProvider()) { entry in
            TallyWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Tally")
        .description("Today's drinks, one tap away.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
