import Foundation
import Testing
@testable import TallyKit

/// Gate 0 invariants for `ScoringEngine` (PLAN Wave 0, SPEC §3).
@Suite("ScoringEngine")
struct ScoringEngineTests {

    let engine = ScoringEngine(configuration: ScoringEngine.Configuration(calendar: Fixture.calendar))
    let deriver = SessionDeriver()

    private func session(_ events: [DrinkEventSnapshot]) -> DerivedSession {
        deriver.derive(events: events)[0]
    }

    // MARK: - Spacers (SPEC §3)

    @Test("An NA drink between two alcoholic drinks is a spacer")
    func spacerBetweenTwoDrinks() {
        let events = [
            Fixture.event(1, hours: 0, .alcoholic),
            Fixture.event(2, hours: 0.5, .nonAlcoholic),
            Fixture.event(3, hours: 1, .alcoholic)
        ]
        #expect(ScoringEngine.spacerCount(in: events) == 1)
        #expect(session(events).spacerCount == 1)
        #expect(session(events).spacerEventIDs == [Fixture.uuid(2)])
    }

    @Test("An NA drink before the first or after the last alcoholic drink is not a spacer")
    func naOutsideTheAlcoholRangeIsNotASpacer() {
        let events = [
            Fixture.event(1, hours: 0, .nonAlcoholic),
            Fixture.event(2, hours: 0.5, .alcoholic),
            Fixture.event(3, hours: 1, .alcoholic),
            Fixture.event(4, hours: 1.5, .nonAlcoholic)
        ]
        #expect(ScoringEngine.spacerCount(in: events) == 0)
    }

    @Test("Two NA drinks between the same pair count as two spacers")
    func consecutiveSpacersBothCount() {
        let events = [
            Fixture.event(1, hours: 0, .alcoholic),
            Fixture.event(2, hours: 0.3, .nonAlcoholic),
            Fixture.event(3, hours: 0.6, .nonAlcoholic),
            Fixture.event(4, hours: 1, .alcoholic)
        ]
        #expect(ScoringEngine.spacerCount(in: events) == 2)
    }

    @Test("A Session with no alcohol has no spacers")
    func allNonAlcoholicHasNoSpacers() {
        let events = (1...3).map { Fixture.event($0, hours: Double($0) * 0.5, .nonAlcoholic) }
        #expect(ScoringEngine.spacerCount(in: events) == 0)
    }

    // MARK: - Points (SPEC §3)

    @Test("+10 per NA drink, +25 per spacer, +50 for finishing at ≥ 1:1")
    func pointsForABalancedSession() {
        let events = [
            Fixture.event(1, hours: 0, .alcoholic),
            Fixture.event(2, hours: 0.5, .nonAlcoholic),
            Fixture.event(3, hours: 1, .alcoholic),
            Fixture.event(4, hours: 1.5, .nonAlcoholic)
        ]
        let derived = session(events)
        let score = engine.score(derived, asOf: Fixture.at(5))

        #expect(derived.alcoholicCount == 2)
        #expect(derived.nonAlcoholicCount == 2)
        #expect(derived.spacerCount == 1)
        #expect(score.nonAlcoholicPoints == 20)
        #expect(score.spacerPoints == 25)
        #expect(score.balancedSessionPoints == 50)
        #expect(score.total == 95)
    }

    @Test("Nothing ever awards points for alcohol")
    func alcoholOnlySessionScoresZero() {
        let events = (1...4).map { Fixture.event($0, hours: Double($0) * 0.5, .alcoholic) }
        let score = engine.score(session(events), asOf: Fixture.at(10))
        #expect(score.total == 0)
        #expect(score.balancedSessionPoints == 0)
    }

    @Test("The +50 lands only once the Session has finished")
    func balancedBonusRequiresAFinishedSession() {
        let events = [
            Fixture.event(1, hours: 0, .alcoholic),
            Fixture.event(2, hours: 0.5, .nonAlcoholic)
        ]
        let derived = session(events)

        let live = engine.score(derived, asOf: Fixture.at(1))
        #expect(live.balancedSessionPoints == 0)
        #expect(live.total == 10)

        let finished = engine.score(derived, asOf: Fixture.at(4))
        #expect(finished.balancedSessionPoints == 50)
        #expect(finished.total == 60)
    }

