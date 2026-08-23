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

    /// SPEC §4's modeled suppression curve, or `nil` — which is the answer
    /// whenever recovery context is off, the store is unreachable, or there is
    /// simply nothing to report. Secondary to the counts by construction: it
    /// only ever occupies space the buttons don't need.
    var suppression: SuppressionSnapshot? = nil

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

    /// `sample()` with the recovery layer showing — for the SwiftUI previews
    /// only. The gallery sample deliberately leaves it off: recovery context is
    /// opt-in (SPEC §4), and a gallery card advertising it would be a lie about
    /// what the widget does for the person looking at it.
    static func recoverySample(date: Date = Date(), calendar: Calendar = .current) -> TallyWidgetEntry {
        var entry = sample(date: date, calendar: calendar)
        let evening = (0..<4).map {
            DrinkEventSnapshot(
                type: .alcoholic,
                timestamp: date.addingTimeInterval(TimeInterval(-3600 * (2 + $0)))
            )
        }
        entry.suppression = SuppressionSnapshot.make(now: date, events: evening)
        return entry
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

    /// How far ahead the suppression curve is pre-rendered, and how finely.
    static let suppressionHorizon = 12
    static let suppressionStride: TimeInterval = 3600

    /// The timeline the provider serves: one entry for now, and one for the
    /// stroke of midnight so the counts visibly reset on the day boundary even
    /// if the system is slow to run the scheduled refresh.
    ///
    /// Everything between those two is event-driven — `LogDrinkIntent` calls
    /// `WidgetCenter.reloadAllTimelines()` after every log, from any surface.
    ///
    /// With recovery context on (SPEC §4) that is not enough: the modeled curve
    /// moves on its own, peaking hours after the last drink, so a card left
    /// untouched until the next log would quietly go stale — and a stale
    /// "peaks ~2 a.m." at 4 a.m. is precisely the dishonesty §4 forbids. So we
    /// add an hourly entry across the next 12 h whenever there is a curve to
    /// show. They cost one store read, not one refresh each: the events are
    /// already local and the model is pure, so every hour is rendered up front.
    static func timeline(now: Date = Date(), calendar: Calendar = .current) -> Timeline<TallyWidgetEntry> {
        let midnight = nextMidnight(after: now, calendar: calendar)
        let horizon = now.addingTimeInterval(suppressionStride * Double(suppressionHorizon))

        guard let snapshots = fetch(from: now, to: max(midnight, horizon), calendar: calendar) else {
            let entries = [now, midnight].map { TallyWidgetEntry.empty(date: $0, calendar: calendar) }
            return Timeline(entries: entries, policy: .after(midnight))
        }

        var anchors = [now, midnight]
        if RecoveryContext.isEnabled(), SuppressionSnapshot.make(now: now, events: snapshots) != nil {
            anchors += (1...suppressionHorizon).map {
                now.addingTimeInterval(suppressionStride * Double($0))
            }
        }

        let entries = build(at: dedupe(anchors), snapshots: snapshots, calendar: calendar)
        return Timeline(entries: entries, policy: .after(entries.last?.date ?? midnight))
    }

    static func entry(at date: Date = Date(), calendar: Calendar = .current) -> TallyWidgetEntry {
        load(at: [date], calendar: calendar)[0]
    }

    /// Sorted, with anchors closer together than a minute collapsed — WidgetKit
    /// wants a strictly increasing timeline.
    private static func dedupe(_ anchors: [Date]) -> [Date] {
        anchors.sorted().reduce(into: [Date]()) { kept, anchor in
            guard let last = kept.last else { return kept.append(anchor) }
            if anchor.timeIntervalSince(last) >= 60 { kept.append(anchor) }
        }
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
        guard let snapshots = fetch(from: earliest, to: latest, calendar: calendar) else {
            return anchors.map { .empty(date: $0, calendar: calendar) }
        }
        return build(at: anchors, snapshots: snapshots, calendar: calendar)
    }

    /// The one store round-trip, covering every anchor between `earliest` and
    /// `latest`. `nil` means the store was unreachable — a missing App Group
    /// entitlement, a migration in flight — which SPEC §6 answers with zeros
    /// rather than a failed timeline.
    private static func fetch(
        from earliest: Date,
        to latest: Date,
        calendar: Calendar = .current
    ) -> [DrinkEventSnapshot]? {
        // Widest window any anchor can ask about: six days before the earliest
        // anchor's day through the end of the latest anchor's day. That also
        // covers the ~60 h of history the suppression model can still feel.
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

        do {
            let context = ModelContext(try TallyRuntime.container())
            return try EventStore.events(from: windowStart, to: windowEnd, in: context).map(\.snapshot)
        } catch {
            return nil
        }
    }

    /// Turns one fetch into one entry per anchor, in the order given.
    private static func build(
        at anchors: [Date],
        snapshots: [DrinkEventSnapshot],
        calendar: Calendar = .current
    ) -> [TallyWidgetEntry] {
        var alcoholicByDay: [Date: Int] = [:]
        var nonAlcoholicByDay: [Date: Int] = [:]
        for snapshot in snapshots {
            let day = calendar.startOfDay(for: snapshot.timestamp)
            switch snapshot.type {
            case .alcoholic: alcoholicByDay[day, default: 0] += 1
            case .nonAlcoholic: nonAlcoholicByDay[day, default: 0] += 1
            }
        }

        // SPEC §4: off by default, and asked once rather than once per anchor.
        let isRecoveryEnabled = RecoveryContext.isEnabled()

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
                isStoreAvailable: true,
                suppression: isRecoveryEnabled
                    ? SuppressionSnapshot.make(now: anchor, events: snapshots)
                    : nil
            )
        }
    }
}
