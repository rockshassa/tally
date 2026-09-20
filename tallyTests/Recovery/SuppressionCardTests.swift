import Foundation
import TallyKit
import Testing
@testable import tally

/// SPEC §4 and `design/fibrinolytic-suppression-chart.md` — the suppression
/// card's copy and clock, as pure logic.
///
/// The copy is the whole honesty contract of the recovery layer: it is what has
/// to say "modeled", what has to give burden and duration, and what must say
/// neither more nor less than the model supports. So the phrasing is pinned
/// here verbatim rather than eyeballed in a screenshot — `SuppressionSummary`
/// and `SuppressionTime` are view-free precisely so this file can exist without
/// a host view, a `ModelContext`, or a running clock.
///
/// The curve itself is not retested: `FibrinolysisModel` and
/// `SuppressionTimeline` are frozen and covered by
/// `TallyKit/Tests/TallyKitTests/`. What is tested here is everything this
/// workstream put on top of them.

// MARK: - Fixtures

private enum Clock {

    /// UTC Gregorian, so "2 a.m." means the same thing on every machine.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// A real zone with real daylight-saving transitions, for the cases a fixed
    /// offset cannot express.
    static let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    static let twelveHour = Locale(identifier: "en_US")
    static let twentyFourHour = Locale(identifier: "fr_FR")

    /// March 2026. The 14th is a Saturday, so the weekday words below are
    /// stable facts about the calendar, not about when the suite runs.
    static func at(_ hour: Int, _ minute: Int = 0, day: Int = 14) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    static func ny(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        newYork.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// 11 p.m. Saturday — mid-Session, which is when the card matters most.
    static let evening = at(23)
}

/// A summary stated directly, so a case like "a returned endpoint on a day that
/// is not today" can be written down instead of searched for in event logs.
private func summary(
    now: Date = Clock.evening,
    start: Date = Clock.at(21),
    peak: SuppressionSummary.Peak = .init(date: Clock.at(2, day: 15), display: 44.7),
    baselineReturn: SuppressionEndpoint = .projected(Clock.at(13, day: 15)),
    state: SuppressionTimeline.State = .rising,
    isComplete: Bool = false,
    isHistoryComplete: Bool = true
) -> SuppressionSummary {
    SuppressionSummary(
        now: now,
        start: start,
        peak: peak,
        baselineReturn: baselineReturn,
        state: state,
        isComplete: isComplete,
        isHistoryComplete: isHistoryComplete
    )
}

private func facts(_ summary: SuppressionSummary, locale: Locale = Clock.twelveHour) -> [SuppressionSummary.Fact] {
    summary.facts(calendar: Clock.calendar, locale: locale)
}

private func line(_ summary: SuppressionSummary, locale: Locale = Clock.twelveHour) -> String {
    summary.voiceOverSummary(calendar: Clock.calendar, locale: locale)
}

private func drinks(_ hoursAgo: [Double], from now: Date, type: DrinkType = .alcoholic) -> [DrinkEventSnapshot] {
    hoursAgo.map { DrinkEventSnapshot(type: type, timestamp: now.addingTimeInterval(-$0 * 3600)) }
}

// MARK: - Fixed copy

@Suite("Suppression copy")
struct SuppressionCopyTests {

    @Test("The header names the model, every time")
    func header() {
        #expect(SuppressionSummary.header == "Modeled fibrinolytic suppression")
        #expect(SuppressionSummary.yAxisLabel == "Modeled suppression above baseline")
        #expect(SuppressionSummary.endpointLabel == "0 · modeled baseline")
    }

    @Test("The four state words, and only those four")
    func stateWords() {
        let expected: [SuppressionTimeline.State: String] = [
            .riseAhead: "Rise ahead",
            .rising: "Rising",
            .easing: "Easing",
            .atBaseline: "At modeled baseline"
        ]

        for state in SuppressionTimeline.State.allCases {
            #expect(summary(state: state).stateText == expected[state])
        }
    }

