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
    ///
    /// Four drinks across the last evening: the episode is still running, so
    /// the curve carries a Now rule and the caption forecasts a return.
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

    /// The completed-episode counterpart: three compressed drinks two nights
    /// ago, whose modeled return is already behind `date` but still inside the
    /// 24-hour retention window. No Now rule, and a "Returned ~…" caption.
    static func completedRecoverySample(
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> TallyWidgetEntry {
        var entry = sample(date: date, calendar: calendar)
        let twoNightsAgo = (0..<3).map {
            DrinkEventSnapshot(
                type: .alcoholic,
                timestamp: date.addingTimeInterval(-48 * 3600 + TimeInterval(1800 * $0))
            )
        }
        entry.suppression = SuppressionSnapshot.make(now: date, events: twoNightsAgo)
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

    /// How finely the suppression curve is pre-rendered, and the ceiling on how
    /// many entries one timeline may hold.
    ///
    /// The stride is hourly because the caption's times are hour-rounded: a
    /// finer grid would spend entries repainting text that has not changed.
    /// The cap is WidgetKit hygiene — 48 hourly entries is two days of
    /// pre-rendered curve, which is more than any refresh budget will outlive.
    static let suppressionStride: TimeInterval = 3600
    static let entryLimit = 48

    /// The timeline the provider serves: one entry for now, one for the stroke
    /// of midnight so the counts visibly reset on the day boundary even if the
    /// system is slow to run the scheduled refresh, and — with recovery context
    /// on — an hourly entry from now until the episode stops being shown.
    ///
    /// Everything between those is event-driven: `LogDrinkIntent` calls
    /// `WidgetCenter.reloadAllTimelines()` after every log, from any surface.
    ///
    /// The hourly run is what the modeled curve needs and the counts do not.
    /// The curve moves on its own, peaking hours after the last drink and
    /// crossing baseline hours after that, so a card left untouched until the
    /// next log would quietly go stale — and a stale "baseline ~2 a.m." at
    /// 4 a.m. is precisely the dishonesty SPEC §4 forbids. Entries cost one
    /// store read between them, not one refresh each: the events are already
    /// local and the model is pure, so every hour is rendered up front.
    static func timeline(now: Date = Date(), calendar: Calendar = .current) -> Timeline<TallyWidgetEntry> {
        let midnight = nextMidnight(after: now, calendar: calendar)
        // The furthest any anchor can reach, since no timeline may exceed
        // `entryLimit` hourly steps. Fixing the far edge up front is what keeps
        // this to one store round-trip: the episode that decides the real end
        // is not known until after the read.
        let horizon = now.addingTimeInterval(suppressionStride * Double(entryLimit))

        guard let fetched = fetch(from: now, to: max(midnight, horizon), calendar: calendar) else {
            let entries = [now, midnight].map { TallyWidgetEntry.empty(date: $0, calendar: calendar) }
            return Timeline(entries: entries, policy: .after(midnight))
        }

        var anchors = [now, midnight]
        // SPEC §4: with recovery off, no suppression work happens at all — not
        // the timeline build, not the extra entries.
        if RecoveryContext.isEnabled(),
           let snapshot = SuppressionSnapshot.make(
               now: now,
               events: fetched.events,
               historyStart: fetched.historyStart
           ) {
            anchors += hourlyAnchors(from: now, until: snapshot.timeline.retainedUntil)
        }

        let entries = build(at: dedupe(anchors), fetched: fetched, calendar: calendar)
        return Timeline(entries: entries, policy: .after(entries.last?.date ?? midnight))
    }

    static func entry(at date: Date = Date(), calendar: Calendar = .current) -> TallyWidgetEntry {
        load(at: [date], calendar: calendar)[0]
    }

    /// Hourly anchors covering `now` (exclusive) through `end`, bounded by
    /// `entryLimit` so a long retention window cannot ask for a thousand
    /// entries.
    static func hourlyAnchors(from now: Date, until end: Date) -> [Date] {
        var anchors: [Date] = []
        var cursor = now.addingTimeInterval(suppressionStride)
        while cursor <= end, anchors.count < entryLimit {
            anchors.append(cursor)
            cursor = cursor.addingTimeInterval(suppressionStride)
        }
        return anchors
    }

    /// Sorted, with anchors closer together than a minute collapsed — WidgetKit
    /// wants a strictly increasing timeline — and capped at `entryLimit`.
    private static func dedupe(_ anchors: [Date]) -> [Date] {
        let kept = anchors.sorted().reduce(into: [Date]()) { kept, anchor in
            guard let last = kept.last else { return kept.append(anchor) }
            if anchor.timeIntervalSince(last) >= 60 { kept.append(anchor) }
        }
        return Array(kept.prefix(entryLimit))
    }

    static func nextMidnight(after date: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: today) ?? date.addingTimeInterval(86_400)
    }

    // MARK: Store read

    /// How far back the suppression snapshot needs to see.
    ///
    /// Far more than the sparkline's week, and for a different reason: an
    /// episode is bounded by the last *return to baseline*, not by a fixed
    /// window, so finding its true first drink means reading back past however
    /// long the person has been drinking without one. Thirty days is the
    /// practical ceiling; beyond it `isHistoryComplete` goes false and the
    /// surfaces say "available history" instead of claiming a first drink.
    static let suppressionHistory: TimeInterval = 30 * 86_400

    /// One store read, plus the window start it used — which the suppression
    /// builder needs verbatim to answer `isHistoryComplete` honestly.
    struct Fetched {
        let events: [DrinkEventSnapshot]
        let historyStart: Date
    }

    /// One store round-trip covering every requested anchor date.
    ///
    /// - Returns: an entry per anchor, in the order given. Never throws — a
    ///   missing App Group entitlement or an unopenable store yields zeroed
    ///   entries flagged `isStoreAvailable == false`.
    private static func load(at anchors: [Date], calendar: Calendar = .current) -> [TallyWidgetEntry] {
        guard let earliest = anchors.min(), let latest = anchors.max() else { return [] }
        guard let fetched = fetch(from: earliest, to: latest, calendar: calendar) else {
            return anchors.map { .empty(date: $0, calendar: calendar) }
        }
        return build(at: anchors, fetched: fetched, calendar: calendar)
    }

    /// The window start one fetch has to reach back to: the wider of the two
    /// things the widget draws. Both series come out of the same read — the
    /// sparkline slices its seven days out of it, the curve uses all of it.
    static func historyStart(for earliest: Date, calendar: Calendar = .current) -> Date {
        let sparkline = calendar.date(
            byAdding: .day,
            value: -(historyLength - 1),
            to: calendar.startOfDay(for: earliest)
        ) ?? earliest
        return min(sparkline, earliest.addingTimeInterval(-suppressionHistory))
    }

    /// The one store round-trip, covering every anchor between `earliest` and
    /// `latest`. `nil` means the store was unreachable — a missing App Group
    /// entitlement, a migration in flight — which SPEC §6 answers with zeros
    /// rather than a failed timeline.
    private static func fetch(
        from earliest: Date,
        to latest: Date,
        calendar: Calendar = .current
    ) -> Fetched? {
        let windowStart = historyStart(for: earliest, calendar: calendar)
        let windowEnd = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: latest)
        ) ?? latest

        do {
            let context = ModelContext(try TallyRuntime.container())
            let events = try EventStore.events(from: windowStart, to: windowEnd, in: context)
            return Fetched(events: events.map(\.snapshot), historyStart: windowStart)
        } catch {
            return nil
        }
    }

    /// Turns one fetch into one entry per anchor, in the order given.
    private static func build(
        at anchors: [Date],
        fetched: Fetched,
        calendar: Calendar = .current
    ) -> [TallyWidgetEntry] {
        var alcoholicByDay: [Date: Int] = [:]
        var nonAlcoholicByDay: [Date: Int] = [:]
        for snapshot in fetched.events {
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
                    ? SuppressionSnapshot.make(
                        now: anchor,
                        events: fetched.events,
                        historyStart: fetched.historyStart
                    )
                    : nil
            )
        }
    }
}