    @Test("Falling short of the ratio goal forfeits the +50")
    func underRatioForfeitsBonus() {
        let events = [
            Fixture.event(1, hours: 0, .alcoholic),
            Fixture.event(2, hours: 0.5, .alcoholic),
            Fixture.event(3, hours: 1, .nonAlcoholic)
        ]
        let score = engine.score(session(events), asOf: Fixture.at(10))
        #expect(score.balancedSessionPoints == 0)
        #expect(score.total == 10)
    }

    @Test("A configurable ratio goal moves the bar")
    func configurableRatioGoal() {
        let strict = ScoringEngine(
            configuration: ScoringEngine.Configuration(ratioGoal: 2.0, calendar: Fixture.calendar)
        )
        let events = [
            Fixture.event(1, hours: 0, .alcoholic),
            Fixture.event(2, hours: 0.5, .nonAlcoholic)
        ]
        let derived = session(events)
        #expect(engine.score(derived, asOf: Fixture.at(10)).balancedSessionPoints == 50)
        #expect(strict.score(derived, asOf: Fixture.at(10)).balancedSessionPoints == 0)
    }

    @Test("Total points sum across Sessions")
    func totalsAcrossSessions() {
        let events = [
            Fixture.event(1, hours: 0, .alcoholic),
            Fixture.event(2, hours: 0.5, .nonAlcoholic),
            Fixture.event(3, hours: 1, .alcoholic),
            Fixture.event(4, hours: 20, .nonAlcoholic)
        ]
        let sessions = deriver.derive(events: events)
        #expect(sessions.count == 2)
        // Session 1: 1 NA (10) + 1 spacer (25) + no bonus (1 NA < 2 alcoholic) = 35
        // Session 2: 1 NA (10) + no spacers + bonus (0 alcoholic) = 60
        #expect(engine.totalPoints(for: sessions, asOf: Fixture.at(40)) == 95)
    }

    // MARK: - Daily stats and streaks (SPEC §3)

    @Test("Days with nothing logged still appear, as dry days")
    func emptyDaysAreDryDays() {
        let events = [
            Fixture.event(1, at: Fixture.onDay(0), .alcoholic),
            Fixture.event(2, at: Fixture.onDay(3), .alcoholic)
        ]
        let days = engine.dailyStats(for: events, asOf: Fixture.onDay(3, hour: 23))
        #expect(days.count == 4)
        #expect(days[0].isDry == false)
        #expect(days[1].isDry)
        #expect(days[2].isDry)
        #expect(days[3].isDry == false)
    }

    @Test("Dry days extend the streak automatically")
    func dryDaysExtendTheStreak() {
        let events = [
            Fixture.event(1, at: Fixture.onDay(0), .alcoholic),
            Fixture.event(2, at: Fixture.onDay(0, hour: 21), .nonAlcoholic),
            // Days 1 and 2: nothing logged at all.
            Fixture.event(3, at: Fixture.onDay(3), .alcoholic),
            Fixture.event(4, at: Fixture.onDay(3, hour: 21), .nonAlcoholic)
        ]
        let streaks = engine.streaks(for: events, asOf: Fixture.onDay(3, hour: 23))
        #expect(streaks.current == 4)
        #expect(streaks.longest == 4)
        #expect(streaks.currentDry == 0)
        #expect(streaks.longestDry == 2)
    }

    @Test("A day that misses the ratio goal breaks the streak")
    func missingTheGoalBreaksTheStreak() {
        let events = [
            Fixture.event(1, at: Fixture.onDay(0), .alcoholic),
            Fixture.event(2, at: Fixture.onDay(0, hour: 21), .nonAlcoholic),
            // Day 1: 2 alcoholic, 0 NA — misses 1:1.
            Fixture.event(3, at: Fixture.onDay(1), .alcoholic),
            Fixture.event(4, at: Fixture.onDay(1, hour: 21), .alcoholic),
            // Day 2: dry.
            Fixture.event(5, at: Fixture.onDay(3), .nonAlcoholic)
        ]
        let streaks = engine.streaks(for: events, asOf: Fixture.onDay(3, hour: 23))
        #expect(streaks.current == 2, "days 2 and 3 both qualify")
        #expect(streaks.longest == 2)
    }

    @Test("The streak is bounded by the log, not by the beginning of time")
    func streakStartsAtTheFirstEvent() {
        let events = [Fixture.event(1, at: Fixture.onDay(0), .nonAlcoholic)]
        let streaks = engine.streaks(for: events, asOf: Fixture.onDay(0, hour: 23))
        #expect(streaks.current == 1)
        #expect(streaks.longest == 1)
    }