    @Test("The forecast says what it assumes")
    func forecastFootnote() {
        #expect(summary().footnote == "Based on logged drinks; assumes no additional drinks")
        // A finished episode forecasts nothing, so it promises nothing.
        #expect(summary(baselineReturn: .returned(Clock.at(13)), isComplete: true).footnote == nil)
    }

    @Test("Zero is explained as the model's own band, not as a measurement")
    func infoText() {
        #expect(
            SuppressionSummary.infoText
                == "Zero on this chart means the model is within its baseline range. It is not a measured biological value."
        )
    }
}

// MARK: - The three facts

@Suite("Suppression facts")
struct SuppressionFactsTests {

    @Test("First drink, peak ahead, baseline ahead — the ordinary night")
    func projected() {
        let all = facts(summary())

        #expect(all.map(\.label) == ["First drink", "Peak", "Baseline"])
        #expect(all[0].value == "9:00 p.m.")
        #expect(all[1].value == "~2 a.m. tomorrow")
        #expect(all[2].value == "~1 p.m. tomorrow")
    }

    @Test("Once they are behind us, the peak and the return change tense")
    func returned() {
        let all = facts(
            summary(
                now: Clock.at(16, day: 15),
                peak: .init(date: Clock.at(2, day: 15), display: 44.7),
                baselineReturn: .returned(Clock.at(13, day: 15)),
                state: .atBaseline,
                isComplete: true
            )
        )

        #expect(all.map(\.label) == ["First drink", "Peaked", "Returned"])
        #expect(all[0].value == "9:00 p.m. yesterday")
        #expect(all[1].value == "~2 a.m.")
        #expect(all[2].value == "~1 p.m.")
    }

    @Test("An endpoint the model could not find is missing, never invented")
    func unavailable() {
        let all = facts(summary(baselineReturn: .unavailable))

        #expect(all[2].label == "Baseline")
        #expect(all[2].value == "Return not modeled")
        // Nothing that reads as a time, and nothing that reads as a zero.
        #expect(!all[2].value.contains("~"))
        #expect(!all[2].value.contains(":"))
    }

    @Test("History that may not reach far enough back does not claim a first drink")
    func incompleteHistory() {
        let all = facts(summary(isHistoryComplete: false))

        #expect(all[0].label == "Available history")
        #expect(all[0].value == "9:00 p.m.")
    }

    @Test("The peak's tense comes from the clock, not from the episode's shape")
    func peakTense() {
        #expect(facts(summary(peak: .init(date: Clock.at(22), display: 12)))[1].label == "Peaked")
        #expect(facts(summary(peak: .init(date: Clock.at(23), display: 12)))[1].label == "Peaked")
        #expect(facts(summary(peak: .init(date: Clock.at(23, 1), display: 12)))[1].label == "Peak")
    }

    @Test("A capped peak is described as the interval it is")
    func plateau() {
        let described = summary(
            peak: .init(date: Clock.at(2, day: 15), display: 97, plateauEnd: Clock.at(5, day: 15))
        )
        .plateauText(calendar: Clock.calendar, locale: Clock.twelveHour)

        #expect(described == "Modeled at its ceiling from ~2 a.m. tomorrow to ~5 a.m. tomorrow")
        #expect(summary().plateauText(calendar: Clock.calendar, locale: Clock.twelveHour) == nil)
    }

    @Test("A finished episode says so where the Now rule used to be")
    func completion() {
        let text = summary(
            now: Clock.at(16, day: 15),
            baselineReturn: .returned(Clock.at(13, day: 15)),
            state: .atBaseline,
            isComplete: true
        )
        .completionText(calendar: Clock.calendar, locale: Clock.twelveHour)

        #expect(text == "Returned to modeled baseline ~1 p.m.")
        // A running episode has a Now rule, so it has nothing to replace it with.
        #expect(summary().completionText(calendar: Clock.calendar, locale: Clock.twelveHour) == nil)
    }
}

// MARK: - Honesty rules

@Suite("Suppression honesty")
struct SuppressionHonestyTests {

