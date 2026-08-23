import Foundation
import TallyKit
import Testing
@testable import tally

/// SPEC §4 — the suppression curve card's copy, as pure logic.
///
/// The caption is the whole honesty contract of the recovery layer: it is the
/// sentence that has to say "modeled", has to give burden and duration, and has
/// to say neither more nor less than the model supports. So the phrasing is
/// pinned here verbatim rather than eyeballed in a screenshot — `SuppressionSummary`
/// and `SuppressionTime` are view-free precisely so this file can exist without
/// a host view, a `ModelContext`, or a running clock.
///
/// The curve itself is not retested: `FibrinolysisModel` is frozen and covered
/// by `TallyKit/Tests/TallyKitTests/FibrinolysisModelTests.swift`. What is
/// tested here is everything this workstream added on top of it.

// MARK: - Fixtures

private enum Clock {

    /// UTC Gregorian, so "2 a.m." means the same thing on every machine.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static let twelveHour = Locale(identifier: "en_US")
    static let twentyFourHour = Locale(identifier: "fr_FR")

    /// 14–15 March 2026, the two days every case below happens across.
    static func at(_ hour: Int, _ minute: Int = 0, day: Int = 14) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    /// 11 p.m. — mid-Session, which is when the card matters most.
    static let evening = at(23)
}

private func summary(
    index: Double = 0,
    isAboveBaseline: Bool = false,
    phase: SuppressionSummary.Phase = .baseline,
    peak: SuppressionSummary.Peak? = nil,
    baselineReturn: Date? = nil,
    hasRecentIntake: Bool = false
) -> SuppressionSummary {
    SuppressionSummary(
        index: index,
        isAboveBaseline: isAboveBaseline,
        phase: phase,
        peak: peak,
        baselineReturn: baselineReturn,
        hasRecentIntake: hasRecentIntake
    )
}

private func caption(_ summary: SuppressionSummary, now: Date = Clock.evening) -> String {
    summary.caption(now: now, calendar: Clock.calendar, locale: Clock.twelveHour)
}

private func drinks(_ hoursAgo: [Double], from now: Date, type: DrinkType = .alcoholic) -> [DrinkEventSnapshot] {
    hoursAgo.map { DrinkEventSnapshot(type: type, timestamp: now.addingTimeInterval(-$0 * 3600)) }
}

// MARK: - Caption copy

@Suite("Suppression caption")
struct SuppressionCaptionTests {

    @Test("The SPEC's own line, verbatim")
    func risingMatchesSpec() {
        let line = caption(
            summary(
                index: 28,
                isAboveBaseline: true,
                phase: .rising,
                peak: .init(date: Clock.at(2, day: 15), index: 44),
                baselineReturn: Clock.at(13, day: 15),
                hasRecentIntake: true
            )
        )

        #expect(line == "Modeled fibrinolytic suppression: elevated · peaks ~2 a.m. · baseline ~1 p.m.")
    }

    @Test("Falling reports the descent and the return, not a peak that is behind us")
    func falling() {
        let line = caption(
            summary(
                index: 22,
                isAboveBaseline: true,
                phase: .falling,
                baselineReturn: Clock.at(13, day: 15),
                hasRecentIntake: true
            )
        )

        #expect(line == "Modeled fibrinolytic suppression: elevated · easing · baseline ~1 p.m.")
        #expect(!line.contains("peaks"))
    }

    @Test("Baseline says so and stops — no duration to promise")
    func baseline() {
        let line = caption(summary(index: 1.2, hasRecentIntake: true))

        #expect(line == "Modeled fibrinolytic suppression: at baseline")
    }

    @Test("The absorption window reads as rising, not as elevated")
    func risingBeforeTheIndexClearsBaseline() {
        // The first ~45 minutes after a drink: the curve is climbing but the
        // index is still at zero. "Elevated" would be a lie, "at baseline"
        // would be misleading.
        let line = caption(
            summary(
                index: 0,
                isAboveBaseline: false,
                phase: .rising,
                peak: .init(date: Clock.at(3, day: 15), index: 18),
                hasRecentIntake: true
            )
        )

        #expect(line == "Modeled fibrinolytic suppression: rising · peaks ~3 a.m.")
    }

