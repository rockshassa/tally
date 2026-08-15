import Foundation

// MARK: - Result types

/// Per-Session point breakdown (SPEC §3).
public struct SessionScore: Identifiable, Hashable, Sendable {

    public let sessionID: UUID

    /// +10 per NA drink.
    public let nonAlcoholicPoints: Int

    /// +25 bonus per spacer.
    public let spacerPoints: Int

    /// +50 for finishing a Session at ≥ 1:1 NA-to-alcohol.
    public let balancedSessionPoints: Int

    public var id: UUID { sessionID }

    public var total: Int { nonAlcoholicPoints + spacerPoints + balancedSessionPoints }

    public init(
        sessionID: UUID,
        nonAlcoholicPoints: Int,
        spacerPoints: Int,
        balancedSessionPoints: Int
    ) {
        self.sessionID = sessionID
        self.nonAlcoholicPoints = nonAlcoholicPoints
        self.spacerPoints = spacerPoints
        self.balancedSessionPoints = balancedSessionPoints
    }
}

/// One calendar day of the log. Days with no events are represented too — that is
/// what makes dry days extend streaks (SPEC §3).
public struct DayStats: Identifiable, Hashable, Sendable {

    /// Start of day in the engine's calendar.
    public let day: Date
    public let alcoholicCount: Int
    public let nonAlcoholicCount: Int

    public var id: Date { day }

    public init(day: Date, alcoholicCount: Int, nonAlcoholicCount: Int) {
        self.day = day
        self.alcoholicCount = alcoholicCount
        self.nonAlcoholicCount = nonAlcoholicCount
    }

    /// No alcoholic drinks. A day with nothing logged at all is dry.
    public var isDry: Bool { alcoholicCount == 0 }

    public var drinkCount: Int { alcoholicCount + nonAlcoholicCount }
}

public struct StreakSummary: Hashable, Sendable {

    /// Consecutive ratio-goal days ending today.
    public let current: Int
    public let longest: Int

    /// Consecutive days with zero alcoholic drinks, ending today.
    public let currentDry: Int
    public let longestDry: Int

    public init(current: Int, longest: Int, currentDry: Int, longestDry: Int) {
        self.current = current
        self.longest = longest
        self.currentDry = currentDry
        self.longestDry = longestDry
    }

    public static let zero = StreakSummary(current: 0, longest: 0, currentDry: 0, longestDry: 0)
}

/// Everything the You tab shows (SPEC §3), computed in one pass.
public struct ScoreSummary: Hashable, Sendable {

    public let totalPoints: Int
    public let sessionScores: [SessionScore]
    public let streaks: StreakSummary
    public let badges: [BadgeAward]
    public let dayStats: [DayStats]

    public init(
        totalPoints: Int,
        sessionScores: [SessionScore],
        streaks: StreakSummary,
        badges: [BadgeAward],
        dayStats: [DayStats]
    ) {
        self.totalPoints = totalPoints
        self.sessionScores = sessionScores
        self.streaks = streaks
        self.badges = badges
        self.dayStats = dayStats
    }

    public static let empty = ScoreSummary(
        totalPoints: 0,
        sessionScores: [],
        streaks: .zero,
        badges: [],
        dayStats: []
    )
}

// MARK: - Engine

/// Points, streaks, and badges (SPEC §3). Every number here is recomputed from
/// the event log — nothing is persisted, so watch- and phone-logged drinks
/// contribute identically and there is no aggregate state to conflict-resolve.
public struct ScoringEngine: Sendable {

    // MARK: Configuration

    public struct Configuration: Hashable, Sendable {

        /// +10 per NA drink.
        public var nonAlcoholicPoints: Int

        /// +25 bonus per spacer.
        public var spacerBonus: Int

        /// +50 for finishing a Session at ≥ ratio goal.
        public var balancedSessionBonus: Int

        /// NA drinks required per alcoholic drink. SPEC §3 default 1:1, configurable
        /// in Settings (SPEC §9).
        public var ratioGoal: Double

        /// Minimum alcoholic drinks before `Badge.pacer` is on the table — one
        /// spacer between two drinks is not "alternated all night".
        public var pacerMinimumAlcoholicDrinks: Int

        /// Days needed for `Badge.hydrationWeek`.
        public var hydrationStreakDays: Int

