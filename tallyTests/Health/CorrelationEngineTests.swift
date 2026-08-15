import Foundation
import Testing
import TallyKit
@testable import tally

/// PLAN Gate 3's SPEC §4 line, as pure arithmetic:
///
/// > *(synthetic HealthKit fixtures): under-threshold data produces no insight;
/// > a ≥ 8/≥ 8-day fixture with a ≥ 20 % effect produces a card whose numbers
/// > match the fixture.*
///
/// Nothing here touches HealthKit, a device, or a dialog — `CorrelationEngine` is
/// pure and takes its samples as a parameter, so a fixture is just a list of days.
///
/// **Target setup (integrator):** written but not yet wired, exactly like
/// `tallyTests/Sync/`. `tallyTests` needs a unit-test bundle target in
/// `tally.xcodeproj` with `TEST_HOST` set to the app; Wave 3 agents are not
/// allowed to touch `project.pbxproj`. Nothing in these files changes when it
/// lands.
@Suite("Health — correlation engine")
struct CorrelationEngineTests {

    // MARK: - Fixture scaffolding

    /// UTC and Gregorian so night bucketing, day boundaries, and DST are not
    /// part of what is being asserted.
    static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Midday, so "today" is unambiguous and the engine's "yesterday's morning
    /// has finished" rule has something to exclude.
    static let now = Date(timeIntervalSince1970: 1_748_779_200) // 2025-06-01 12:00 UTC

    private var calendar: Calendar { Self.calendar }
    private var now: Date { Self.now }

    /// Start of the day `offset` days from today. Negative is the past.
    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    /// A drinking night: `count` alcoholic drinks from 21:00, half an hour apart.
    ///
    /// 21:00 minus the engine's 4 h night boundary lands the same evening, so
    /// these all belong to the night of `day(offset)` and are followed by the
    /// morning of `day(offset + 1)`. Half-hour spacing keeps them inside one
    /// `SessionDeriver` inactivity window, so the night is one Session of `count`
    /// drinks — which is what SPEC §4's threshold is written against.
    private func drinkingNight(_ offset: Int, count: Int = 3) -> [DrinkEventSnapshot] {
        let evening = day(offset).addingTimeInterval(21 * 3_600)
        return (0..<count).map { index in
            DrinkEventSnapshot(
                type: .alcoholic,
                timestamp: evening.addingTimeInterval(Double(index) * 1_800)
            )
        }
    }

    /// Activity for every day in `day(-95)...day(0)`, with `drinkingMinutes` on
    /// the mornings named in `mornings` and `baselineMinutes` everywhere else.
    ///
    /// Steps are non-zero on every day so `hasSignal` is true throughout: this
    /// fixture is about the *effect*, not about coverage holes.
    private func activity(
        mornings: Set<Int>,
        drinkingMinutes: Double,
        baselineMinutes: Double,
        workoutsOnBaselineDays: Int = 0
    ) -> [HealthDaySample] {
        (-95...0).map { offset in
            let isMorningAfter = mornings.contains(offset)
            return HealthDaySample(
                day: day(offset),
                exerciseMinutes: isMorningAfter ? drinkingMinutes : baselineMinutes,
                activeEnergyKilocalories: 400,
                stepCount: 6_000,
                workoutCount: isMorningAfter ? 0 : workoutsOnBaselineDays
            )
        }
    }

    private func engine(threshold: Int = 3) -> CorrelationEngine {
        var configuration = CorrelationEngine.Configuration.default
        configuration.morningAfterThreshold = threshold
        configuration.calendar = calendar
        return CorrelationEngine(configuration: configuration)
    }

    private func report(
        drinkingNightOffsets: [Int],
        drinkingMinutes: Double,
        baselineMinutes: Double,
        threshold: Int = 3,
        drinksPerNight: Int = 3
    ) -> HealthInsightReport {
        let events = drinkingNightOffsets.flatMap { drinkingNight($0, count: drinksPerNight) }
        let sessions = SessionDeriver().derive(events: events)
        let samples = activity(
            mornings: Set(drinkingNightOffsets.map { $0 + 1 }),
            drinkingMinutes: drinkingMinutes,
            baselineMinutes: baselineMinutes
        )
        return engine(threshold: threshold).report(
            sessions: sessions,
            events: events,
            activity: samples,
            asOf: now
        )
    }