    @Test("Every variant carries the word 'modeled' (SPEC §4, non-negotiable)")
    func alwaysSaysModeled() {
        let all = [
            summary(hasRecentIntake: true),
            summary(index: 30, isAboveBaseline: true, phase: .rising,
                    peak: .init(date: Clock.at(2, day: 15), index: 40),
                    baselineReturn: Clock.at(13, day: 15), hasRecentIntake: true),
            summary(index: 30, isAboveBaseline: true, phase: .falling,
                    baselineReturn: Clock.at(13, day: 15), hasRecentIntake: true)
        ]

        for candidate in all {
            #expect(caption(candidate).hasPrefix("Modeled fibrinolytic suppression: "))
        }
    }

    @Test("Nothing in the copy is a number on a scale")
    func neverPrintsTheIndex() {
        // The index is dimensionless and capped at 100; printing it would be
        // the clot-risk score SPEC §4 forbids. Only clock times may be digits.
        let line = caption(
            summary(index: 73.4, isAboveBaseline: true, phase: .falling,
                    baselineReturn: Clock.at(13, day: 15), hasRecentIntake: true)
        )

        #expect(!line.contains("73"))
    }

    @Test("VoiceOver hears pauses where the interpuncts are")
    func spokenForm() {
        let spoken = summary(
            index: 28,
            isAboveBaseline: true,
            phase: .rising,
            peak: .init(date: Clock.at(2, day: 15), index: 44),
            baselineReturn: Clock.at(13, day: 15),
            hasRecentIntake: true
        )
        .spokenCaption(now: Clock.evening, calendar: Clock.calendar, locale: Clock.twelveHour)

        #expect(spoken == "Modeled fibrinolytic suppression: elevated, peaks ~2 a.m., baseline ~1 p.m.")
        #expect(!spoken.contains("·"))
    }
}

// MARK: - Time formatting

@Suite("Suppression time formatting")
struct SuppressionTimeTests {

    private func text(_ date: Date, now: Date = Clock.evening, locale: Locale = Clock.twelveHour) -> String {
        SuppressionTime.approximate(date, relativeTo: now, calendar: Clock.calendar, locale: locale)
    }

    @Test("Hours wear a tilde, because the model cannot support minutes")
    func wholeHours() {
        #expect(text(Clock.at(2, day: 15)) == "~2 a.m.")
        #expect(text(Clock.at(13, day: 15)) == "~1 p.m.")
    }

    @Test("Rounds to the nearest hour in both directions")
    func rounding() {
        #expect(text(Clock.at(1, 40, day: 15)) == "~2 a.m.")
        #expect(text(Clock.at(2, 20, day: 15)) == "~2 a.m.")
        #expect(text(Clock.at(2, 29, day: 15)) == "~2 a.m.")
        #expect(text(Clock.at(2, 30, day: 15)) == "~3 a.m.")
    }

    @Test("Noon and midnight read as 12, not as 0")
    func twelves() {
        #expect(text(Clock.at(12, day: 15)) == "~12 p.m.")
        #expect(text(Clock.at(0, day: 15)) == "~12 a.m.")
    }

    @Test("A 24-hour locale keeps its clock")
    func twentyFourHourLocale() {
        #expect(text(Clock.at(13, day: 15), locale: Clock.twentyFourHour) == "~13:00")
        #expect(text(Clock.at(2, day: 15), locale: Clock.twentyFourHour) == "~2:00")
    }

    @Test("Far enough ahead that a bare hour would be ambiguous, it gets a day")
    func tomorrow() {
        // 11 p.m. Friday → 6 p.m. Saturday is 19 h out, past the threshold.
        #expect(text(Clock.at(18, day: 15)) == "~6 p.m. tomorrow")
        // …but the usual overnight case stays clean.
        #expect(text(Clock.at(13, day: 15)) == "~1 p.m.")
    }