    @Test("An empty log has no streak")
    func emptyLogHasNoStreak() {
        #expect(engine.streaks(for: [], asOf: Fixture.onDay(5)) == .zero)
        #expect(engine.dailyStats(for: [], asOf: Fixture.onDay(5)).isEmpty)
    }

    // MARK: - Badges (SPEC §3)

    @Test("Pacer: alternated all night")
    func pacerBadge() {
        let events = [
            Fixture.event(1, hours: 0, .alcoholic),
            Fixture.event(2, hours: 0.4, .nonAlcoholic),
            Fixture.event(3, hours: 0.8, .alcoholic),
            Fixture.event(4, hours: 1.2, .nonAlcoholic),
            Fixture.event(5, hours: 1.6, .alcoholic)
        ]
        let derived = session(events)
        #expect(engine.isPacer(derived))

        let awards = engine.badges(sessions: [derived], events: events, asOf: Fixture.at(10))
        #expect(awards.map(\.badge).contains(.pacer))
        #expect(awards.first { $0.badge == .pacer }?.sessionID == derived.id)
    }

    @Test("Pacer is not awarded when two alcoholic drinks run back to back")
    func pacerRequiresEveryGapCovered() {
        let events = [
            Fixture.event(1, hours: 0, .alcoholic),
            Fixture.event(2, hours: 0.4, .nonAlcoholic),
            Fixture.event(3, hours: 0.8, .alcoholic),
            Fixture.event(4, hours: 1.2, .alcoholic)
        ]
        #expect(!engine.isPacer(session(events)))
    }

    @Test("Pacer needs more than one pair to count as a night")
    func pacerRequiresThreeDrinks() {
        let events = [
            Fixture.event(1, hours: 0, .alcoholic),
            Fixture.event(2, hours: 0.4, .nonAlcoholic),
            Fixture.event(3, hours: 0.8, .alcoholic)
        ]
        #expect(!engine.isPacer(session(events)))
    }