        /// Calendar used for day bucketing and streak walking.
        public var calendar: Calendar

        public init(
            nonAlcoholicPoints: Int = 10,
            spacerBonus: Int = 25,
            balancedSessionBonus: Int = 50,
            ratioGoal: Double = 1.0,
            pacerMinimumAlcoholicDrinks: Int = 3,
            hydrationStreakDays: Int = 7,
            calendar: Calendar = .current
        ) {
            self.nonAlcoholicPoints = nonAlcoholicPoints
            self.spacerBonus = spacerBonus
            self.balancedSessionBonus = balancedSessionBonus
            self.ratioGoal = ratioGoal
            self.pacerMinimumAlcoholicDrinks = pacerMinimumAlcoholicDrinks
            self.hydrationStreakDays = hydrationStreakDays
            self.calendar = calendar
        }

        public static let `default` = Configuration()
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Points

    /// SPEC §3: +10 per NA drink, +25 per spacer, +50 for *finishing* a Session at
    /// ≥ the ratio goal. The +50 lands only once the Session has closed — it is
    /// awarded for how the night ended, so an in-progress Session cannot bank it.
    public func score(_ session: DerivedSession, asOf now: Date = Date()) -> SessionScore {
        let naPoints = session.nonAlcoholicCount * configuration.nonAlcoholicPoints
        let spacerPoints = session.spacerCount * configuration.spacerBonus

        let finished = session.isClosed(asOf: now)
        let balanced = finished
            && session.drinkCount > 0
            && meetsRatioGoal(alcoholicCount: session.alcoholicCount, nonAlcoholicCount: session.nonAlcoholicCount)

        return SessionScore(
            sessionID: session.id,
            nonAlcoholicPoints: naPoints,
            spacerPoints: spacerPoints,
            balancedSessionPoints: balanced ? configuration.balancedSessionBonus : 0
        )
    }

    public func scores(for sessions: [DerivedSession], asOf now: Date = Date()) -> [SessionScore] {
        sessions.map { score($0, asOf: now) }
    }

    public func totalPoints(for sessions: [DerivedSession], asOf now: Date = Date()) -> Int {
        scores(for: sessions, asOf: now).reduce(0) { $0 + $1.total }
    }

    // MARK: - Ratio goal

    public func meetsRatioGoal(alcoholicCount: Int, nonAlcoholicCount: Int) -> Bool {
        // Dry qualifies unconditionally — nothing to pace against.
        guard alcoholicCount > 0 else { return true }
        return Double(nonAlcoholicCount) >= configuration.ratioGoal * Double(alcoholicCount)
    }

    public func meetsRatioGoal(_ day: DayStats) -> Bool {
        meetsRatioGoal(alcoholicCount: day.alcoholicCount, nonAlcoholicCount: day.nonAlcoholicCount)
    }

    // MARK: - Days

