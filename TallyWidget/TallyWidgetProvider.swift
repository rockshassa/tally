import Foundation
import WidgetKit

/// Serves every Tally widget family from the shared App Group store.
///
/// Refresh policy (SPEC §6):
/// - **Scheduled:** one reload just after midnight, because that is the only
///   moment the counts change without anybody tapping anything.
/// - **Event-driven:** `LogDrinkIntent` calls `WidgetCenter.reloadAllTimelines()`
///   at the end of every log, so a tap on the widget, in the app, or on the
///   watch refreshes the counts immediately without burning a refresh budget.
/// - **Pre-rendered:** with recovery context on (SPEC §4) the modeled curve
///   moves on its own, so `TallyWidgetData.timeline()` renders an hourly entry
///   ahead of time for as long as the episode is shown — inside one timeline,
///   on one store read, rather than one system reload per hour. The timeline
///   then expires on its last entry, and the next `getTimeline` re-reads.
struct TallyWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> TallyWidgetEntry {
        // Redacted in the gallery, so the sample's shape is what matters.
        .sample()
    }

    func getSnapshot(in context: Context, completion: @escaping (TallyWidgetEntry) -> Void) {
        // The widget gallery previews with `isPreview`; real data everywhere else.
        completion(context.isPreview ? .sample() : TallyWidgetData.entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TallyWidgetEntry>) -> Void) {
        completion(TallyWidgetData.timeline())
    }
}
