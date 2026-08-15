import Foundation
import TallyKit

/// Everything the You tab draws, derived in one pass from the event log
/// (SPEC §3: "all of it recomputed from the event log").
///
/// This type owns no rendering and no state. It exists so the screen is a pure
/// function of `ScoringEngine` output — PLAN Gate 2 asserts that the points,
/// streak, and badge states on screen match what the engine produces headlessly
/// for the same fixture, and the only way to guarantee that is for the view to
/// have nowhere else to get its numbers from.
///
/// The one thing computed here that the engine does not hand over directly is
/// the *weekly* slice: `ScoreSummary` is all-time, and the hero's "+120 this
/// week" and the ratio-goal bar both scope to the current week. Both are simple
/// filters over engine output, never a second scoring rule.
struct YouSummary: Equatable {

    // MARK: Points (SPEC §3)

    /// `ScoreSummary.totalPoints` — +10 per NA drink, +25 per spacer, +50 per
    /// balanced Session. Nothing here comes from an alcoholic drink.
    let allTimePoints: Int

    /// Points from Sessions that started inside the current week.
    let weekPoints: Int

    // MARK: Streaks (SPEC §3)

    let currentStreak: Int
    let longestStreak: Int
    let currentDryStreak: Int
    let longestDryStreak: Int

    // MARK: This week's ratio goal

    let ratioGoal: Double
    let weekStart: Date
    let weekAlcoholicCount: Int
    let weekNonAlcoholicCount: Int

    // MARK: Badge case (SPEC §3)

    let badgeStates: [YouBadgeState]

    /// False only for a store with no events at all — what the zero-state asks.
    let hasEvents: Bool

    // MARK: - Derived

    /// How full the weekly ratio bar is, 0...1.
    ///
    /// A week with no alcoholic drinks is complete by definition — the engine
    /// treats dry as meeting the goal unconditionally, and the bar must not
    /// disagree with the streak sitting next to it.
    var weekRatioProgress: Double {
        let required = ratioGoal * Double(weekAlcoholicCount)
        guard required > 0 else { return 1 }
        return min(1, Double(weekNonAlcoholicCount) / required)
    }

    var meetsWeeklyRatioGoal: Bool {
        weekRatioProgress >= 1
    }

    var hasDrinksThisWeek: Bool {
        weekAlcoholicCount + weekNonAlcoholicCount > 0
    }

    var earnedBadges: [YouBadgeState] { badgeStates.filter(\.isEarned) }
    var lockedBadges: [YouBadgeState] { badgeStates.filter { !$0.isEarned } }

    /// The next streak length worth chasing — what the ring fills toward.
    /// Beyond the last rung the ring simply reads full; there is no number to
    /// dangle in front of someone on a 400-day streak.
    var nextStreakMilestone: Int? {
        Self.streakMilestones.first { $0 > currentStreak }
    }

    /// Ring fill, 0...1.
    var streakProgress: Double {
        guard let milestone = nextStreakMilestone, milestone > 0 else { return currentStreak > 0 ? 1 : 0 }
        return min(1, Double(currentStreak) / Double(milestone))
    }

    static let streakMilestones = [3, 7, 14, 30, 60, 100, 180, 365]

    // MARK: - Construction

    static let empty = YouSummary(
        allTimePoints: 0,
        weekPoints: 0,
        currentStreak: 0,
        longestStreak: 0,
        currentDryStreak: 0,
        longestDryStreak: 0,
        ratioGoal: RatioGoalPreference.defaultValue,
        weekStart: Date(),
        weekAlcoholicCount: 0,
        weekNonAlcoholicCount: 0,
        badgeStates: YouBadgeState.allLocked(),
        hasEvents: false
    )