    /// Contiguous day-by-day stats from the first logged event through `now`,
    /// including days with nothing logged (they are dry days, SPEC §3).
    public func dailyStats(for events: [DrinkEventSnapshot], asOf now: Date = Date()) -> [DayStats] {
        let calendar = configuration.calendar
        guard let earliest = events.map(\.timestamp).min() else { return [] }

        var counts: [Date: (alcoholic: Int, nonAlcoholic: Int)] = [:]
        for event in events {
            let day = calendar.startOfDay(for: event.timestamp)
            var bucket = counts[day] ?? (0, 0)
            if event.type == .alcoholic { bucket.alcoholic += 1 } else { bucket.nonAlcoholic += 1 }
            counts[day] = bucket
        }

        let firstDay = calendar.startOfDay(for: earliest)
        let lastDay = max(calendar.startOfDay(for: now), calendar.startOfDay(for: events.map(\.timestamp).max() ?? now))

        var result: [DayStats] = []
        var cursor = firstDay
        while cursor <= lastDay {
            let bucket = counts[cursor] ?? (0, 0)
            result.append(
                DayStats(day: cursor, alcoholicCount: bucket.alcoholic, nonAlcoholicCount: bucket.nonAlcoholic)
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return result
    }

    // MARK: - Streaks

    /// SPEC §3: daily streak for hitting the ratio goal; dry days extend it
    /// automatically. The streak is bounded by the log — it starts counting at the
    /// first ever event, not at the beginning of time.
    public func streaks(for events: [DrinkEventSnapshot], asOf now: Date = Date()) -> StreakSummary {
        streaks(days: dailyStats(for: events, asOf: now))
    }

    public func streaks(days: [DayStats]) -> StreakSummary {
        guard !days.isEmpty else { return .zero }

        var run = 0, longest = 0
        var dryRun = 0, longestDry = 0

        for day in days {
            run = meetsRatioGoal(day) ? run + 1 : 0
            longest = max(longest, run)

            dryRun = day.isDry ? dryRun + 1 : 0
            longestDry = max(longestDry, dryRun)
        }

        return StreakSummary(current: run, longest: longest, currentDry: dryRun, longestDry: longestDry)
    }

    // MARK: - Badge predicates

    /// SPEC §3 "Pacer — alternated all night".
    public func isPacer(_ session: DerivedSession) -> Bool {
        Spacers.alternatedThroughout(
            session.events,
            minimumAlcoholicDrinks: configuration.pacerMinimumAlcoholicDrinks
        )
    }

    /// SPEC §3 "Designated Legend — a Session at a bar with zero alcoholic drinks".
    public func isDesignatedLegend(_ session: DerivedSession, venue: VenueSnapshot?) -> Bool {
        guard let venue, venue.category == .bar else { return false }
        return session.alcoholicCount == 0 && session.nonAlcoholicCount > 0
    }

    // MARK: - Badges

    /// One award per badge type, at the moment it was first earned. That is what
    /// the badge case on the You tab shows (SPEC §3).
    public func badges(
        sessions: [DerivedSession],
        events: [DrinkEventSnapshot],
        venues: [UUID: VenueSnapshot] = [:],
        asOf now: Date = Date()
    ) -> [BadgeAward] {

        var earliest: [Badge: BadgeAward] = [:]

        func record(_ badge: Badge, at date: Date, sessionID: UUID? = nil) {
            let candidate = BadgeAward(badge: badge, earnedAt: date, sessionID: sessionID)
            if let existing = earliest[badge], existing.earnedAt <= candidate.earnedAt { return }
            earliest[badge] = candidate
        }

        // Session badges.
        for session in sessions.sorted(by: DerivedSession.isOrderedBefore) {
            guard session.isClosed(asOf: now) else { continue }
            if isPacer(session) {
                record(.pacer, at: session.endedAt, sessionID: session.id)
            }
            let venue = session.venueID.flatMap { venues[$0] }
            if isDesignatedLegend(session, venue: venue) {
                record(.designatedLegend, at: session.endedAt, sessionID: session.id)
            }
        }

        // Streak badges — walk the days once and stamp the day each threshold hit.
        var run = 0
        var dryRun = 0
        for day in dailyStats(for: events, asOf: now) {
            run = meetsRatioGoal(day) ? run + 1 : 0
            if run == configuration.hydrationStreakDays {
                record(.hydrationWeek, at: day.day)
            }

            dryRun = day.isDry ? dryRun + 1 : 0
            for badge in [Badge.drySpell3, .drySpell7, .drySpell30] {
                if let threshold = badge.dryDayThreshold, dryRun == threshold {
                    record(badge, at: day.day)
                }
            }
        }

        return earliest.values.sorted(by: BadgeAward.isOrderedBefore)
    }

    // MARK: - Everything at once

    public func summary(
        events: [DrinkEventSnapshot],
        sessions: [DerivedSession],
        venues: [UUID: VenueSnapshot] = [:],
        asOf now: Date = Date()
    ) -> ScoreSummary {
        let days = dailyStats(for: events, asOf: now)
        let sessionScores = scores(for: sessions, asOf: now)
        return ScoreSummary(
            totalPoints: sessionScores.reduce(0) { $0 + $1.total },
            sessionScores: sessionScores,
            streaks: streaks(days: days),
            badges: badges(sessions: sessions, events: events, venues: venues, asOf: now),
            dayStats: days
        )
    }

    // MARK: - Shared spacer definition

    /// The canonical spacer count for an ordered run of events (SPEC §3).
    public static func spacerCount(in events: [DrinkEventSnapshot]) -> Int {
        Spacers.count(in: events)
    }
}