    @Test("Designated Legend: a Session at a bar with zero alcoholic drinks")
    func designatedLegendBadge() {
        let events = [
            Fixture.event(1, hours: 0, .nonAlcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(2, hours: 1, .nonAlcoholic, venue: Fixture.anchorVenueID)
        ]
        let derived = session(events)
        #expect(engine.isDesignatedLegend(derived, venue: Fixture.anchor))

        let awards = engine.badges(
            sessions: [derived],
            events: events,
            venues: Fixture.venuesByID,
            asOf: Fixture.at(10)
        )
        #expect(awards.map(\.badge).contains(.designatedLegend))
    }

    @Test("Designated Legend never fires at home or with alcohol present")
    func designatedLegendIsBarOnly() {
        let atHome = session([
            Fixture.event(1, hours: 0, .nonAlcoholic, venue: Fixture.homeVenueID),
            Fixture.event(2, hours: 1, .nonAlcoholic, venue: Fixture.homeVenueID)
        ])
        #expect(!engine.isDesignatedLegend(atHome, venue: Fixture.home))

        let withAlcohol = session([
            Fixture.event(3, hours: 0, .nonAlcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(4, hours: 1, .alcoholic, venue: Fixture.anchorVenueID)
        ])
        #expect(!engine.isDesignatedLegend(withAlcohol, venue: Fixture.anchor))

        let untagged = session([Fixture.event(5, hours: 0, .nonAlcoholic)])
        #expect(!engine.isDesignatedLegend(untagged, venue: nil))
    }

    @Test("Hydration Week: a 7-day ratio streak")
    func hydrationWeekBadge() {
        // Day 0 qualifies on the ratio; days 1–6 are dry and extend it.
        let events = [
            Fixture.event(1, at: Fixture.onDay(0), .alcoholic),
            Fixture.event(2, at: Fixture.onDay(0, hour: 21), .nonAlcoholic)
        ]
        let asOf = Fixture.onDay(6, hour: 23)
        let sessions = deriver.derive(events: events)

        #expect(engine.streaks(for: events, asOf: asOf).longest == 7)
        let awards = engine.badges(sessions: sessions, events: events, asOf: asOf)
        #expect(awards.map(\.badge).contains(.hydrationWeek))
        #expect(awards.first { $0.badge == .hydrationWeek }?.earnedAt == Fixture.calendar.startOfDay(for: Fixture.onDay(6)))
    }

    @Test("Hydration Week does not fire at six days")
    func hydrationWeekNeedsSevenDays() {
        let events = [
            Fixture.event(1, at: Fixture.onDay(0), .alcoholic),
            Fixture.event(2, at: Fixture.onDay(0, hour: 21), .nonAlcoholic)
        ]
        let asOf = Fixture.onDay(5, hour: 23)
        let awards = engine.badges(sessions: deriver.derive(events: events), events: events, asOf: asOf)
        #expect(!awards.map(\.badge).contains(.hydrationWeek))
    }

    @Test("Dry Spell 3 / 7 / 30")
    func drySpellBadges() {
        let events = [Fixture.event(1, at: Fixture.onDay(0), .alcoholic)]

        let afterThree = engine.badges(
            sessions: deriver.derive(events: events),
            events: events,
            asOf: Fixture.onDay(3, hour: 23)
        ).map(\.badge)
        #expect(afterThree.contains(.drySpell3))
        #expect(!afterThree.contains(.drySpell7))

        let afterThirty = engine.badges(
            sessions: deriver.derive(events: events),
            events: events,
            asOf: Fixture.onDay(30, hour: 23)
        ).map(\.badge)
        #expect(afterThirty.contains(.drySpell3))
        #expect(afterThirty.contains(.drySpell7))
        #expect(afterThirty.contains(.drySpell30))
    }

    @Test("A drinking day resets the dry run")
    func dryRunResets() {
        let events = [
            Fixture.event(1, at: Fixture.onDay(0), .alcoholic),
            Fixture.event(2, at: Fixture.onDay(2), .alcoholic)
        ]
        let awards = engine.badges(
            sessions: deriver.derive(events: events),
            events: events,
            asOf: Fixture.onDay(3, hour: 23)
        ).map(\.badge)
        #expect(!awards.contains(.drySpell3), "only day 1 and day 3 were dry, never three in a row")
    }

    @Test("Badges are reported once each, at the moment first earned")
    func badgesAreDeduplicated() {
        let events = [
            Fixture.event(1, hours: 0, .nonAlcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(2, hours: 1, .nonAlcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(3, hours: 30, .nonAlcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(4, hours: 31, .nonAlcoholic, venue: Fixture.anchorVenueID)
        ]
        let sessions = deriver.derive(events: events)
        #expect(sessions.count == 2)

        let awards = engine.badges(
            sessions: sessions,
            events: events,
            venues: Fixture.venuesByID,
            asOf: Fixture.at(60)
        )
        let legends = awards.filter { $0.badge == .designatedLegend }
        #expect(legends.count == 1)
        #expect(legends[0].sessionID == sessions[0].id, "the first one earned it")
    }

    // MARK: - Summary

    @Test("Summary agrees with the individual computations")
    func summaryIsConsistent() {
        let events = [
            Fixture.event(1, at: Fixture.onDay(0, hour: 19), .alcoholic),
            Fixture.event(2, at: Fixture.onDay(0, hour: 20), .nonAlcoholic),
            Fixture.event(3, at: Fixture.onDay(0, hour: 21), .alcoholic)
        ]
        let asOf = Fixture.onDay(1, hour: 12)
        let sessions = deriver.derive(events: events)
        let summary = engine.summary(events: events, sessions: sessions, venues: Fixture.venuesByID, asOf: asOf)

        #expect(summary.totalPoints == engine.totalPoints(for: sessions, asOf: asOf))
        #expect(summary.streaks == engine.streaks(for: events, asOf: asOf))
        #expect(summary.dayStats == engine.dailyStats(for: events, asOf: asOf))
        #expect(summary.sessionScores.count == sessions.count)
    }

    @Test("Scoring is order-independent")
    func scoringIsOrderIndependent() {
        let events = (1...12).map {
            Fixture.event($0, hours: Double($0) * 0.4, $0.isMultiple(of: 2) ? .nonAlcoholic : .alcoholic)
        }
        let asOf = Fixture.at(24)
        let canonical = engine.totalPoints(for: deriver.derive(events: events), asOf: asOf)
        for _ in 0..<25 {
            #expect(engine.totalPoints(for: deriver.derive(events: events.shuffled()), asOf: asOf) == canonical)
        }
    }
}