    @Test("Locale clock detection")
    func clockDetection() {
        #expect(SuppressionTime.uses12HourClock(Clock.twelveHour))
        #expect(!SuppressionTime.uses12HourClock(Clock.twentyFourHour))
    }
}

// MARK: - Derivation from the event log

@Suite("Suppression summary derivation")
struct SuppressionSummaryTests {

    private func make(_ events: [DrinkEventSnapshot], now: Date = Clock.evening) -> SuppressionSummary {
        SuppressionSummary.make(now: now, events: events)
    }

    @Test("An empty log has nothing to say and no card to say it on")
    func emptyLog() {
        let derived = make([])

        #expect(derived.phase == .baseline)
        #expect(!derived.hasRecentIntake)
        #expect(!derived.shouldRender)
    }

    @Test("A compressed evening two hours back is rising toward a peak still ahead")
    func rising() {
        let derived = make(drinks([3, 2.5, 2], from: Clock.evening))

        #expect(derived.phase == .rising)
        #expect(derived.isAboveBaseline)
        #expect(derived.level == "elevated")
        #expect((derived.peak?.date ?? .distantPast) > Clock.evening)
        #expect(derived.shouldRender)
    }

    @Test("A drink inside the absorption window is rising from zero")
    func absorbing() {
        let derived = make(drinks([0.5], from: Clock.evening))

        #expect(derived.index == 0)
        #expect(!derived.isAboveBaseline)
        #expect(derived.phase == .rising)
        #expect(derived.level == "rising")
        #expect(derived.shouldRender)
    }

    @Test("Past the peak, the card switches to the return time")
    func falling() {
        let derived = make(drinks([8, 7.5, 7], from: Clock.evening))

        #expect(derived.phase == .falling)
        #expect(derived.isAboveBaseline)
        #expect(derived.baselineReturn != nil)
        #expect(derived.shouldRender)
    }

    @Test("Yesterday's drink still counts as recent even once the curve is flat")
    func decayedButRecent() {
        // 20 h on, one drink models below the baseline threshold — but SPEC §4
        // still wants the card, because *something happened today*.
        let derived = make(drinks([20], from: Clock.evening))

        #expect(derived.phase == .baseline)
        #expect(derived.hasRecentIntake)
        #expect(derived.shouldRender)
        #expect(caption(derived) == "Modeled fibrinolytic suppression: at baseline")
    }

    @Test("Zero footprint: nothing recent and nothing raised means no card")
    func staleLog() {
        let derived = make(drinks([30], from: Clock.evening))

        #expect(derived.phase == .baseline)
        #expect(!derived.hasRecentIntake)
        #expect(!derived.shouldRender)
    }

    @Test("NA drinks contribute nothing and do not summon the card")
    func nonAlcoholicIsInvisibleHere() {
        let derived = make(drinks([1, 2, 3], from: Clock.evening, type: .nonAlcoholic))

        #expect(derived.index == 0)
        #expect(!derived.hasRecentIntake)
        #expect(!derived.shouldRender)
    }

    @Test("Only the events the model can still feel are handed to it")
    func trimsTheLog() {
        // Guards a performance cliff, not a display bug: the model weighs every
        // drink against every other, so passing the whole store would make the
        // card quadratic in the size of the event log.
        let events = drinks([1, 10, 50, 80, 400], from: Clock.evening)
        let relevant = SuppressionSummary.relevantEvents(events, now: Clock.evening)

        #expect(relevant.count == 3)
        #expect(relevant.allSatisfy { $0.type == .alcoholic })
    }
}

// MARK: - Contract with the UI test suite

@Suite("Suppression card identifiers")
struct SuppressionCardIdentifierTests {

    @Test("The identifier the XCUITest suite drives")
    func identifier() {
        #expect(SuppressionCardA11y.card == "tally.suppressionCard")
    }
}
