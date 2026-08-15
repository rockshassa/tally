import Foundation
import TallyKit

/// The arithmetic behind every SPEC §5 trigger, as pure functions over event
/// snapshots.
///
/// Deliberately free of `UNUserNotificationCenter`, `ModelContext`, and clocks
/// you cannot pass in: the question "would this fire on the 3-drinks-in-90-min
/// fixture?" (PLAN Gate 2) should be answerable by calling one function with an
/// array and a date, not by running an app.
enum NotificationTriggers {

    // MARK: - Weekly digest (SPEC §5)

    /// "12 drinks this week, down 3 from last. 7-day avg: 1.7/day."
    struct DigestFacts: Hashable, Sendable {

        /// Alcoholic drinks in the seven days ending on the digest date.
        let alcoholicThisWeek: Int
        let alcoholicLastWeek: Int
        let nonAlcoholicThisWeek: Int
        let spacersThisWeek: Int

        /// Alcoholic drinks per day across the digest week.
        var sevenDayAverage: Double { Double(alcoholicThisWeek) / 7.0 }

        /// Negative means fewer than last week.
        var change: Int { alcoholicThisWeek - alcoholicLastWeek }

        /// Nothing at all in either week — there is no news, so no digest.
        var isEmpty: Bool { alcoholicThisWeek == 0 && nonAlcoholicThisWeek == 0 && alcoholicLastWeek == 0 }
    }

    /// Facts for the seven days ending at `endingAt` (inclusive of that day).
    static func digestFacts(
        events: [DrinkEventSnapshot],
        endingAt: Date,
        calendar: Calendar = .current
    ) -> DigestFacts {

        let lastDay = calendar.startOfDay(for: endingAt)
        let thisWeekStart = calendar.date(byAdding: .day, value: -6, to: lastDay) ?? lastDay
        let lastWeekStart = calendar.date(byAdding: .day, value: -13, to: lastDay) ?? lastDay
        let thisWeekEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay

        let thisWeek = events.filter { $0.timestamp >= thisWeekStart && $0.timestamp < thisWeekEnd }
        let lastWeek = events.filter { $0.timestamp >= lastWeekStart && $0.timestamp < thisWeekStart }

        return DigestFacts(
            alcoholicThisWeek: thisWeek.count { $0.type == .alcoholic },
            alcoholicLastWeek: lastWeek.count { $0.type == .alcoholic },
            nonAlcoholicThisWeek: thisWeek.count { $0.type == .nonAlcoholic },
            spacersThisWeek: ScoringEngine.spacerCount(in: thisWeek.sorted(by: DrinkEventSnapshot.isOrderedBefore))
        )
    }

    // MARK: - Trend alert (SPEC §5)

    /// "Third week trending down — nice."
    struct TrendFinding: Hashable, Sendable {

        enum Direction: String, Hashable, Sendable {
            case down
            case up
        }

        let direction: Direction

        /// How many weeks the run covers — two consecutive moves is three weeks.
        let weeks: Int

        /// Percent change across the whole run, always positive; `direction`
        /// carries the sign.
        let percentChange: Int

        /// Identity of this finding, so the same run is never announced twice.
        var signature: String { "\(direction.rawValue).\(weeks)" }
    }

    /// Minimum week-over-week move that counts as a move rather than noise.
    static let trendMinimumFraction = 0.15

    /// …and the floor in whole drinks, so 1 → 2 drinks a week is not "up 100%".
    static let trendMinimumDrinks = 2

    /// SPEC §5: "sustained change in 7-day average". Sustained means the last two
    /// or more week-over-week moves went the same way, each one big enough to be
    /// real.
    ///
    /// - Returns: `nil` when the log is short, flat, or noisy. Silence is the
    ///   right output far more often than an alert is.
    static func trendFinding(
        events: [DrinkEventSnapshot],
        asOf now: Date = Date(),
        calendar: Calendar = .current
    ) -> TrendFinding? {

        let weeks = weeklyAlcoholicCounts(events: events, asOf: now, weeks: 4, calendar: calendar)
        guard weeks.count == 4, weeks.contains(where: { $0 > 0 }) else { return nil }

        // Moves, oldest first: weeks[1] - weeks[0], and so on.
        var moves: [TrendFinding.Direction?] = []
        for (earlier, later) in zip(weeks, weeks.dropFirst()) {
            moves.append(direction(from: earlier, to: later))
        }

        guard let latest = moves.last ?? nil else { return nil }

        var run = 0
        for move in moves.reversed() {
            guard move == latest else { break }
            run += 1
        }
        guard run >= 2 else { return nil }

        let startIndex = moves.count - run
        let start = weeks[startIndex]
        let end = weeks[weeks.count - 1]
        let percent: Int
        if start == 0 {
            percent = 100
        } else {
            percent = Int((abs(Double(end - start)) / Double(start) * 100).rounded())
        }

        return TrendFinding(direction: latest, weeks: run + 1, percentChange: percent)
    }