    @Test("Every spoken form carries the word 'modeled' (SPEC §4, non-negotiable)")
    func alwaysSaysModeled() {
        let all = [
            summary(),
            summary(state: .riseAhead),
            summary(state: .atBaseline, isComplete: true, isHistoryComplete: false),
            summary(baselineReturn: .unavailable),
            summary(baselineReturn: .returned(Clock.at(13)), state: .easing, isComplete: true)
        ]

        for candidate in all {
            #expect(line(candidate).hasPrefix("Modeled fibrinolytic suppression. "))
            #expect(line(candidate).lowercased().contains("modeled"))
        }
    }

    @Test("Nothing in the copy is a percentage or a raw model index")
    func neverAPercentageOrTheIndex() {
        // The index is dimensionless and the display scale is baseline-relative;
        // printing either as a figure would be the clot-risk score SPEC §4
        // forbids. Only clock times may be digits.
        let derived = summary(peak: .init(date: Clock.at(2, day: 15), display: 44.7))
        let copy = line(derived) + facts(derived).map { $0.label + $0.value }.joined()

        #expect(!copy.contains("%"))
        #expect(!copy.contains("44"))   // the display value
        #expect(!copy.contains("47"))   // the raw index behind it
        #expect(!copy.contains("percent"))
    }

    @Test("The inspection readout names the scale it is on, and is not a percentage")
    func readout() {
        let text = SuppressionSummary.readout(
            display: 18.4,
            at: Clock.at(2, 15, day: 15),
            relativeTo: Clock.evening,
            calendar: Clock.calendar,
            locale: Clock.twelveHour
        )

        #expect(text == "Modeled 18 above baseline · 2:15 a.m. tomorrow")
        #expect(!text.contains("%"))
    }

    @Test("VoiceOver hears the start, the peak, the state, and the return")
    func voiceOver() {
        let spoken = line(summary())

        #expect(
            spoken == """
                Modeled fibrinolytic suppression. Rising. First drink 9:00 p.m. \
                Peak ~2 a.m. tomorrow. Baseline ~1 p.m. tomorrow.
                """
        )
        #expect(!spoken.contains("·"))
    }

    @Test("A capped peak reaches VoiceOver too")
    func voiceOverPlateau() {
        let spoken = line(
            summary(peak: .init(date: Clock.at(2, day: 15), display: 97, plateauEnd: Clock.at(5, day: 15)))
        )

        #expect(spoken.contains("Modeled at its ceiling from ~2 a.m. tomorrow to ~5 a.m. tomorrow."))
    }
}

// MARK: - Time formatting

@Suite("Suppression time formatting")
struct SuppressionTimeTests {

    private func text(
        _ date: Date,
        now: Date = Clock.evening,
        calendar: Calendar = Clock.calendar,
        locale: Locale = Clock.twelveHour
    ) -> String {
        SuppressionTime.approximate(date, relativeTo: now, calendar: calendar, locale: locale)
    }

    private func logged(
        _ date: Date,
        now: Date = Clock.evening,
        calendar: Calendar = Clock.calendar,
        locale: Locale = Clock.twelveHour
    ) -> String {
        SuppressionTime.exact(date, relativeTo: now, calendar: calendar, locale: locale)
    }

    @Test("Modeled hours wear a tilde, because the model cannot support minutes")
    func wholeHours() {
        #expect(text(Clock.at(2)) == "~2 a.m.")
        #expect(text(Clock.at(21)) == "~9 p.m.")
    }

    @Test("Rounds to the nearest hour in both directions")
    func rounding() {
        #expect(text(Clock.at(1, 40, day: 15)) == "~2 a.m. tomorrow")
        #expect(text(Clock.at(2, 20, day: 15)) == "~2 a.m. tomorrow")
        #expect(text(Clock.at(2, 29, day: 15)) == "~2 a.m. tomorrow")
        #expect(text(Clock.at(2, 30, day: 15)) == "~3 a.m. tomorrow")
    }

    @Test("Noon and midnight read as 12, not as 0")
    func twelves() {
        #expect(text(Clock.at(12, day: 15)) == "~12 p.m. tomorrow")
        #expect(text(Clock.at(0, day: 15)) == "~12 a.m. tomorrow")
    }