    /// Ten drinking nights every third day, the oldest at day −29. The engine's
    /// window then runs from that first logged night to the last night whose
    /// morning has finished (day −2): 28 nights, 10 of them drinking and 18 dry.
    private static let qualifyingNights = stride(from: -2, through: -29, by: -3).map { $0 }

    /// Seven drinking nights — one short of SPEC §4's floor, on purpose.
    private static let underThresholdNights = stride(from: -2, through: -20, by: -3).map { $0 }

    // MARK: - Under-threshold silence

    @Test("Seven drinking days produce nothing at all")
    func underThresholdIsSilent() {
        let result = report(
            drinkingNightOffsets: Self.underThresholdNights,
            // A vast effect, which must not rescue an under-powered comparison:
            // SPEC §4's two guardrails are an AND, not an OR.
            drinkingMinutes: 2,
            baselineMinutes: 40
        )

        #expect(result.isEmpty)
        #expect(result.evidence.drinkingComparisons == 7)
        #expect(result.evidence.dryComparisons == 12)
        #expect(result.evidence.meetsSampleFloor == false)

        // Silence, not filler: no insight of any kind, including the two weekly
        // analyses, which the global sample floor also gates.
        #expect(result.morningAfter == nil)
        #expect(result.headlineInsight == nil)
    }

    @Test("Eight dry days are required too, not just eight drinking ones")
    func dryFloorAlsoApplies() {
        // Every night from the first logged one is a drinking night, so there is
        // nothing to compare against.
        let offsets = Array(stride(from: -2, through: -12, by: -1))
        let result = report(
            drinkingNightOffsets: offsets,
            drinkingMinutes: 10,
            baselineMinutes: 40
        )

        #expect(result.evidence.drinkingComparisons == 11)
        #expect(result.evidence.dryComparisons == 0)
        #expect(result.evidence.meetsSampleFloor == false)
        #expect(result.isEmpty)
    }

    // MARK: - The qualifying fixture

    @Test("A qualifying fixture produces the fixture's own numbers")
    func qualifyingFixtureMatchesItsNumbers() throws {
        let result = report(
            drinkingNightOffsets: Self.qualifyingNights,
            drinkingMinutes: 12,
            baselineMinutes: 34
        )

        #expect(result.evidence.drinkingComparisons == 10)
        #expect(result.evidence.dryComparisons == 18)
        #expect(result.evidence.meetsSampleFloor)
        #expect(result.evidence.metric == .exerciseMinutes)

        let insight = try #require(result.morningAfter)
        let comparison = try #require(insight.comparison)

        #expect(comparison.metric == .exerciseMinutes)
        #expect(comparison.afterDrinking == 12)
        #expect(comparison.afterDry == 34)
        #expect(comparison.drinkingDayCount == 10)
        #expect(comparison.dryDayCount == 18)
        #expect(comparison.threshold == 3)

        // SPEC §4's example sentence, generated from the fixture.
        #expect(
            insight.detail
                == "After 3+ drink Sessions, your next-day exercise averages 12 min vs your usual 34."
        )
        #expect(insight.headline == "Next-day exercise 65% lower")
        #expect(insight.relativeChange < 0)