    private static func direction(from earlier: Int, to later: Int) -> TrendFinding.Direction? {
        let delta = later - earlier
        guard abs(delta) >= trendMinimumDrinks else { return nil }
        let base = max(earlier, 1)
        guard abs(Double(delta)) / Double(base) >= trendMinimumFraction else { return nil }
        return delta < 0 ? .down : .up
    }

    /// Alcoholic drinks per trailing 7-day bucket, oldest bucket first. The last
    /// bucket ends today.
    static func weeklyAlcoholicCounts(
        events: [DrinkEventSnapshot],
        asOf now: Date = Date(),
        weeks: Int,
        calendar: Calendar = .current
    ) -> [Int] {

        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }

        var buckets: [Int] = []
        for index in stride(from: weeks - 1, through: 0, by: -1) {
            guard
                let end = calendar.date(byAdding: .day, value: -7 * index, to: tomorrow),
                let start = calendar.date(byAdding: .day, value: -7, to: end)
            else { return [] }
            buckets.append(events.count { $0.type == .alcoholic && $0.timestamp >= start && $0.timestamp < end })
        }
        return buckets
    }

    // MARK: - Pacing nudge (SPEC §5)

    /// "Time for a spacer? +25 pts."
    struct PacingFinding: Hashable, Sendable {
        let alcoholicCount: Int
        let windowMinutes: Int
    }

    /// SPEC §5: 3+ alcoholic drinks within 90 minutes, in-Session.
    static let pacingWindow: TimeInterval = 90 * 60
    static let pacingDrinkThreshold = 3

    /// - Parameter events: the active Session's events (any order).
    /// - Returns: a finding when the last 90 minutes hold three or more
    ///   alcoholic drinks *and* nothing non-alcoholic came between them. An NA
    ///   drink already logged in the run means the user is pacing — the nudge
    ///   would be telling them to do what they just did.
    static func pacingFinding(
        sessionEvents events: [DrinkEventSnapshot],
        asOf now: Date = Date()
    ) -> PacingFinding? {

        let windowStart = now.addingTimeInterval(-pacingWindow)
        let window = events
            .filter { $0.timestamp > windowStart && $0.timestamp <= now }
            .sorted(by: DrinkEventSnapshot.isOrderedBefore)

        let alcoholic = window.filter { $0.type == .alcoholic }
        guard alcoholic.count >= pacingDrinkThreshold else { return nil }

        guard
            let first = alcoholic.first?.timestamp,
            let last = alcoholic.last?.timestamp
        else { return nil }

        let hadSpacer = window.contains {
            $0.type == .nonAlcoholic && $0.timestamp > first && $0.timestamp < last
        }
        guard !hadSpacer else { return nil }

        return PacingFinding(
            alcoholicCount: alcoholic.count,
            windowMinutes: Int(pacingWindow / 60)
        )
    }

    // MARK: - Streak protection (SPEC §5)

    /// "5-day streak on the line — log some water."
    struct StreakRisk: Hashable, Sendable {

        /// Days already banked, before today.
        let streakDays: Int

        /// NA drinks still needed today to hold the streak.
        let nonAlcoholicNeeded: Int
    }

    /// Streaks worth protecting. One good day is not a streak, and a nudge about
    /// it would be noise.
    static let streakMinimumDays = 2

    /// SPEC §5: "evening of a day that would break a streak".
    ///
    /// A dry day extends the streak automatically (SPEC §3), so nothing is ever
    /// at risk until an alcoholic drink has actually been logged today — which is
    /// what makes this trigger quiet on the days it should be.
    static func streakRisk(
        events: [DrinkEventSnapshot],
        engine: ScoringEngine,
        asOf now: Date = Date(),
        calendar: Calendar = .current
    ) -> StreakRisk? {

        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }

        let todayEvents = events.filter { $0.timestamp >= today && $0.timestamp < tomorrow }
        let alcoholic = todayEvents.count { $0.type == .alcoholic }
        let nonAlcoholic = todayEvents.count { $0.type == .nonAlcoholic }

        guard alcoholic > 0 else { return nil }
        guard !engine.meetsRatioGoal(alcoholicCount: alcoholic, nonAlcoholicCount: nonAlcoholic) else { return nil }

        // The streak as it stood at the end of yesterday.
        let earlier = events.filter { $0.timestamp < today }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
        let banked = engine.streaks(for: earlier, asOf: yesterday).current
        guard banked >= streakMinimumDays else { return nil }

        let needed = Int((engine.configuration.ratioGoal * Double(alcoholic)).rounded(.up)) - nonAlcoholic
        return StreakRisk(streakDays: banked, nonAlcoholicNeeded: max(needed, 1))
    }
}

// MARK: - Small helper

private extension Sequence {
    /// `count(where:)` under a name that reads at the call sites above.
    func count(_ isIncluded: (Element) -> Bool) -> Int {
        reduce(into: 0) { total, element in if isIncluded(element) { total += 1 } }
    }
}