    @Test("Rounding that crosses midnight takes the next day's name with it")
    func roundingAcrossMidnight() {
        // 11:40 p.m. today is midnight tomorrow once it is rounded, and the day
        // word has to describe where the rounded time actually landed.
        #expect(text(Clock.at(23, 40)) == "~12 a.m. tomorrow")
        #expect(text(Clock.at(23, 20)) == "~11 p.m.")
    }

    @Test("A 24-hour locale keeps its clock")
    func twentyFourHourLocale() {
        #expect(text(Clock.at(13, day: 15), locale: Clock.twentyFourHour) == "~13:00 tomorrow")
        #expect(text(Clock.at(2, day: 15), locale: Clock.twentyFourHour) == "~2:00 tomorrow")
        #expect(logged(Clock.at(21, 5), locale: Clock.twentyFourHour) == "21:05")
    }

    @Test("A logged drink keeps the precision it was logged with")
    func loggedPrecision() {
        #expect(logged(Clock.at(21, 5)) == "9:05 p.m.")
        #expect(logged(Clock.at(21, 5, day: 13)) == "9:05 p.m. yesterday")
        #expect(logged(Clock.at(21, 5, day: 12)) == "9:05 p.m. Thursday")
        #expect(!logged(Clock.at(21, 5)).contains("~"))
    }

    @Test("Day words come from the calendar, not from an elapsed-hours threshold")
    func dayAware() {
        // Same calendar day, however far away on the clock.
        #expect(text(Clock.at(1)) == "~1 a.m.")
        #expect(text(Clock.at(23)) == "~11 p.m.")
        // The old rolling window called anything under 18 h "today"; 1 p.m.
        // tomorrow is 14 h out and is still tomorrow.
        #expect(text(Clock.at(13, day: 15)) == "~1 p.m. tomorrow")
        #expect(text(Clock.at(18, day: 15)) == "~6 p.m. tomorrow")
        #expect(text(Clock.at(10, day: 13)) == "~10 a.m. yesterday")
    }

    @Test("Beyond tomorrow it is a weekday; beyond a week it is a date")
    func weekdaysAndDates() {
        // Saturday the 14th: the 17th is a Tuesday, the 20th a Friday.
        #expect(text(Clock.at(9, day: 17)) == "~9 a.m. Tuesday")
        #expect(text(Clock.at(9, day: 20)) == "~9 a.m. Friday")
        #expect(text(Clock.at(9, day: 11)) == "~9 a.m. Wednesday")

        // Seven days out, a bare weekday would repeat the one we are standing on.
        let far = text(Clock.at(9, day: 21))
        #expect(far.hasPrefix("~9 a.m. "))
        #expect(far.contains("Sat"))
        #expect(far.contains("Mar"))
        #expect(far.contains("21"))
    }

    @Test("A spring-forward day is still one day, and never quotes an hour that does not exist")
    func daylightSavingSpringForward() {
        // 8 March 2026, 2 a.m. EST → 3 a.m. EDT: a 23-hour day.
        let saturdayNight = Clock.ny(3, 7, 22)

        // 14 real hours later, but the next calendar day all the same.
        #expect(text(Clock.ny(3, 8, 13), now: saturdayNight, calendar: Clock.newYork) == "~1 p.m. tomorrow")
        // 1:30 a.m. rounds into the hour the clock skipped, so it reports the
        // hour that actually exists.
        #expect(text(Clock.ny(3, 8, 1, 30), now: saturdayNight, calendar: Clock.newYork) == "~3 a.m. tomorrow")
        #expect(logged(Clock.ny(3, 8, 1, 30), now: saturdayNight, calendar: Clock.newYork) == "1:30 a.m. tomorrow")
    }

    @Test("A fall-back day is one day too, though it is 25 hours long")
    func daylightSavingFallBack() {
        // 1 November 2026, 2 a.m. EDT → 1 a.m. EST.
        let saturdayNight = Clock.ny(10, 31, 22)

        #expect(text(Clock.ny(11, 1, 13), now: saturdayNight, calendar: Clock.newYork) == "~1 p.m. tomorrow")
        #expect(text(Clock.ny(11, 2, 13), now: saturdayNight, calendar: Clock.newYork) == "~1 p.m. Monday")
    }

