import Foundation
import SwiftData
import TallyKit
import WidgetKit

// MARK: - Day total

/// One day's drink counts — the unit the medium widget's 7-day sparkline plots.
struct DayTotal: Hashable, Identifiable, Sendable {

    /// Start of the day this bucket covers.
    let day: Date
    let alcoholic: Int
    let nonAlcoholic: Int

    var id: Date { day }
    var total: Int { alcoholic + nonAlcoholic }

    func count(of type: DrinkType) -> Int {
        type == .alcoholic ? alcoholic : nonAlcoholic
    }
}

// MARK: - Entry

struct TallyWidgetEntry: TimelineEntry {

    let date: Date
    let counts: TodayCounts

    /// Exactly `TallyWidgetData.historyLength` buckets, oldest first, the last
    /// being the day `date` falls in.
    let history: [DayTotal]

    /// `false` when the App Group store couldn't be opened. The widget still
    /// renders — zeroed, never crashed (SPEC §6: the gallery must always work).
    let isStoreAvailable: Bool

    var total: Int { counts.alcoholic + counts.nonAlcoholic }

    func count(of type: DrinkType) -> Int {
        type == .alcoholic ? counts.alcoholic : counts.nonAlcoholic
    }
}

extension TallyWidgetEntry {

    /// A zeroed entry ending on `date`. Used for the store-unavailable path and
    /// as the redacted placeholder.
    static func empty(date: Date = Date(), calendar: Calendar = .current) -> TallyWidgetEntry {
        TallyWidgetEntry(
            date: date,
            counts: .zero,
            history: TallyWidgetData.emptyHistory(endingOn: date, calendar: calendar),
            isStoreAvailable: false
        )
    }

    /// Gallery/preview sample — the mockups' "3 drinks, 2 NA".
    static func sample(date: Date = Date(), calendar: Calendar = .current) -> TallyWidgetEntry {
        let alcoholic = [2, 0, 4, 1, 5, 3, 3]
        let nonAlcoholic = [1, 0, 2, 0, 1, 2, 2]
        let days = TallyWidgetData.dayStarts(endingOn: date, calendar: calendar)
        return TallyWidgetEntry(
            date: date,
            counts: TodayCounts(alcoholic: 3, nonAlcoholic: 2),
            history: zip(days, zip(alcoholic, nonAlcoholic)).map {
                DayTotal(day: $0, alcoholic: $1.0, nonAlcoholic: $1.1)
            },
            isStoreAvailable: true
        )
    }
}

// MARK: - Loading

/// Reads the shared App Group store on behalf of the timeline provider.
///
/// Everything here is synchronous and failure-tolerant: a widget that throws is
/// a widget that shows an error card, and SPEC §6 wants the counter visible
/// even when the store is momentarily unreachable.
enum TallyWidgetData {

    /// Days plotted by the medium widget's sparkline.
    static let historyLength = 7

    // MARK: Day helpers

    static func dayStarts(endingOn date: Date, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: date)
        return (0..<historyLength).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
    }

    static func emptyHistory(endingOn date: Date, calendar: Calendar = .current) -> [DayTotal] {
        dayStarts(endingOn: date, calendar: calendar).map {
            DayTotal(day: $0, alcoholic: 0, nonAlcoholic: 0)
        }
    }

    // MARK: Entries

    /// The timeline the provider serves: one entry for now, and one for the
    /// stroke of midnight so the counts visibly reset on the day boundary even
    /// if the system is slow to run the scheduled refresh.
    ///
    /// Everything between those two is event-driven — `LogDrinkIntent` calls
    /// `WidgetCenter.reloadAllTimelines()` after every log, from any surface.
    static func timeline(now: Date = Date(), calendar: Calendar = .current) -> Timeline<TallyWidgetEntry> {
        let midnight = nextMidnight(after: now, calendar: calendar)
        let entries = load(at: [now, midnight], calendar: calendar)
        return Timeline(entries: entries, policy: .after(midnight))
    }

    static func entry(at date: Date = Date(), calendar: Calendar = .current) -> TallyWidgetEntry {
        load(at: [date], calendar: calendar)[0]
    }

    static func nextMidnight(after date: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: today) ?? date.addingTimeInterval(86_400)
    }

    // MARK: Store read

    /// One store round-trip covering every requested anchor date.
    ///
    /// - Returns: an entry per anchor, in the order given. Never throws — a
    ///   missing App Group entitlement or an unopenable store yields zeroed
    ///   entries flagged `isStoreAvailable == false`.
    private static func load(at anchors: [Date], calendar: Calendar = .current) -> [TallyWidgetEntry] {
        guard let earliest = anchors.min(), let latest = anchors.max() else { return [] }

        // Widest window any anchor can ask about: six days before the earliest
        // anchor's day through the end of the latest anchor's day.
        let windowStart = calendar.date(
            byAdding: .day,
            value: -(historyLength - 1),
            to: calendar.startOfDay(for: earliest)
        ) ?? earliest
        let windowEnd = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: latest)
        ) ?? latest

        let snapshots: [DrinkEventSnapshot]
        do {
            let context = ModelContext(try TallyRuntime.container())
            snapshots = try EventStore.events(from: windowStart, to: windowEnd, in: context)
                .map(\.snapshot)
        } catch {
            // Store unavailable (no entitlement, migration in flight, …).
            // Show zeros rather than failing the timeline (SPEC §6).
            return anchors.map { .empty(date: $0, calendar: calendar) }
        }

        var alcoholicByDay: [Date: Int] = [:]
        var nonAlcoholicByDay: [Date: Int] = [:]
        for snapshot in snapshots {
            let day = calendar.startOfDay(for: snapshot.timestamp)
            switch snapshot.type {
            case .alcoholic: alcoholicByDay[day, default: 0] += 1
            case .nonAlcoholic: nonAlcoholicByDay[day, default: 0] += 1
            }
        }

        return anchors.map { anchor in
            let history = dayStarts(endingOn: anchor, calendar: calendar).map { day in
                DayTotal(
                    day: day,
                    alcoholic: alcoholicByDay[day] ?? 0,
                    nonAlcoholic: nonAlcoholicByDay[day] ?? 0
                )
            }
            let today = history.last
            return TallyWidgetEntry(
                date: anchor,
                counts: TodayCounts(
                    alcoholic: today?.alcoholic ?? 0,
                    nonAlcoholic: today?.nonAlcoholic ?? 0
                ),
                history: history,
                isStoreAvailable: true
            )
        }
    }
}