        // The morning-after card is the only thing this fixture supports: drinks
        // are evenly spaced (no four-week drift) and it logs no workouts (no
        // displacement).
        #expect(result.insights.count == 1)
    }

    @Test("The configured threshold decides which nights count")
    func thresholdIsHonoured() {
        // Two drinks a night, against a threshold of three: no night qualifies,
        // so every one of them falls into neither group — and the drinking side
        // is empty rather than wrong.
        let events = Self.qualifyingNights.flatMap { drinkingNight($0, count: 2) }
        let samples = activity(
            mornings: Set(Self.qualifyingNights.map { $0 + 1 }),
            drinkingMinutes: 12,
            baselineMinutes: 34
        )
        let result = engine(threshold: 3).report(
            sessions: SessionDeriver().derive(events: events),
            events: events,
            activity: samples,
            asOf: now
        )

        #expect(result.evidence.drinkingComparisons == 0)
        #expect(result.isEmpty)

        // Same fixture, threshold lowered to two: the nights now qualify.
        let lowered = engine(threshold: 2).report(
            sessions: SessionDeriver().derive(events: events),
            events: events,
            activity: samples,
            asOf: now
        )
        #expect(lowered.evidence.drinkingComparisons == 10)
        #expect(lowered.morningAfter?.comparison?.threshold == 2)
    }

    // MARK: - The 20 % effect floor

    @Test("Exactly 20 % clears the floor")
    func twentyPercentQualifies() throws {
        let result = report(
            drinkingNightOffsets: Self.qualifyingNights,
            drinkingMinutes: 32,
            baselineMinutes: 40
        )

        let insight = try #require(result.morningAfter)
        #expect(insight.relativeChange == -0.2)
        #expect(insight.headline == "Next-day exercise 20% lower")
        #expect(
            insight.detail
                == "After 3+ drink Sessions, your next-day exercise averages 32 min vs your usual 40."
        )
    }

    @Test("Just under 20 % produces silence")
    func underTwentyPercentIsSilent() {
        let result = report(
            drinkingNightOffsets: Self.qualifyingNights,
            drinkingMinutes: 33,
            baselineMinutes: 40
        )

        // The data was there — this is the effect floor doing the work, not the
        // sample floor.
        #expect(result.evidence.meetsSampleFloor)
        #expect(result.evidence.drinkingComparisons == 10)
        #expect(result.isEmpty)
    }

    @Test("A higher morning-after average is reported, not suppressed")
    func positiveEffectsAreStatedToo() throws {
        // SPEC §5's tone rules cut both ways: the engine reports what it finds.
        let result = report(
            drinkingNightOffsets: Self.qualifyingNights,
            drinkingMinutes: 45,
            baselineMinutes: 30
        )

        let insight = try #require(result.morningAfter)
        #expect(insight.relativeChange == 0.5)
        #expect(insight.headline == "Next-day exercise 50% higher")
    }

    // MARK: - Coverage holes

    @Test("Days with no activity signal are holes, not zeros")
    func daysWithoutSignalAreExcluded() {
        let events = Self.qualifyingNights.flatMap { drinkingNight($0) }

        // Every morning after a drinking night is a completely blank day — phone
        // on a table, watch on a charger. Counting those as "zero minutes of
        // exercise" would manufacture a 100 % effect out of nothing.
        let mornings = Set(Self.qualifyingNights.map { $0 + 1 })
        let samples: [HealthDaySample] = (-95...0).map { offset in
            mornings.contains(offset)
                ? HealthDaySample(day: day(offset))
                : HealthDaySample(
                    day: day(offset),
                    exerciseMinutes: 34,
                    activeEnergyKilocalories: 400,
                    stepCount: 6_000
                )
        }

        let result = engine().report(
            sessions: SessionDeriver().derive(events: events),
            events: events,
            activity: samples,
            asOf: now
        )

        #expect(result.evidence.drinkingComparisons == 0)
        #expect(result.isEmpty)
    }

    @Test("No readable activity is an absent input, not a null result")
    func revokedReadsReportNoActivity() {
        let events = Self.qualifyingNights.flatMap { drinkingNight($0) }

        // What a revoked read looks like from here: HealthKit answers, and the
        // answer is zeros (SPEC §4 — it never discloses read authorization).
        let samples = (-95...0).map { HealthDaySample(day: day($0)) }

        let result = engine().report(
            sessions: SessionDeriver().derive(events: events),
            events: events,
            activity: samples,
            asOf: now
        )

        #expect(result.evidence.hasReadableActivity == false)
        #expect(result.evidence.meetsSampleFloor == false)
        #expect(result.isEmpty)
    }

    // MARK: - Night bucketing

    @Test("A Session ending after midnight belongs to the night it started")
    func afterMidnightBelongsToThePreviousNight() {
        let engine = engine()

        // 23:00 Friday and 02:00 Saturday are the same night, and both are
        // followed by Saturday.
        let lateFriday = day(-3).addingTimeInterval(23 * 3_600)
        let earlySaturday = day(-2).addingTimeInterval(2 * 3_600)

        #expect(engine.night(for: lateFriday) == day(-3))
        #expect(engine.night(for: earlySaturday) == day(-3))

        // 05:00 is past the 4 h boundary — a morning, not a night.
        #expect(engine.night(for: day(-2).addingTimeInterval(5 * 3_600)) == day(-2))
    }

    @Test("Today is never a comparison — its activity is still being recorded")
    func todayIsExcluded() {
        // One extra drinking night at day −1, whose morning is today.
        let offsets = Self.qualifyingNights + [-1]
        let result = report(
            drinkingNightOffsets: offsets,
            drinkingMinutes: 12,
            baselineMinutes: 34
        )

        #expect(result.evidence.drinkingComparisons == 10)
    }

    // MARK: - Weekly analyses

    @Test("Weekly drift needs drinks up and activity down, both by 20 %")
    func weeklyDriftRequiresBothDirections() throws {
        // Four weeks: the recent two carry twice the drinking nights of the
        // earlier two, and the exercise on their mornings is halved.
        let earlier = [-28, -25, -22, -21, -18, -15]
        let recent = [-14, -13, -11, -10, -8, -7, -6, -4, -3, -2]
        let offsets = earlier + recent

        let events = offsets.flatMap { drinkingNight($0) }
        let samples: [HealthDaySample] = (-95...0).map { offset in
            let isRecent = offset > -14
            return HealthDaySample(
                day: day(offset),
                exerciseMinutes: isRecent ? 10 : 40,
                activeEnergyKilocalories: 400,
                stepCount: 6_000
            )
        }

        let result = engine().report(
            sessions: SessionDeriver().derive(events: events),
            events: events,
            activity: samples,
            asOf: now
        )

        let drift = try #require(result.insights.first { $0.kind == .weeklyDrift })
        #expect(drift.relativeChange <= -0.20)
        #expect(drift.detail.hasPrefix("Over the last four weeks your drinks are "))
        #expect(drift.comparison == nil)
    }

    @Test("Workout displacement reports drops only")
    func workoutDisplacementReportsDrops() throws {
        // Heavier weeks are the recent ones; workouts are logged only on the
        // days of the earlier, lighter half.
        let offsets = Self.qualifyingNights + [-3, -6, -9, -12]
        let events = offsets.flatMap { drinkingNight($0) }

        let samples: [HealthDaySample] = (-95...0).map { offset in
            HealthDaySample(
                day: day(offset),
                exerciseMinutes: 30,
                activeEnergyKilocalories: 400,
                stepCount: 6_000,
                workoutCount: offset <= -30 ? 1 : 0
            )
        }

        let result = engine().report(
            sessions: SessionDeriver().derive(events: events),
            events: events,
            activity: samples,
            asOf: now
        )

        // Weeks before the first logged night hold every workout, so heavier
        // weeks average fewer — a drop, which is the only direction this
        // analysis reports.
        if let displacement = result.insights.first(where: { $0.kind == .workoutDisplacement }) {
            #expect(displacement.relativeChange <= -0.20)
            #expect(displacement.metric == .workouts)
            #expect(displacement.detail.hasPrefix("In your heavier weeks you average "))
        }

        // Whatever it found, it never invents a rise.
        for insight in result.insights where insight.kind == .workoutDisplacement {
            #expect(insight.relativeChange < 0)
        }
    }

    // MARK: - Copy

    @Test("Insight copy states correlation and never advises")
    func copyIsCorrelationOnly() throws {
        let result = report(
            drinkingNightOffsets: Self.qualifyingNights,
            drinkingMinutes: 12,
            baselineMinutes: 34
        )

        let forbidden = ["because", "should", "try ", "cut down", "too much", "bad", "unhealthy"]
        for insight in result.insights {
            let text = (insight.detail + " " + insight.headline).lowercased()
            for word in forbidden {
                #expect(!text.contains(word), "\(insight.kind) copy contains '\(word)'")
            }
        }

        #expect(HealthInsightCopy.change(-0.647) == "65% lower")
        #expect(HealthInsightCopy.change(0.2) == "20% higher")
        #expect(HealthMetric.exerciseMinutes.formatted(12.4) == "12 min")
        #expect(HealthMetric.workouts.formatted(1.0) == "1 workout")
        #expect(HealthMetric.workouts.formatted(2.4) == "2.4 workouts")
    }
}