    @Test("Locale clock detection")
    func clockDetection() {
        #expect(SuppressionTime.uses12HourClock(Clock.twelveHour))
        #expect(!SuppressionTime.uses12HourClock(Clock.twentyFourHour))
    }
}

// MARK: - X axis

@Suite("Suppression axis labels")
struct SuppressionAxisTests {

    private func ticks(
        from: Date,
        to: Date,
        calendar: Calendar = Clock.calendar
    ) -> [SuppressionTime.AxisTick] {
        SuppressionTime.axisTicks(in: from...to, calendar: calendar, locale: Clock.twelveHour)
    }

    @Test("Four to six labels, whatever the episode's span")
    func count() {
        let spans: [(Date, Date)] = [
            (Clock.at(22), Clock.at(16, day: 15)),          // 18 h — one drink
            (Clock.at(20), Clock.at(8, day: 17)),           // ~2.5 days
            (Clock.at(20), Clock.at(8, day: 22)),           // ~8 days
            (Clock.at(20), Clock.at(8, day: 29))            // ~2 weeks
        ]

        for (from, to) in spans {
            let marks = ticks(from: from, to: to)
            #expect(marks.count >= SuppressionTime.minimumTicks)
            #expect(marks.count <= SuppressionTime.maximumTicks)
        }
    }

    @Test("Midnight is labelled with the day it opens")
    func dayBoundaries() {
        let marks = ticks(from: Clock.at(22), to: Clock.at(16, day: 15))
        let midnight = marks.first { $0.isDayBoundary }

        #expect(midnight != nil)
        #expect(midnight?.text == "Sun")
        #expect(marks.filter { !$0.isDayBoundary }.allSatisfy { $0.text.contains(":") == false })
    }

    @Test("Labels stay inside the plotted range and in order")
    func bounds() {
        let range = Clock.at(22)...Clock.at(16, day: 15)
        let marks = SuppressionTime.axisTicks(in: range, calendar: Clock.calendar, locale: Clock.twelveHour)

        #expect(marks.allSatisfy { range.contains($0.date) })
        #expect(marks.map(\.date) == marks.map(\.date).sorted())
    }

    @Test("A daylight-saving day keeps wall-clock labels and never repeats one")
    func daylightSaving() {
        let marks = ticks(from: Clock.ny(3, 7, 20), to: Clock.ny(3, 8, 20), calendar: Clock.newYork)

        #expect(marks.count >= SuppressionTime.minimumTicks)
        #expect(marks.count <= SuppressionTime.maximumTicks)
        #expect(Set(marks.map(\.date)).count == marks.count)
        for mark in marks {
            #expect(Clock.newYork.component(.minute, from: mark.date) == 0)
        }
    }
}

// MARK: - Derivation from the event log

@Suite("Suppression summary derivation")
struct SuppressionSummaryDerivationTests {

    private let model = FibrinolysisModel()

    private func timeline(
        _ events: [DrinkEventSnapshot],
        now: Date = Clock.evening,
        historyStart: Date? = nil
    ) -> SuppressionTimeline? {
        SuppressionTimeline.make(now: now, events: events, model: model, historyStart: historyStart)
    }

    @Test("Empty and non-alcoholic-only logs render no card at all")
    func nothingToShow() {
        #expect(timeline([]) == nil)
        #expect(timeline(drinks([1, 2, 3], from: Clock.evening, type: .nonAlcoholic)) == nil)
        // A drink dated in the future has not happened, so it starts nothing.
        #expect(timeline(drinks([-4], from: Clock.evening)) == nil)
    }

