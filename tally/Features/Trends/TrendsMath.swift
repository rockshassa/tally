import Foundation
import TallyKit

// Everything the Trends tab plots, computed as pure functions over the event log
// (SPEC §1: derive, don't store — nothing on this screen is ever persisted).
//
// The math lives apart from the views on purpose: PLAN Gate 2 asks that "the
// 7-day average matches fixture math exactly", and a value-in/value-out function
// is the only version of that claim anyone can check.

// MARK: - Granularity

/// The segmented control on top of the drinks chart (SPEC §4).
public enum TrendsGranularity: String, CaseIterable, Identifiable, Sendable {

    case day
    case week
    case month

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .day: "Day"
        case .week: "Week"
        case .month: "Month"
        }
    }

    /// How many buckets the chart shows, counting back from today.
    var bucketCount: Int {
        switch self {
        case .day: 14
        case .week: 12
        case .month: 12
        }
    }

    /// The calendar unit one bar spans — also the `BarMark(unit:)` value, so bar
    /// widths and bucket boundaries can never disagree.
    var unit: Calendar.Component {
        switch self {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    var chartSubtitle: String {
        switch self {
        case .day: "Last 14 days · line is the 7-day average"
        case .week: "Last 12 weeks · 7-day average as a weekly rate"
        case .month: "Last 12 months · 7-day average as a monthly rate"
        }
    }

    var averageLegendLabel: String {
        switch self {
        case .day: "7-day avg"
        case .week: "7-day avg · weekly"
        case .month: "7-day avg · monthly"
        }
    }
}

// MARK: - Plotted values

/// One bar on the drinks chart: the two stacked counts plus the neutral overlay.
public struct TrendsBucket: Identifiable, Hashable, Sendable {

    public let start: Date

    /// Days of this bucket that have actually happened — the current week is
    /// three days long on a Wednesday, and the overlay is scaled by this so the
    /// line never towers over a partial bar.
    public let elapsedDays: Int

    public let alcoholic: Int
    public let nonAlcoholic: Int

    /// The trailing 7-day average of alcoholic drinks at this bucket's last
    /// elapsed day, scaled to `elapsedDays`. `nil` before the log begins.
    public let average: Double?

    public var id: Date { start }
    public var total: Int { alcoholic + nonAlcoholic }
}

/// A point on the NA : alcoholic ratio chart (SPEC §4), one per week.
public struct TrendsRatioPoint: Identifiable, Hashable, Sendable {

    public let weekStart: Date
    public let alcoholic: Int
    public let nonAlcoholic: Int

    /// NA per alcoholic drink. `nil` for a dry week — there is nothing to pace
    /// against, so plotting a number there would be an invention.
    public let ratio: Double?

    public var id: Date { weekStart }
}

/// One row of the by-venue breakdown (SPEC §4: "Home vs bars vs everything else").
public struct TrendsVenueRow: Identifiable, Hashable, Sendable {

    public let id: String
    public let name: String
    public let alcoholic: Int
    public let nonAlcoholic: Int
    public let sessionCount: Int

    /// True for the catch-all row of events that never got a venue.
    public let isUntagged: Bool

    public var total: Int { alcoholic + nonAlcoholic }
}

/// One tile of the hour × weekday heatmap (SPEC §4).
public struct TrendsHeatmapCell: Identifiable, Hashable, Sendable {

    /// 0 = the calendar's first weekday, so the grid respects the user's locale.
    public let weekdayIndex: Int
    public let hour: Int
    public let count: Int

    public var id: Int { weekdayIndex * 24 + hour }
}

/// A Session worth calling out by name (SPEC §4 Session stats).
public struct TrendsSessionHighlight: Identifiable, Hashable, Sendable {

    public let id: UUID
    public let venueName: String
    public let date: Date
    public let headline: String
    public let detail: String
}

/// SPEC §4: "average drinks per Session, Sessions per week, longest Session,
/// best-paced Session".
public struct TrendsSessionStats: Hashable, Sendable {

    public let sessionCount: Int
    public let averageAlcoholicPerSession: Double
    public let averageSpacersPerSession: Double
    public let sessionsPerWeek: Double
    public let longest: TrendsSessionHighlight?
    public let bestPaced: TrendsSessionHighlight?

    public static let empty = TrendsSessionStats(
        sessionCount: 0,
        averageAlcoholicPerSession: 0,
        averageSpacersPerSession: 0,
        sessionsPerWeek: 0,
        longest: nil,
        bestPaced: nil
    )
}

/// SPEC §4: "this week vs last week, longest dry streak, current streak, most
/// frequent venue" — plus the two headline numbers from the mockup.
public struct TrendsTileSet: Hashable, Sendable {

    public let thisWeekAlcoholic: Int
    public let lastWeekAlcoholic: Int

    /// Alcoholic drinks in the trailing 7 days ÷ 7 (SPEC §5's digest math).
    public let sevenDayAverage: Double
    public let previousSevenDayAverage: Double

    /// NA per alcoholic drink over the trailing 7 days. `nil` when dry.
    public let weekRatio: Double?
    public let ratioGoal: Double

    public let currentStreak: Int
    public let currentDryStreak: Int
    public let longestDryStreak: Int

    public let topVenueName: String?
    public let topVenueSessionCount: Int

    public var weekDelta: Int { thisWeekAlcoholic - lastWeekAlcoholic }
    public var averageDelta: Double { sevenDayAverage - previousSevenDayAverage }
    public var meetsRatioGoal: Bool {
        guard let weekRatio else { return true }
        return weekRatio >= ratioGoal
    }

    public static let empty = TrendsTileSet(
        thisWeekAlcoholic: 0,
        lastWeekAlcoholic: 0,
        sevenDayAverage: 0,
        previousSevenDayAverage: 0,
        weekRatio: nil,
        ratioGoal: 1,
        currentStreak: 0,
        currentDryStreak: 0,
        longestDryStreak: 0,
        topVenueName: nil,
        topVenueSessionCount: 0
    )
}

/// The recovery layer's weekly tile (SPEC §4: *"a weekly Trends tile (modeled
/// suppression-hours, this week vs last)"*).
///
/// Both figures are **modeled hours above baseline**, never a measurement — see
/// `TrendsMath.suppressionHours`. `nil` on `TrendsData` whenever recovery context
/// is off, which is how the tile disappears entirely rather than rendering zeros.
public struct TrendsSuppression: Hashable, Sendable {

    /// Modeled hours above baseline in the 7 × 24 h ending at `now`.
    public let thisWeekHours: Double

    /// The same window, shifted back a week.
    public let lastWeekHours: Double

    /// Negative means less modeled suppression than last week.
    public var deltaHours: Double { thisWeekHours - lastWeekHours }
}

// MARK: - The whole screen's data

/// One immutable snapshot of everything Trends draws. Rebuilt wholesale on every
/// reload — there is no incremental state to get out of step.
public struct TrendsData: Sendable {

    public let granularity: TrendsGranularity
    public let buckets: [TrendsBucket]
    public let ratioPoints: [TrendsRatioPoint]
    public let venueRows: [TrendsVenueRow]
    public let heatmap: [TrendsHeatmapCell]
    public let sessionStats: TrendsSessionStats
    public let tiles: TrendsTileSet

    /// SPEC §4's recovery context, or `nil` when the layer is off — off means
    /// "zero footprint", so the number is not computed, not stored, and not
    /// rendered.
    public let suppression: TrendsSuppression?

    /// Events in the whole log. Zero means the empty state; one means every
    /// chart still has to render something sane (PLAN Gate 2).
    public let eventCount: Int

    public var isEmpty: Bool { eventCount == 0 }

    public static func empty(granularity: TrendsGranularity = .day) -> TrendsData {
        TrendsData(
            granularity: granularity,
            buckets: [],
            ratioPoints: [],
            venueRows: [],
            heatmap: [],
            sessionStats: .empty,
            tiles: .empty,
            suppression: nil,
            eventCount: 0
        )
    }
}

// MARK: - Math

/// The pure half of Trends. No SwiftUI, no `ModelContext`, no clock of its own —
/// every entry point takes `now` so a fixture can pin it.
public enum TrendsMath {

    /// SPEC §4's headline signal, defined once so the chart overlay and the stat
    /// tile can never disagree: **alcoholic drinks in the 7 days ending on `day`,
    /// divided by 7.**
    ///
    /// Always ÷ 7, including at the very start of the log — the same arithmetic
    /// SPEC §5's weekly digest quotes ("12 drinks this week … 7-day avg 1.7/day").
    public static func sevenDayAverage(
        endingOn day: Date,
        dailyAlcoholic: [Date: Int],
        calendar: Calendar
    ) -> Double {
        Double(trailingSum(endingOn: day, days: 7, dailyCounts: dailyAlcoholic, calendar: calendar)) / 7.0
    }

    /// Sum of a daily series over the `days` days ending on `day`, inclusive.
    public static func trailingSum(
        endingOn day: Date,
        days: Int,
        dailyCounts: [Date: Int],
        calendar: Calendar
    ) -> Int {
        guard days > 0 else { return 0 }
        let last = calendar.startOfDay(for: day)
        var total = 0
        for offset in 0..<days {
            guard let cursor = calendar.date(byAdding: .day, value: -offset, to: last) else { break }
            total += dailyCounts[calendar.startOfDay(for: cursor)] ?? 0
        }
        return total
    }

    /// NA : alcoholic, or `nil` when there is no alcohol to pace against.
    public static func ratio(alcoholic: Int, nonAlcoholic: Int) -> Double? {
        guard alcoholic > 0 else { return nil }
        return Double(nonAlcoholic) / Double(alcoholic)
    }

    // MARK: Day maps

    /// Day-keyed counts covering *at least* `[earliest … now]`, built from
    /// `ScoringEngine.dailyStats` so empty days are present (SPEC §3: a day with
    /// nothing logged is a dry day, and it still counts).
    static func dailyMaps(
        days: [DayStats],
        calendar: Calendar
    ) -> (alcoholic: [Date: Int], nonAlcoholic: [Date: Int]) {
        var alcoholic: [Date: Int] = [:]
        var nonAlcoholic: [Date: Int] = [:]
        for day in days {
            let key = calendar.startOfDay(for: day.day)
            alcoholic[key, default: 0] += day.alcoholicCount
            nonAlcoholic[key, default: 0] += day.nonAlcoholicCount
        }
        return (alcoholic, nonAlcoholic)
    }

    // MARK: Bucketing

    /// The bucket starts the chart plots, oldest first, ending with the bucket
    /// containing `now`.
    static func bucketStarts(
        granularity: TrendsGranularity,
        now: Date,
        calendar: Calendar
    ) -> [Date] {
        let current = startOfBucket(containing: now, granularity: granularity, calendar: calendar)
        var starts: [Date] = []
        for offset in stride(from: granularity.bucketCount - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: bucketStride(granularity), value: -offset, to: current) else {
                continue
            }
            starts.append(start)
        }
        return starts.isEmpty ? [current] : starts
    }

    static func startOfBucket(
        containing date: Date,
        granularity: TrendsGranularity,
        calendar: Calendar
    ) -> Date {
        switch granularity {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        case .month:
            let components = calendar.dateComponents([.year, .month], from: date)
            return calendar.date(from: components) ?? calendar.startOfDay(for: date)
        }
    }

    private static func bucketStride(_ granularity: TrendsGranularity) -> Calendar.Component {
        switch granularity {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    /// Exclusive end of the bucket starting at `start`.
    static func endOfBucket(
        start: Date,
        granularity: TrendsGranularity,
        calendar: Calendar
    ) -> Date {
        calendar.date(byAdding: bucketStride(granularity), value: 1, to: start)
            ?? start.addingTimeInterval(86_400)
    }

    /// Builds every bar on the drinks chart, overlay included.
    static func buckets(
        granularity: TrendsGranularity,
        dailyAlcoholic: [Date: Int],
        dailyNonAlcoholic: [Date: Int],
        now: Date,
        calendar: Calendar
    ) -> [TrendsBucket] {

        let today = calendar.startOfDay(for: now)
        let logStart = Set(dailyAlcoholic.keys).union(dailyNonAlcoholic.keys).min()

        return bucketStarts(granularity: granularity, now: now, calendar: calendar).map { start in
            let end = endOfBucket(start: start, granularity: granularity, calendar: calendar)

            var alcoholic = 0
            var nonAlcoholic = 0
            var elapsed = 0
            var lastElapsedDay = start

            var cursor = calendar.startOfDay(for: start)
            while cursor < end {
                if cursor <= today {
                    elapsed += 1
                    lastElapsedDay = cursor
                    alcoholic += dailyAlcoholic[cursor] ?? 0
                    nonAlcoholic += dailyNonAlcoholic[cursor] ?? 0
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
                cursor = next
            }

            // A bucket entirely in the future (possible only for a retro-logged
            // clock skew) contributes no overlay rather than a phantom zero.
            let average: Double?
            if elapsed == 0 || (logStart.map { lastElapsedDay < $0 } ?? true) {
                average = nil
            } else {
                let perDay = sevenDayAverage(
                    endingOn: lastElapsedDay,
                    dailyAlcoholic: dailyAlcoholic,
                    calendar: calendar
                )
                average = perDay * Double(elapsed)
            }

            return TrendsBucket(
                start: start,
                elapsedDays: max(elapsed, 1),
                alcoholic: alcoholic,
                nonAlcoholic: nonAlcoholic,
                average: average
            )
        }
    }

    // MARK: Ratio series

    static func ratioPoints(
        weeks: Int,
        dailyAlcoholic: [Date: Int],
        dailyNonAlcoholic: [Date: Int],
        now: Date,
        calendar: Calendar
    ) -> [TrendsRatioPoint] {

        let today = calendar.startOfDay(for: now)
        let currentWeek = startOfBucket(containing: now, granularity: .week, calendar: calendar)

        return stride(from: weeks - 1, through: 0, by: -1).compactMap { offset -> TrendsRatioPoint? in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: currentWeek) else { return nil }
            let end = endOfBucket(start: start, granularity: .week, calendar: calendar)

            var alcoholic = 0
            var nonAlcoholic = 0
            var cursor = calendar.startOfDay(for: start)
            while cursor < end {
                if cursor <= today {
                    alcoholic += dailyAlcoholic[cursor] ?? 0
                    nonAlcoholic += dailyNonAlcoholic[cursor] ?? 0
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
                cursor = next
            }

            return TrendsRatioPoint(
                weekStart: start,
                alcoholic: alcoholic,
                nonAlcoholic: nonAlcoholic,
                ratio: ratio(alcoholic: alcoholic, nonAlcoholic: nonAlcoholic)
            )
        }
    }

    // MARK: Venue breakdown

    /// SPEC §4: where the drinks happen. Named venues by volume, then the honest
    /// "Untagged" remainder — never silently dropped, since an untagged night is
    /// a real night (SPEC §2 step 4).
    static func venueRows(
        events: [DrinkEventSnapshot],
        sessions: [DerivedSession],
        venues: [UUID: VenueSnapshot],
        limit: Int = 5
    ) -> [TrendsVenueRow] {

        var alcoholic: [UUID: Int] = [:]
        var nonAlcoholic: [UUID: Int] = [:]
        var untaggedAlcoholic = 0
        var untaggedNonAlcoholic = 0

        for event in events {
            if let id = event.venueID, venues[id] != nil {
                if event.type == .alcoholic { alcoholic[id, default: 0] += 1 } else { nonAlcoholic[id, default: 0] += 1 }
            } else {
                if event.type == .alcoholic { untaggedAlcoholic += 1 } else { untaggedNonAlcoholic += 1 }
            }
        }

        var sessionCounts: [UUID: Int] = [:]
        var untaggedSessions = 0
        for session in sessions {
            if let id = session.venueID, venues[id] != nil {
                sessionCounts[id, default: 0] += 1
            } else {
                untaggedSessions += 1
            }
        }

        var rows: [TrendsVenueRow] = venues.values.compactMap { venue in
            let a = alcoholic[venue.id] ?? 0
            let n = nonAlcoholic[venue.id] ?? 0
            guard a + n > 0 else { return nil }
            return TrendsVenueRow(
                id: venue.id.uuidString,
                name: venue.name.isEmpty ? "Unnamed place" : venue.name,
                alcoholic: a,
                nonAlcoholic: n,
                sessionCount: sessionCounts[venue.id] ?? 0,
                isUntagged: false
            )
        }

        rows.sort {
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        rows = Array(rows.prefix(limit))

        if untaggedAlcoholic + untaggedNonAlcoholic > 0 {
            rows.append(
                TrendsVenueRow(
                    id: "untagged",
                    name: "Untagged",
                    alcoholic: untaggedAlcoholic,
                    nonAlcoholic: untaggedNonAlcoholic,
                    sessionCount: untaggedSessions,
                    isUntagged: true
                )
            )
        }

        return rows
    }

    // MARK: Heatmap

    static func heatmap(
        events: [DrinkEventSnapshot],
        calendar: Calendar
    ) -> [TrendsHeatmapCell] {

        var counts: [Int: Int] = [:]
        for event in events where event.type == .alcoholic {
            let weekday = calendar.component(.weekday, from: event.timestamp)
            let row = ((weekday - calendar.firstWeekday) % 7 + 7) % 7
            let hour = calendar.component(.hour, from: event.timestamp)
            counts[row * 24 + hour, default: 0] += 1
        }

        return (0..<7).flatMap { row in
            (0..<24).map { hour in
                TrendsHeatmapCell(weekdayIndex: row, hour: hour, count: counts[row * 24 + hour] ?? 0)
            }
        }
    }

    static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        guard symbols.count == 7 else { return ["S", "M", "T", "W", "T", "F", "S"] }
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    // MARK: Session stats

    static func sessionStats(
        sessions: [DerivedSession],
        venues: [UUID: VenueSnapshot],
        windowDays: Int
    ) -> TrendsSessionStats {

        guard !sessions.isEmpty else { return .empty }

        let alcoholicTotal = sessions.reduce(0) { $0 + $1.alcoholicCount }
        let spacerTotal = sessions.reduce(0) { $0 + $1.spacerCount }
        let weeks = max(Double(windowDays) / 7.0, 1.0 / 7.0)

        func name(for session: DerivedSession) -> String {
            SessionFormatting.venueName(for: session, venues: venues)
        }

        let longest = sessions
            .filter { $0.duration > 0 }
            .max { lhs, rhs in
                if lhs.duration != rhs.duration { return lhs.duration < rhs.duration }
                return lhs.startedAt < rhs.startedAt
            }
            .map { session in
                TrendsSessionHighlight(
                    id: session.id,
                    venueName: name(for: session),
                    date: session.startedAt,
                    headline: SessionFormatting.duration(session.duration),
                    detail: "\(name(for: session)) · \(SessionFormatting.shortDate(session.startedAt))"
                )
            }

        // "Best-paced" is the highest spacer ratio (SPEC §4). Spacers only exist
        // between two alcoholic drinks, so a one-drink night is not in the running.
        let paced = sessions
            .filter { $0.alcoholicCount >= 2 && $0.spacerCount > 0 }
            .max { lhs, rhs in
                let l = Double(lhs.spacerCount) / Double(lhs.alcoholicCount)
                let r = Double(rhs.spacerCount) / Double(rhs.alcoholicCount)
                if l != r { return l < r }
                return lhs.startedAt < rhs.startedAt
            }
            .map { session in
                TrendsSessionHighlight(
                    id: session.id,
                    venueName: name(for: session),
                    date: session.startedAt,
                    headline: "\(session.spacerCount) / \(session.alcoholicCount)",
                    detail: "\(name(for: session)) · \(SessionFormatting.shortDate(session.startedAt))"
                )
            }

        return TrendsSessionStats(
            sessionCount: sessions.count,
            averageAlcoholicPerSession: Double(alcoholicTotal) / Double(sessions.count),
            averageSpacersPerSession: Double(spacerTotal) / Double(sessions.count),
            sessionsPerWeek: Double(sessions.count) / weeks,
            longest: longest,
            bestPaced: paced
        )
    }

    // MARK: Modeled suppression (SPEC §4 "Recovery context")

    /// How far back a drink can still push the curve above baseline. Past this,
    /// `FibrinolysisModel`'s exponential decay has taken even a heavily
    /// compressed night's pulses far under the baseline threshold, so drinks
    /// older than this are dropped before sampling — the integral is over a week,
    /// but the log behind it can be years long.
    static let suppressionLeadIn: TimeInterval = 72 * 3600

    /// **Modeled suppression-hours** over `[start, end)`: the time the
    /// `FibrinolysisModel` curve spends above its baseline threshold.
    ///
    /// Integrating the above-baseline stretch of the curve rather than the curve
    /// itself is what makes the answer quotable: SPEC §4 allows burden and
    /// duration only, and hours is the one unit a dimensionless index can
    /// honestly be reported in. Never a measurement — this is a population
    /// dose-response evaluated against the event log, and every surface that
    /// shows it says "modeled".
    ///
    /// Two details the caller does not have to think about:
    ///
    /// * **Drinks before the window still count inside it.** Saturday's last
    ///   drink peaks on Sunday morning — that lag is the entire point of the
    ///   model — so the sampler sees `suppressionLeadIn` of earlier drinks and
    ///   counts only the hours that land inside the window.
    /// * **Hours are clipped to the window.** A Sunday-night drink whose curve
    ///   runs into Monday contributes only its Sunday hours here, and the rest to
    ///   the next window. Consecutive windows therefore partition the timeline
    ///   with nothing double-counted and nothing lost.
    ///
    /// Sampling is `step`-spaced with linear interpolation across the baseline
    /// crossing, so the result is far finer than the step: at the 15-minute
    /// default the error on a single pulse is well under a minute.
    public static func suppressionHours(
        events: [DrinkEventSnapshot],
        from start: Date,
        to end: Date,
        model: FibrinolysisModel = FibrinolysisModel(),
        step: TimeInterval = 15 * 60
    ) -> Double {

        guard end > start, step > 0 else { return 0 }

        let windowEvents = events.filter {
            $0.type == .alcoholic
                && $0.timestamp < end
                && $0.timestamp >= start.addingTimeInterval(-suppressionLeadIn)
        }
        guard !windowEvents.isEmpty else { return 0 }

        let samples = model.curve(from: start, to: end, step: step, events: windowEvents)
        guard samples.count > 1 else { return 0 }

        let threshold = model.configuration.baselineThreshold
        var seconds: TimeInterval = 0

        for (lhs, rhs) in zip(samples, samples.dropFirst()) {
            let span = rhs.date.timeIntervalSince(lhs.date)
            let wasAbove = lhs.index > threshold
            let isAbove = rhs.index > threshold

            switch (wasAbove, isAbove) {
            case (true, true):
                seconds += span
            case (false, false):
                break
            case (true, false), (false, true):
                // Where the straight line between the two samples crosses.
                let rise = rhs.index - lhs.index
                let crossing = rise == 0 ? 0 : (threshold - lhs.index) / rise
                let fraction = min(max(crossing, 0), 1)
                seconds += span * (wasAbove ? fraction : 1 - fraction)
            }
        }

        return seconds / 3600
    }

    /// The tile's two numbers: the 7 × 24 h ending at `now`, and the 7 × 24 h
    /// before that.
    ///
    /// Rolling windows rather than calendar weeks, so the comparison is
    /// like-for-like — a calendar "this week" is a partial week until Saturday
    /// night, and a tile that shrank every Monday would be describing the
    /// calendar rather than the drinking.
    public static func suppression(
        events: [DrinkEventSnapshot],
        now: Date,
        model: FibrinolysisModel = FibrinolysisModel()
    ) -> TrendsSuppression {

        let week: TimeInterval = 7 * 86_400
        let thisWeekStart = now.addingTimeInterval(-week)
        let lastWeekStart = thisWeekStart.addingTimeInterval(-week)

        return TrendsSuppression(
            thisWeekHours: suppressionHours(events: events, from: thisWeekStart, to: now, model: model),
            lastWeekHours: suppressionHours(events: events, from: lastWeekStart, to: thisWeekStart, model: model)
        )
    }

    // MARK: Formatting

    /// "1 : 2" — the share card and the ratio tile speak the same dialect.
    public static func ratioText(alcoholic: Int, nonAlcoholic: Int) -> String {
        guard alcoholic > 0 else { return nonAlcoholic > 0 ? "All NA" : "—" }
        guard nonAlcoholic > 0 else { return "0 : \(alcoholic)" }
        let divisor = greatestCommonDivisor(nonAlcoholic, alcoholic)
        return "\(nonAlcoholic / divisor) : \(alcoholic / divisor)"
    }

    /// "1.1 : 1" — the stat tile, where a decimal reads better than a fraction.
    public static func decimalRatioText(_ ratio: Double?) -> String {
        guard let ratio else { return "—" }
        return "\(ratio.formatted(.number.precision(.fractionLength(0...1)))) : 1"
    }

    static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return max(x, 1)
    }
}
