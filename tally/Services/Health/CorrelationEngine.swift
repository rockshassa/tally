import Foundation
import TallyKit

/// SPEC §4's correlation engine: three analyses, two hard guardrails, and a
/// strong bias toward saying nothing.
///
/// **Pure by construction.** It takes the event log, the derived Sessions, and a
/// list of `HealthDaySample`s, and returns values. No HealthKit import, no
/// `ModelContext`, no clock of its own — `now` is a parameter. That is what makes
/// PLAN Gate 3's synthetic fixtures able to assert on exact card numbers.
///
/// **Nothing it touches is persisted.** The samples arrive from an on-demand
/// read and are gone when the call returns (SPEC §10).
///
/// ## The guardrails
///
/// SPEC §4: *"an insight is shown only when there's enough data (≥ 8 drinking-day
/// and ≥ 8 dry-day comparisons in the trailing 90 days) and the effect is
/// meaningful (≥ 20 % difference). Weak or noisy correlations produce silence,
/// not filler."*
///
/// The sample floor is applied **globally**, not per analysis. If there are not
/// eight of each kind of day to compare, this engine has not learned enough about
/// the user to say anything at all — so the weekly-drift and workout-displacement
/// analyses do not run either. The effect floor is then applied per analysis, and
/// an analysis that misses it contributes nothing rather than a hedged sentence.
///
/// ## Nights, not calendar days
///
/// "The day after a Session" cannot be `startOfDay(session.endedAt) + 1` — a
/// Session that ends at 02:00 would put its own morning after tomorrow. So days
/// are bucketed into *nights*: a timestamp belongs to the night of
/// `startOfDay(timestamp − nightBoundary)`, with a 4 h boundary. A Session
/// ending at 23:00 Friday and one ending at 02:00 Saturday are both Friday
/// night, and both are followed by Saturday.
nonisolated public struct CorrelationEngine: Sendable {

    // MARK: - Configuration

    public struct Configuration: Hashable, Sendable {

        /// SPEC §4: "days following a Session of ≥ 2 alcoholic drinks (threshold
        /// configurable)". Read from `TallyDefaults.Keys.morningAfterThreshold`.
        public var morningAfterThreshold: Int

        /// SPEC §4: "≥ 8 drinking-day and ≥ 8 dry-day comparisons".
        public var minimumComparisons: Int

        /// SPEC §4: "the effect is meaningful (≥ 20 % difference)".
        public var minimumRelativeEffect: Double

        /// SPEC §4: "in the trailing 90 days".
        public var windowDays: Int

        /// SPEC §4: "trailing 4-week exercise trend against drink totals".
        public var driftWeeks: Int

        /// How much of the small hours belongs to the previous night. Four hours
        /// puts a 03:00 last drink on the night it started.
        public var nightBoundary: TimeInterval

        /// A week with fewer readable days than this is a hole, not a quiet week,
        /// and is dropped from the weekly analyses.
        public var minimumReadableDaysPerWeek: Int

        /// Both weekly analyses need enough weeks on each side to be worth the
        /// words.
        public var minimumWeeksPerGroup: Int

        public var calendar: Calendar

        /// The literal mirrors `TallyDefaults.Fallback.morningAfterThreshold`
        /// (SPEC §4's "≥ 2 alcoholic drinks"). It is spelled out rather than read
        /// from there because this engine is `nonisolated` and `TallyDefaults`
        /// is not — and because a pure engine should not have a settings store in
        /// its default arguments. `HealthInsightsModel.engineConfiguration` is the
        /// one place the user's actual value is applied.
        public init(
            morningAfterThreshold: Int = 2,
            minimumComparisons: Int = 8,
            minimumRelativeEffect: Double = 0.20,
            windowDays: Int = 90,
            driftWeeks: Int = 4,
            nightBoundary: TimeInterval = 4 * 60 * 60,
            minimumReadableDaysPerWeek: Int = 4,
            minimumWeeksPerGroup: Int = 3,
            calendar: Calendar = .current
        ) {
            self.morningAfterThreshold = morningAfterThreshold
            self.minimumComparisons = minimumComparisons
            self.minimumRelativeEffect = minimumRelativeEffect
            self.windowDays = windowDays
            self.driftWeeks = driftWeeks
            self.nightBoundary = nightBoundary
            self.minimumReadableDaysPerWeek = minimumReadableDaysPerWeek
            self.minimumWeeksPerGroup = minimumWeeksPerGroup
            self.calendar = calendar
        }

        public static let `default` = Configuration()
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Entry point

    /// Runs all three analyses of SPEC §4 and returns whatever survived the
    /// guardrails — usually nothing.
    ///
    /// - Parameters:
    ///   - sessions: derived Sessions (`SessionDeriver`), for the ≥ threshold test.
    ///   - events: the raw log, for per-night alcoholic counts and weekly totals.
    ///   - activity: on-demand HealthKit reads covering the trailing window.
    ///   - now: the clock, injected so fixtures are deterministic.
    public func report(
        sessions: [DerivedSession],
        events: [DrinkEventSnapshot],
        activity: [HealthDaySample],
        asOf now: Date
    ) -> HealthInsightReport {

        let calendar = configuration.calendar
        let activityByDay = index(activity, calendar: calendar)
        let hasReadableActivity = activity.contains(where: \.hasSignal)

        // No readable activity at all: not a null result, an absent input. The
        // caller reads this to tell "connected but quiet" from "never granted or
        // revoked" — HealthKit itself will not say which (SPEC §4, §10).
        guard hasReadableActivity, !events.isEmpty else {
            return HealthInsightReport(
                insights: [],
                evidence: .init(
                    drinkingComparisons: 0,
                    dryComparisons: 0,
                    metric: nil,
                    meetsSampleFloor: false,
                    hasReadableActivity: hasReadableActivity
                )
            )
        }

        let pairs = morningAfterPairs(
            sessions: sessions,
            events: events,
            activityByDay: activityByDay,
            asOf: now
        )

        let drinkingSamples = pairs.filter { $0.wasDrinking }.map(\.sample)
        let drySamples = pairs.filter { !$0.wasDrinking }.map(\.sample)

        let meetsFloor = drinkingSamples.count >= configuration.minimumComparisons
            && drySamples.count >= configuration.minimumComparisons

        // SPEC §4's hard gate. Under it, this engine has nothing to say — about
        // mornings, about weeks, about anything.
        guard meetsFloor else {
            return HealthInsightReport(
                insights: [],
                evidence: .init(
                    drinkingComparisons: drinkingSamples.count,
                    dryComparisons: drySamples.count,
                    metric: nil,
                    meetsSampleFloor: false,
                    hasReadableActivity: true
                )
            )
        }

        let metric = preferredMetric(drinking: drinkingSamples, dry: drySamples)

        var insights: [HealthInsight] = []

        if let metric,
           let insight = morningAfterInsight(metric: metric, drinking: drinkingSamples, dry: drySamples) {
            insights.append(insight)
        }

        if let insight = weeklyDriftInsight(
            metric: metric ?? .steps,
            events: events,
            activityByDay: activityByDay,
            asOf: now
        ) {
            insights.append(insight)
        }

        if let insight = workoutDisplacementInsight(
            events: events,
            activityByDay: activityByDay,
            asOf: now
        ) {
            insights.append(insight)
        }

        return HealthInsightReport(
            insights: insights.sorted(by: HealthInsight.isOrderedBefore),
            evidence: .init(
                drinkingComparisons: drinkingSamples.count,
                dryComparisons: drySamples.count,
                metric: metric,
                meetsSampleFloor: true,
                hasReadableActivity: true
            )
        )
    }

    // MARK: - (a) Morning after

    /// One night classified, paired with the activity of the day that followed.
    struct MorningAfterPair: Hashable {
        let night: Date
        let wasDrinking: Bool
        let sample: HealthDaySample
    }

    /// Walks the trailing window night by night and keeps the ones that can be
    /// compared.
    ///
    /// A night is included only when it is unambiguous:
    /// * **drinking** — at least one Session attributed to it had ≥ threshold
    ///   alcoholic drinks (SPEC §4's own wording is per-Session);
    /// * **dry** — no alcoholic drinks at all that night (SPEC §3: a day with
    ///   nothing logged is dry).
    ///
    /// A night with one drink, under a threshold of two, is neither, and counts
    /// for nothing. Averaging it into either side would be the "spurious
    /// correlation" SPEC §4 spends a paragraph forbidding.
    func morningAfterPairs(
        sessions: [DerivedSession],
        events: [DrinkEventSnapshot],
        activityByDay: [Date: HealthDaySample],
        asOf now: Date
    ) -> [MorningAfterPair] {

        let calendar = configuration.calendar

        var alcoholicByNight: [Date: Int] = [:]
        for event in events where event.type == .alcoholic {
            alcoholicByNight[night(for: event.timestamp), default: 0] += 1
        }

        var qualifyingNights: Set<Date> = []
        for session in sessions where session.alcoholicCount >= configuration.morningAfterThreshold {
            qualifyingNights.insert(night(for: session.endedAt))
        }

        // The window starts at the later of "90 days back" and the first night
        // the user ever logged. Nights before the log began are not dry nights,
        // they are nights nobody was counting.
        guard let firstLoggedNight = events.map({ night(for: $0.timestamp) }).min() else { return [] }
        let windowStart = calendar.date(
            byAdding: .day,
            value: -configuration.windowDays,
            to: calendar.startOfDay(for: now)
        ) ?? calendar.startOfDay(for: now)
        let startNight = max(calendar.startOfDay(for: windowStart), firstLoggedNight)

        // Today's activity is still being recorded, so the last usable night is
        // the one whose morning already finished.
        let today = calendar.startOfDay(for: now)

        var pairs: [MorningAfterPair] = []
        var cursor = startNight

        while cursor < today {
            defer {
                cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? today.addingTimeInterval(1)
            }

            guard
                let morning = calendar.date(byAdding: .day, value: 1, to: cursor),
                morning < today,
                let sample = activityByDay[morning],
                sample.hasSignal
            else { continue }

            if qualifyingNights.contains(cursor) {
                pairs.append(MorningAfterPair(night: cursor, wasDrinking: true, sample: sample))
            } else if (alcoholicByNight[cursor] ?? 0) == 0 {
                pairs.append(MorningAfterPair(night: cursor, wasDrinking: false, sample: sample))
            }
        }

        return pairs
    }

    /// The first metric in the preference order with a non-zero baseline on the
    /// dry side. A baseline of zero makes a relative effect undefined, and
    /// "infinitely less exercise than none" is not a sentence.
    func preferredMetric(drinking: [HealthDaySample], dry: [HealthDaySample]) -> HealthMetric? {
        HealthMetric.morningAfterPreference.first { metric in
            mean(dry, metric) > 0
        }
    }

    private func morningAfterInsight(
        metric: HealthMetric,
        drinking: [HealthDaySample],
        dry: [HealthDaySample]
    ) -> HealthInsight? {

        let comparison = HealthInsightComparison(
            metric: metric,
            afterDrinking: mean(drinking, metric),
            afterDry: mean(dry, metric),
            drinkingDayCount: drinking.count,
            dryDayCount: dry.count,
            threshold: configuration.morningAfterThreshold
        )

        let change = comparison.relativeChange
        guard abs(change) >= configuration.minimumRelativeEffect else { return nil }

        return HealthInsight(
            kind: .morningAfter,
            metric: metric,
            headline: "Next-day \(metric.subject) \(HealthInsightCopy.change(change))",
            detail: HealthInsightCopy.morningAfter(comparison),
            relativeChange: change,
            sampleCount: drinking.count + dry.count,
            comparison: comparison
        )
    }

    // MARK: - (b) Weekly drift

    /// One trailing week: what was drunk, and how much activity was recorded.
    struct WeekBucket: Hashable {
        let start: Date
        let alcoholicCount: Int
        let activityTotal: Double
        let workoutCount: Int
        let readableDays: Int
    }

    /// SPEC §4: *"trailing 4-week exercise trend against drink totals — flags
    /// when a rising drink trend co-occurs with a falling activity trend."*
    ///
    /// Implemented as the two most recent weeks against the two before them,
    /// rather than a regression slope: the card has to state the finding in the
    /// user's own numbers, and "up 38 % while activity is down 24 %" is a number
    /// they can check. A slope is not.
    func weeklyDriftInsight(
        metric: HealthMetric,
        events: [DrinkEventSnapshot],
        activityByDay: [Date: HealthDaySample],
        asOf now: Date
    ) -> HealthInsight? {

        let weeks = weekBuckets(
            count: configuration.driftWeeks,
            metric: metric,
            events: events,
            activityByDay: activityByDay,
            asOf: now
        )

        // Every week has to be readable, or "the trend" is a trend in coverage.
        guard weeks.count == configuration.driftWeeks else { return nil }
        guard weeks.allSatisfy({ $0.readableDays >= configuration.minimumReadableDaysPerWeek }) else { return nil }

        let half = configuration.driftWeeks / 2
        guard half > 0 else { return nil }

        let earlier = Array(weeks.prefix(half))
        let recent = Array(weeks.suffix(half))

        let earlierDrinks = Double(earlier.reduce(0) { $0 + $1.alcoholicCount })
        let recentDrinks = Double(recent.reduce(0) { $0 + $1.alcoholicCount })
        let earlierActivity = earlier.reduce(0.0) { $0 + $1.activityTotal }
        let recentActivity = recent.reduce(0.0) { $0 + $1.activityTotal }

        guard earlierDrinks > 0, earlierActivity > 0 else { return nil }

        let drinkChange = (recentDrinks - earlierDrinks) / earlierDrinks
        let activityChange = (recentActivity - earlierActivity) / earlierActivity

        // The co-occurrence SPEC §4 names: drinks up, activity down, both by
        // enough to be worth saying.
        guard drinkChange >= configuration.minimumRelativeEffect else { return nil }
        guard activityChange <= -configuration.minimumRelativeEffect else { return nil }

        return HealthInsight(
            kind: .weeklyDrift,
            metric: metric,
            headline: "Drinks \(HealthInsightCopy.change(drinkChange)), \(metric.subject) \(HealthInsightCopy.change(activityChange))",
            detail: HealthInsightCopy.weeklyDrift(
                metric: metric,
                drinkChange: drinkChange,
                activityChange: activityChange
            ),
            relativeChange: activityChange,
            sampleCount: weeks.count
        )
    }

    // MARK: - (c) Workout displacement

    /// SPEC §4: *"whether workout frequency drops in weeks with more Sessions."*
    ///
    /// Weeks across the trailing window are split at their own mean drink count.
    /// Only a *drop* is reported: "displacement" is the claim being tested, and a
    /// card saying workouts went up in heavy weeks would be noise dressed as a
    /// finding.
    func workoutDisplacementInsight(
        events: [DrinkEventSnapshot],
        activityByDay: [Date: HealthDaySample],
        asOf now: Date
    ) -> HealthInsight? {

        let weekCount = configuration.windowDays / 7
        let weeks = weekBuckets(
            count: weekCount,
            metric: .workouts,
            events: events,
            activityByDay: activityByDay,
            asOf: now
        ).filter { $0.readableDays >= configuration.minimumReadableDaysPerWeek }

        guard weeks.count >= configuration.minimumWeeksPerGroup * 2 else { return nil }

        let meanDrinks = Double(weeks.reduce(0) { $0 + $1.alcoholicCount }) / Double(weeks.count)
        let heavier = weeks.filter { Double($0.alcoholicCount) > meanDrinks }
        let lighter = weeks.filter { Double($0.alcoholicCount) <= meanDrinks }

        guard heavier.count >= configuration.minimumWeeksPerGroup,
              lighter.count >= configuration.minimumWeeksPerGroup
        else { return nil }

        let heavierWorkouts = Double(heavier.reduce(0) { $0 + $1.workoutCount }) / Double(heavier.count)
        let lighterWorkouts = Double(lighter.reduce(0) { $0 + $1.workoutCount }) / Double(lighter.count)

        guard lighterWorkouts > 0 else { return nil }

        let change = (heavierWorkouts - lighterWorkouts) / lighterWorkouts
        guard change <= -configuration.minimumRelativeEffect else { return nil }

        return HealthInsight(
            kind: .workoutDisplacement,
            metric: .workouts,
            headline: "Workouts \(HealthInsightCopy.change(change)) in heavier weeks",
            detail: HealthInsightCopy.workoutDisplacement(heavier: heavierWorkouts, lighter: lighterWorkouts),
            relativeChange: change,
            sampleCount: weeks.count
        )
    }

    // MARK: - Weekly bucketing

    /// The last `count` seven-day windows ending at the start of today, oldest
    /// first. Fixed-length windows rather than calendar weeks: the comparison is
    /// "the last four weeks", not "since Monday".
    func weekBuckets(
        count: Int,
        metric: HealthMetric,
        events: [DrinkEventSnapshot],
        activityByDay: [Date: HealthDaySample],
        asOf now: Date
    ) -> [WeekBucket] {

        let calendar = configuration.calendar
        let today = calendar.startOfDay(for: now)

        var buckets: [WeekBucket] = []

        for index in stride(from: count, to: 0, by: -1) {
            guard
                let start = calendar.date(byAdding: .day, value: -index * 7, to: today),
                let end = calendar.date(byAdding: .day, value: 7, to: start)
            else { continue }

            let alcoholic = events.reduce(into: 0) { total, event in
                guard event.type == .alcoholic else { return }
                let night = night(for: event.timestamp)
                if night >= start && night < end { total += 1 }
            }

            var activityTotal = 0.0
            var workouts = 0
            var readable = 0
            var cursor = start
            while cursor < end {
                if let sample = activityByDay[cursor], sample.hasSignal {
                    readable += 1
                    activityTotal += sample.value(for: metric)
                    workouts += sample.workoutCount
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
                cursor = next
            }

            buckets.append(
                WeekBucket(
                    start: start,
                    alcoholicCount: alcoholic,
                    activityTotal: activityTotal,
                    workoutCount: workouts,
                    readableDays: readable
                )
            )
        }

        return buckets
    }

    // MARK: - Helpers

    /// The night a timestamp belongs to. See the type doc for why 04:00.
    func night(for date: Date) -> Date {
        configuration.calendar.startOfDay(for: date.addingTimeInterval(-configuration.nightBoundary))
    }

    private func index(_ activity: [HealthDaySample], calendar: Calendar) -> [Date: HealthDaySample] {
        var byDay: [Date: HealthDaySample] = [:]
        for sample in activity {
            byDay[calendar.startOfDay(for: sample.day)] = sample
        }
        return byDay
    }

    private func mean(_ samples: [HealthDaySample], _ metric: HealthMetric) -> Double {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0.0) { $0 + $1.value(for: metric) } / Double(samples.count)
    }
}