    /// The one entry point. Everything on screen traces back to this call.
    static func make(
        events: [DrinkEventSnapshot],
        sessions: [DerivedSession],
        venues: [UUID: VenueSnapshot],
        configuration: ScoringEngine.Configuration,
        now: Date = Date()
    ) -> YouSummary {

        let engine = ScoringEngine(configuration: configuration)
        let score = engine.summary(events: events, sessions: sessions, venues: venues, asOf: now)

        let calendar = configuration.calendar
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? calendar.startOfDay(for: now)

        // Weekly points: the same SessionScores, filtered by when the Session
        // started. No second scoring pass, so the two numbers in the hero can
        // never tell different stories.
        var startedAt: [UUID: Date] = [:]
        for session in sessions { startedAt[session.id] = session.startedAt }
        let weekPoints = score.sessionScores
            .filter { (startedAt[$0.sessionID] ?? .distantPast) >= weekStart }
            .reduce(0) { $0 + $1.total }

        let weekEvents = events.filter { $0.timestamp >= weekStart && $0.timestamp <= now }

        return YouSummary(
            allTimePoints: score.totalPoints,
            weekPoints: weekPoints,
            currentStreak: score.streaks.current,
            longestStreak: score.streaks.longest,
            currentDryStreak: score.streaks.currentDry,
            longestDryStreak: score.streaks.longestDry,
            ratioGoal: configuration.ratioGoal,
            weekStart: weekStart,
            weekAlcoholicCount: weekEvents.filter { $0.type == .alcoholic }.count,
            weekNonAlcoholicCount: weekEvents.filter { $0.type == .nonAlcoholic }.count,
            badgeStates: YouBadgeState.states(
                awards: score.badges,
                streaks: score.streaks,
                hydrationStreakDays: configuration.hydrationStreakDays
            ),
            hasEvents: !events.isEmpty
        )
    }
}

// MARK: - Badge case

/// One tile in the badge case: the badge, when it was earned if it was, and how
/// far off it is if it wasn't.
struct YouBadgeState: Identifiable, Equatable {

    let badge: Badge

    /// `nil` while locked. Carries the SPEC §3 earned date when not.
    let award: BadgeAward?

    /// Present only for the badges with a countable threshold — the Dry Spells
    /// and Hydration Week. *Pacer* and *Designated Legend* are earned by the
    /// shape of a single night, and there is no honest halfway point to show.
    let progress: Progress?

    var id: Badge { badge }
    var isEarned: Bool { award != nil }
    var earnedAt: Date? { award?.earnedAt }

    struct Progress: Equatable {
        let current: Int
        let target: Int

        var remaining: Int { max(0, target - current) }

        var fraction: Double {
            guard target > 0 else { return 0 }
            return min(1, max(0, Double(current) / Double(target)))
        }
    }

    /// Grid order: earned first — newest achievement leads — then the locked
    /// ones in ascending difficulty, which is also the order they'll be earned.
    static let displayOrder: [Badge] = [
        .pacer,
        .designatedLegend,
        .hydrationWeek,
        .drySpell3,
        .drySpell7,
        .drySpell30
    ]

    static func states(
        awards: [BadgeAward],
        streaks: StreakSummary,
        hydrationStreakDays: Int
    ) -> [YouBadgeState] {

        var byBadge: [Badge: BadgeAward] = [:]
        for award in awards { byBadge[award.badge] = award }

        let states = displayOrder.map { badge in
            YouBadgeState(
                badge: badge,
                award: byBadge[badge],
                progress: progress(
                    for: badge,
                    streaks: streaks,
                    hydrationStreakDays: hydrationStreakDays
                )
            )
        }

        // Stable partition: earned tiles float up, each group keeps
        // `displayOrder`, so the case never reshuffles under the user.
        return states.filter(\.isEarned) + states.filter { !$0.isEarned }
    }

    static func allLocked() -> [YouBadgeState] {
        states(awards: [], streaks: .zero, hydrationStreakDays: 7)
    }

    private static func progress(
        for badge: Badge,
        streaks: StreakSummary,
        hydrationStreakDays: Int
    ) -> Progress? {
        if let threshold = badge.dryDayThreshold {
            return Progress(current: streaks.currentDry, target: threshold)
        }
        if badge == .hydrationWeek {
            return Progress(current: streaks.current, target: hydrationStreakDays)
        }
        return nil
    }

    /// The locked-tile subtitle: the badge's own copy, plus the countdown when
    /// there is one to give. SPEC §5's tone rules apply here too — this states a
    /// number, it never scolds.
    var lockedDetail: String {
        guard let progress, progress.current > 0, progress.remaining > 0 else {
            return badge.detail
        }
        return "\(badge.detail) \(progress.remaining) to go."
    }
}