    @Test("Immediately after the first drink: the opening delay reads as a rise ahead")
    func firstDrink() throws {
        let derived = SuppressionSummary(try #require(timeline(drinks([0.2], from: Clock.evening))))

        #expect(derived.stateText == "Rise ahead")
        #expect(derived.footnote == SuppressionSummary.forecastFootnote)

        let all = facts(derived)
        #expect(all.map(\.label) == ["First drink", "Peak", "Baseline"])
        // The peak is ~4 h out and the return ~18 h out, both on the next day.
        #expect(all[1].value.hasSuffix("tomorrow"))
        #expect(all[2].value.hasSuffix("tomorrow"))
    }

    @Test("The next morning still shows the same first drink, and the peak it passed")
    func nextMorning() throws {
        let events = drinks([0, 1, 2], from: Clock.at(22))
        let derived = SuppressionSummary(try #require(timeline(events, now: Clock.at(8, day: 15))))

        #expect(derived.start == Clock.at(20))
        #expect(derived.stateText == "Easing")
        #expect(facts(derived)[0].value == "8:00 p.m. yesterday")
        #expect(facts(derived)[1].label == "Peaked")
    }

    @Test("A completed episode is retained, says 'Returned', and forecasts nothing")
    func completed() throws {
        let events = drinks([0], from: Clock.at(20))
        // One drink returns to baseline ~17.9 h on; 24 h on it is complete and
        // still inside its retention window.
        let derived = SuppressionSummary(try #require(timeline(events, now: Clock.at(20, day: 15))))

        #expect(derived.isComplete)
        #expect(derived.stateText == "At modeled baseline")
        #expect(facts(derived)[2].label == "Returned")
        #expect(derived.footnote == nil)
        #expect(derived.completionText(calendar: Clock.calendar, locale: Clock.twelveHour) != nil)
    }

    @Test("Past its retention window the card is gone")
    func retentionExpires() {
        let events = drinks([0], from: Clock.at(20))
        // Return ~13:54 on the 15th; retained until ~13:54 on the 16th.
        #expect(timeline(events, now: Clock.at(12, day: 16)) != nil)
        #expect(timeline(events, now: Clock.at(16, day: 16)) == nil)
    }

    @Test("An episode longer than the old 66-hour cutoff keeps its first drink")
    func longEpisode() throws {
        // Four evenings running: each night's drinks land before the previous
        // night's modeled return, so this is one episode, not four.
        let events = (0..<4).flatMap { night in
            drinks([0, 1, 2].map { $0 - Double(night) * 24 }, from: Clock.at(22, day: 11))
        }
        let derived = SuppressionSummary(try #require(timeline(events, now: Clock.at(10, day: 15))))

        #expect(derived.start == Clock.at(20, day: 11))
        #expect(facts(derived)[0].label == "First drink")
        #expect(facts(derived)[0].value.contains("Wednesday"))
    }

    @Test("History that may not reach back far enough says 'Available history'")
    func incompleteHistory() throws {
        let events = drinks([1, 2], from: Clock.evening)
        let fetched = Clock.evening.addingTimeInterval(-3 * 3600)
        let derived = SuppressionSummary(try #require(timeline(events, historyStart: fetched)))

        #expect(!derived.isHistoryComplete)
        #expect(facts(derived)[0].label == "Available history")
    }

    @Test("Undo and timestamp edits produce a different summary, at the same event count")
    func edits() throws {
        let original = drinks([1, 2, 3], from: Clock.evening)
        let moved = original.enumerated().map { index, event in
            index == 0
                ? DrinkEventSnapshot(id: event.id, type: event.type, timestamp: event.timestamp.addingTimeInterval(-6 * 3600))
                : event
        }

        let before = SuppressionSummary(try #require(timeline(original)))
        let after = SuppressionSummary(try #require(timeline(moved)))

        #expect(before != after)
        #expect(original.count == moved.count)

        // Undoing the first drink moves the episode's origin.
        let undone = SuppressionSummary(try #require(timeline(Array(original.dropLast()))))
        #expect(undone.start != before.start)
    }
}

// MARK: - Contract with the UI test suite

@Suite("Suppression card identifiers")
struct SuppressionCardIdentifierTests {

    @Test("The identifiers the XCUITest suite drives")
    func identifiers() {
        #expect(SuppressionCardA11y.card == "tally.suppressionCard")
        #expect(SuppressionCardA11y.detailSheet == "tally.suppressionDetail")
        #expect(HistoryRecoveryA11y.timelineRow == "history.recoveryTimeline")
    }
}
