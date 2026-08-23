import Foundation
import Testing
import TallyKit
import UserNotifications
@testable import tally

/// SPEC §2 — Bar Radar, both tiers — as pure logic.
///
/// Everything Gate 3 asks of this workstream that does not need a simulator is
/// here: who earns a geofence, what an entry/exit/logged drink means, and which
/// detected visits survive the discovery gates. No `CLMonitor`, no `CLVisit`, no
/// notification centre, no store — the three types under test are pure functions
/// precisely so this file can exist.
///
/// **Target setup (integrator):** written but not yet wired, exactly like
/// `tallyTests/Sync/`. `tallyTests` needs a unit-test bundle target in
/// `tally.xcodeproj` with `TEST_HOST` set to the app; Wave 3 agents are not
/// allowed to touch `project.pbxproj`. Nothing in this file changes when it lands.

// MARK: - Fixtures

private enum RadarFixture {

    static let anchorLatitude = 51.5074
    static let anchorLongitude = -0.1278

    static let anchorID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let saltyDogID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    static let homeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
    static let mutedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!

    /// Roughly `meters` east of the anchor.
    static func longitude(offsetByMeters meters: Double) -> Double {
        let metersPerDegree = 111_320.0 * cos(anchorLatitude * .pi / 180)
        return anchorLongitude + meters / metersPerDegree
    }

    static func venue(
        id: UUID = anchorID,
        name: String = "The Anchor",
        category: VenueCategory = .bar,
        offsetMeters: Double = 0,
        radius: Double = 75,
        muted: Bool = false
    ) -> VenueSnapshot {
        VenueSnapshot(
            id: id,
            name: name,
            category: category,
            latitude: anchorLatitude,
            longitude: longitude(offsetByMeters: offsetMeters),
            radiusMeters: radius,
            source: .mapKitPOI,
            mapItemID: "poi." + name.lowercased(),
            muted: muted
        )
    }

    static func target(
        _ venue: VenueSnapshot = RadarFixture.venue(),
        sessions: Int = 3,
        lastSessionAt: Date = Date()
    ) -> RadarTarget {
        RadarTarget(venue: venue, sessionCount: sessions, lastSessionAt: lastSessionAt)
    }

    /// A Session with nothing in it but the fields derivation cares about.
    static func session(venueID: UUID?, startedAt: Date, id: UUID = UUID()) -> DerivedSession {
        DerivedSession(
            id: id,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(3600),
            closesAt: startedAt.addingTimeInterval(4 * 3600),
            venueID: venueID,
            events: [],
            isMaterialized: false
        )
    }

    static func visit(
        offsetMeters: Double = 0,
        accuracy: Double = 40,
        arrival: Date = Date(),
        departure: Date = .distantFuture
    ) -> RadarVisitObservation {
        RadarVisitObservation(
            latitude: anchorLatitude,
            longitude: longitude(offsetByMeters: offsetMeters),
            horizontalAccuracy: accuracy,
            arrivalDate: arrival,
            departureDate: departure
        )
    }

    static func candidate(
        name: String,
        category: VenueCategory = .bar,
        distance: Double
    ) -> VenueCandidate {
        VenueCandidate(
            id: "poi." + name.lowercased(),
            name: name,
            category: category,
            latitude: anchorLatitude,
            longitude: longitude(offsetByMeters: distance),
            distanceMeters: distance,
            mapItemID: "poi." + name.lowercased()
        )
    }

    /// A fixed clock: 2026-03-14 21:00 local — inside the default 4 pm–2 am
    /// discovery window.
    static var night: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 14
        components.hour = 21
        return Calendar.current.date(from: components)!
    }

    static func at(hour: Int, minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 14
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }
}

// MARK: - Frequented derivation

@Suite("Bar Radar — frequented venues (SPEC §2 Tier 1)")
@MainActor
struct FrequentedVenuesTests {

    private let frequented = FrequentedVenues()
    private let now = RadarFixture.night

    private func sessions(venueID: UUID, count: Int, daysAgo: [Int]) -> [DerivedSession] {
        daysAgo.prefix(count).map { days in
            RadarFixture.session(
                venueID: venueID,
                startedAt: now.addingTimeInterval(-Double(days) * 86_400)
            )
        }
    }

    @Test("Three Sessions in the trailing 90 days earns a geofence; two does not")
    func minimumSessions() {
        let anchor = RadarFixture.venue()
        let saltyDog = RadarFixture.venue(id: RadarFixture.saltyDogID, name: "The Salty Dog", offsetMeters: 400)

        let log =
            sessions(venueID: anchor.id, count: 3, daysAgo: [1, 10, 40])
            + sessions(venueID: saltyDog.id, count: 2, daysAgo: [2, 20])

        let targets = frequented.targets(sessions: log, venues: [anchor, saltyDog], asOf: now)

        #expect(targets.map(\.venueID) == [anchor.id])
        #expect(targets.first?.sessionCount == 3)
    }

    @Test("Sessions older than 90 days do not count toward frequented status")
    func lookbackWindow() {
        let anchor = RadarFixture.venue()
        let log = sessions(venueID: anchor.id, count: 3, daysAgo: [1, 10, 120])

        #expect(frequented.targets(sessions: log, venues: [anchor], asOf: now).isEmpty)
    }

    @Test("Home is never a Bar Radar target, however often it is logged")
    func homeExcluded() {
        let home = RadarFixture.venue(id: RadarFixture.homeID, name: "Home", category: .home, offsetMeters: 900)
        let log = sessions(venueID: home.id, count: 3, daysAgo: [1, 2, 3])

        #expect(frequented.targets(sessions: log, venues: [home], asOf: now).isEmpty)
    }

    @Test("A muted venue is excluded (SPEC §1's per-venue Bar Radar opt-out)")
    func mutedExcluded() {
        let muted = RadarFixture.venue(id: RadarFixture.mutedID, name: "The Local", offsetMeters: 600, muted: true)
        let log = sessions(venueID: muted.id, count: 4, daysAgo: [1, 2, 3, 4])

        #expect(frequented.targets(sessions: log, venues: [muted], asOf: now).isEmpty)
    }

    @Test("Untagged Sessions and Sessions pointing at deleted venues are ignored")
    func danglingSessions() {
        let anchor = RadarFixture.venue()
        let ghost = UUID()

        let log =
            sessions(venueID: anchor.id, count: 3, daysAgo: [1, 2, 3])
            + sessions(venueID: ghost, count: 3, daysAgo: [1, 2, 3])
            + [RadarFixture.session(venueID: nil, startedAt: now.addingTimeInterval(-3600))]

        let targets = frequented.targets(sessions: log, venues: [anchor], asOf: now)
        #expect(targets.map(\.venueID) == [anchor.id])
    }

    @Test("The region budget keeps the most recently visited venues")
    func regionBudget() {
        let budget = 3
        let deriver = FrequentedVenues(
            configuration: FrequentedVenues.Configuration(regionBudget: budget)
        )

        var venues: [VenueSnapshot] = []
        var log: [DerivedSession] = []

        // Ten qualifying venues, venue `index` last visited `index` days ago.
        for index in 0..<10 {
            let venue = RadarFixture.venue(
                id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02X", index + 16))")!,
                name: "Bar \(index)",
                offsetMeters: Double(index) * 200
            )
            venues.append(venue)
            log += sessions(venueID: venue.id, count: 3, daysAgo: [index, index + 30, index + 60])
        }

        let targets = deriver.targets(sessions: log, venues: venues, asOf: now)

        #expect(targets.count == budget)
        #expect(targets.map(\.name) == ["Bar 0", "Bar 1", "Bar 2"])
        // Most recent first.
        #expect(targets[0].lastSessionAt > targets[1].lastSessionAt)
    }

    @Test("The default budget stays under the system's ~20-region cap")
    func underSystemCap() {
        #expect(FrequentedVenues.Configuration.default.regionBudget <= 18)
    }
}

// MARK: - Tier 1 visit rules

@Suite("Bar Radar — visits, dwell, and re-entry (SPEC §2 Tier 1)")
@MainActor
struct RadarVisitMachineTests {

    private let target = RadarFixture.target()
    private let start = RadarFixture.at(hour: 20)

    private func machine(dwellMinutes: Int = 45) -> RadarVisitMachine {
        RadarVisitMachine(
            configuration: RadarVisitMachine.Configuration(
                dwellDelay: TimeInterval(dwellMinutes * 60)
            )
        )
    }

    private func enter(
        _ machine: RadarVisitMachine,
        at date: Date,
        state: RadarVisitState = RadarVisitState()
    ) -> RadarVisitMachine.Outcome {
        machine.handle(.entered(target: target, at: date), state: state)
    }

    // MARK: Arrival

    @Test("Entry auto-checks in, prompts, and arms the follow-up")
    func arrival() {
        let outcome = enter(machine(), at: start)

        #expect(outcome.effects.count == 3)

        guard case .autoCheckIn(let venueID, _) = outcome.effects[0] else {
            Issue.record("expected an auto check-in first")
            return
        }
        #expect(venueID == target.venueID)

        guard case .deliver(let prompt) = outcome.effects[1] else {
            Issue.record("expected the arrival prompt")
            return
        }
        #expect(prompt.kind == .arrival)
        #expect(prompt.placeName == "The Anchor")

        guard case .scheduleDwell(let followUp, let due) = outcome.effects[2] else {
            Issue.record("expected a dwell follow-up")
            return
        }
        #expect(followUp.kind == .dwell)
        #expect(due == start.addingTimeInterval(45 * 60))
        #expect(followUp.visitID == prompt.visitID)
    }

    @Test("The dwell delay comes from Settings")
    func configurableDwellDelay() {
        let outcome = enter(machine(dwellMinutes: 90), at: start)

        guard case .scheduleDwell(_, let due) = outcome.effects[2] else {
            Issue.record("expected a dwell follow-up")
            return
        }
        #expect(due == start.addingTimeInterval(90 * 60))
    }

    @Test("A repeated entry while already inside does not re-prompt")
    func duplicateEntry() {
        let machine = self.machine()
        let first = enter(machine, at: start)
        let second = enter(machine, at: start.addingTimeInterval(60), state: first.state)

        #expect(second.effects.isEmpty)
        #expect(second.state.visits.count == 1)
    }

    // MARK: Re-entry

    @Test("Exit then re-entry within 2 h is the same visit and does not re-prompt")
    func reentryWithinWindow() {
        let machine = self.machine()

        let arrival = enter(machine, at: start)
        let visitID = arrival.state.visits[0].id

        let exit = machine.handle(
            .exited(venueID: target.venueID, at: start.addingTimeInterval(30 * 60)),
            state: arrival.state
        )
        let back = enter(machine, at: start.addingTimeInterval(60 * 60), state: exit.state)

        // Same visit, so no arrival prompt.
        #expect(back.state.visits.count == 1)
        #expect(back.state.visits[0].id == visitID)
        #expect(!back.effects.contains { effect in
            if case .deliver = effect { return true }
            return false
        })

        // The follow-up the exit pulled is re-armed, still one delivery maximum.
        let rearmed = back.effects.compactMap { effect -> Date? in
            if case .scheduleDwell(_, let due) = effect { return due }
            return nil
        }
        #expect(rearmed == [start.addingTimeInterval(60 * 60 + 45 * 60)])
    }

    @Test("Re-entry after more than 2 h is a new visit and prompts again")
    func reentryAfterWindow() {
        let machine = self.machine()

        let arrival = enter(machine, at: start)
        let firstID = arrival.state.visits[0].id

        let exit = machine.handle(
            .exited(venueID: target.venueID, at: start.addingTimeInterval(30 * 60)),
            state: arrival.state
        )
        let back = enter(machine, at: start.addingTimeInterval(4 * 3600), state: exit.state)

        #expect(back.state.visits.count == 1)
        #expect(back.state.visits[0].id != firstID)
        #expect(back.effects.contains { effect in
            if case .deliver(let prompt) = effect { return prompt.kind == .arrival }
            return false
        })
    }

    // MARK: Dwell cancellation

    @Test("A logged drink cancels the pending follow-up")
    func drinkCancelsDwell() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)
        let visitID = arrival.state.visits[0].id

        let logged = machine.handle(
            .drinkLogged(at: start.addingTimeInterval(10 * 60)),
            state: arrival.state
        )

        // `contains` rather than equality: the same drink also arms the
        // mid-Session reminder, which `SessionReminderTests` covers.
        #expect(logged.effects.contains(.cancelDwell(visitID: visitID)))
        #expect(logged.state.visits[0].dwellScheduled == false)
        #expect(logged.state.visits[0].lastDrinkLoggedAt != nil)
    }

    @Test("An exit cancels the pending follow-up and records the Session-closing exit")
    func exitCancelsDwellAndClosesSession() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)
        let visitID = arrival.state.visits[0].id
        let exitAt = start.addingTimeInterval(20 * 60)

        let exit = machine.handle(.exited(venueID: target.venueID, at: exitAt), state: arrival.state)

        #expect(exit.effects == [
            .recordExit(venueID: target.venueID, at: exitAt),
            .cancelDwell(visitID: visitID)
        ])
    }

    @Test("A second drink does not cancel a follow-up that is already gone")
    func cancellationIsIdempotent() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)

        let first = machine.handle(.drinkLogged(at: start.addingTimeInterval(600)), state: arrival.state)
        let second = machine.handle(.drinkLogged(at: start.addingTimeInterval(1200)), state: first.state)

        // The second drink re-arms the mid-Session reminder, but the follow-up
        // it already pulled is not pulled twice.
        #expect(!second.effects.contains { effect in
            if case .cancelDwell = effect { return true }
            return false
        })
    }

    @Test("One follow-up maximum per visit, even when it was ignored")
    func oneFollowUpPerVisit() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)

        // The follow-up fires at +45 min and is ignored — no callback at all.
        // Stepping out at +60 and back at +70 must not arm a second one.
        let exit = machine.handle(
            .exited(venueID: target.venueID, at: start.addingTimeInterval(60 * 60)),
            state: arrival.state
        )
        let back = enter(machine, at: start.addingTimeInterval(70 * 60), state: exit.state)

        #expect(!back.effects.contains { effect in
            if case .scheduleDwell = effect { return true }
            return false
        })
        #expect(back.state.visits[0].hasSpentDwellFollowUp(asOf: start.addingTimeInterval(70 * 60)))
    }

    @Test("\"Not drinking tonight\" cancels the follow-up and silences the visit")
    func declineSilencesVisit() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)
        let visitID = arrival.state.visits[0].id

        let declined = machine.handle(
            .declined(visitID: visitID, at: start.addingTimeInterval(5 * 60)),
            state: arrival.state
        )
        #expect(declined.effects == [.cancelDwell(visitID: visitID)])
        #expect(declined.state.visits[0].isSuppressed)

        // Stepping out and back inside the window stays silent.
        let exit = machine.handle(
            .exited(venueID: target.venueID, at: start.addingTimeInterval(30 * 60)),
            state: declined.state
        )
        let back = enter(machine, at: start.addingTimeInterval(45 * 60), state: exit.state)

        #expect(back.effects.allSatisfy { effect in
            if case .autoCheckIn = effect { return true }
            return false
        })
    }

    @Test("An exit with no known visit still closes the Session")
    func exitWithoutVisit() {
        let exitAt = start.addingTimeInterval(3600)
        let outcome = machine().handle(
            .exited(venueID: target.venueID, at: exitAt),
            state: RadarVisitState()
        )
        #expect(outcome.effects == [.recordExit(venueID: target.venueID, at: exitAt)])
    }

    @Test("Departed visits are pruned once the re-entry window has passed")
    func pruning() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)
        let exit = machine.handle(
            .exited(venueID: target.venueID, at: start.addingTimeInterval(30 * 60)),
            state: arrival.state
        )

        let pruned = machine.prune(exit.state, asOf: start.addingTimeInterval(5 * 3600))
        #expect(pruned.visits.isEmpty)
    }

    @Test("Visit state round-trips through JSON so a background launch keeps it")
    func statePersists() throws {
        let arrival = enter(machine(), at: start)
        let data = try JSONEncoder().encode(arrival.state)
        let restored = try JSONDecoder().decode(RadarVisitState.self, from: data)
        #expect(restored == arrival.state)
    }
}

// MARK: - Mid-Session reminder

/// SPEC §2's mid-Session reminder, which is the dwell follow-up's mirror image:
/// it speaks only *after* a drink has been logged, is re-armed by every
/// subsequent one, and is capped at two per visit.
@Suite("Bar Radar — mid-Session reminder (SPEC §2 Tier 1)")
@MainActor
struct SessionReminderTests {

    private let target = RadarFixture.target()
    private let start = RadarFixture.at(hour: 20)

    private func machine(reminderMinutes: Int = 60, dwellMinutes: Int = 45) -> RadarVisitMachine {
        RadarVisitMachine(
            configuration: RadarVisitMachine.Configuration(
                dwellDelay: TimeInterval(dwellMinutes * 60),
                sessionReminderDelay: TimeInterval(reminderMinutes * 60)
            )
        )
    }

    private func enter(
        _ machine: RadarVisitMachine,
        at date: Date,
        state: RadarVisitState = RadarVisitState()
    ) -> RadarVisitMachine.Outcome {
        machine.handle(.entered(target: target, at: date), state: state)
    }

    private func minutes(_ count: Double) -> Date { start.addingTimeInterval(count * 60) }

    /// Every reminder fire date in an outcome, in order.
    private func reminderDates(_ outcome: RadarVisitMachine.Outcome) -> [Date] {
        outcome.effects.compactMap { effect in
            if case .scheduleSessionReminder(_, let due) = effect { return due }
            return nil
        }
    }

    private func reminderPrompts(_ outcome: RadarVisitMachine.Outcome) -> [RadarPrompt] {
        outcome.effects.compactMap { effect in
            if case .scheduleSessionReminder(let prompt, _) = effect { return prompt }
            return nil
        }
    }

    // MARK: Arming

    @Test("The first logged drink arms the reminder, one interval after that drink")
    func firstDrinkArmsReminder() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)
        let visitID = arrival.state.visits[0].id

        let logged = machine.handle(.drinkLogged(at: minutes(10)), state: arrival.state)

        #expect(logged.effects == [
            .cancelDwell(visitID: visitID),
            .scheduleSessionReminder(
                RadarPrompt(
                    kind: .sessionReminder,
                    visitID: visitID,
                    placeName: "The Anchor",
                    venueID: target.venueID
                ),
                at: minutes(70)
            )
        ])
        #expect(logged.state.visits[0].sessionReminderScheduledFor == minutes(70))
        #expect(logged.state.visits[0].spentSessionReminders(asOf: minutes(10)) == 0)
    }

    @Test("Arriving with nothing logged arms no reminder — that stretch belongs to dwell")
    func zeroDrinksNeverSchedules() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)

        #expect(reminderDates(arrival).isEmpty)
        #expect(arrival.state.visits[0].sessionReminderScheduledFor == nil)
        #expect(!arrival.state.visits[0].wantsSessionReminder(asOf: start))

        // Nor does stepping out and back in, which re-arms only the dwell prompt.
        let exit = machine.handle(.exited(venueID: target.venueID, at: minutes(20)), state: arrival.state)
        let back = enter(machine, at: minutes(30), state: exit.state)

        #expect(reminderDates(back).isEmpty)
        #expect(back.state.visits[0].sessionReminderScheduledFor == nil)
    }

    @Test("The interval comes from Settings")
    func configurableInterval() {
        let machine = self.machine(reminderMinutes: 90)
        let arrival = enter(machine, at: start)

        let logged = machine.handle(.drinkLogged(at: minutes(10)), state: arrival.state)
        #expect(reminderDates(logged) == [minutes(100)])
    }

    @Test("The machine's default interval is the one TallyDefaults hands out")
    func defaultInterval() {
        #expect(TallyDefaults.Fallback.barRadarSessionReminderMinutes == 60)
        #expect(
            RadarVisitMachine.Configuration.default.sessionReminderDelay
                == TimeInterval(TallyDefaults.Fallback.barRadarSessionReminderMinutes * 60)
        )
    }

    // MARK: Rescheduling

    @Test("A second drink retracts the pending reminder and re-arms from its own timestamp")
    func nextDrinkReschedules() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)
        let visitID = arrival.state.visits[0].id

        let first = machine.handle(.drinkLogged(at: minutes(10)), state: arrival.state)
        let second = machine.handle(.drinkLogged(at: minutes(20)), state: first.state)

        // Retracted and re-issued, not stacked: one cancel, one schedule.
        #expect(second.effects == [
            .cancelSessionReminder(visitID: visitID),
            .scheduleSessionReminder(
                RadarPrompt(
                    kind: .sessionReminder,
                    visitID: visitID,
                    placeName: "The Anchor",
                    venueID: target.venueID
                ),
                at: minutes(80)
            )
        ])

        // Exactly one pending, and nothing spent — a reminder pulled before its
        // date never counted against the cap.
        #expect(second.state.visits[0].sessionReminderScheduledFor == minutes(80))
        #expect(second.state.visits[0].sessionRemindersFired == 0)
        #expect(second.state.visits[0].spentSessionReminders(asOf: minutes(20)) == 0)
    }

    @Test("Two maximum per visit, counted by fire date rather than by any callback")
    func twoPerVisitCap() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)

        // Drink 1 arms the first reminder for +70. It fires, ignored — no callback.
        let first = machine.handle(.drinkLogged(at: minutes(10)), state: arrival.state)
        #expect(reminderDates(first) == [minutes(70)])

        // Drink 2, after that date: the fired one is banked, the second armed.
        let second = machine.handle(.drinkLogged(at: minutes(80)), state: first.state)
        #expect(reminderDates(second) == [minutes(140)])
        #expect(second.state.visits[0].sessionRemindersFired == 1)
        // Nothing to cancel — a reminder that already fired cannot be retracted.
        #expect(!second.effects.contains { effect in
            if case .cancelSessionReminder = effect { return true }
            return false
        })

        // Drink 3, after *that* date: both are spent, so the visit goes quiet.
        let third = machine.handle(.drinkLogged(at: minutes(150)), state: second.state)
        #expect(third.effects.isEmpty)
        #expect(third.state.visits[0].sessionRemindersFired == RadarVisit.maxSessionReminders)
        #expect(!third.state.visits[0].wantsSessionReminder(asOf: minutes(150)))

        // And a fourth drink does not talk the cap back open.
        let fourth = machine.handle(.drinkLogged(at: minutes(220)), state: third.state)
        #expect(reminderDates(fourth).isEmpty)
    }

    // MARK: Cancellation

    @Test("The geofence exit cancels the pending reminder")
    func exitCancels() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)
        let visitID = arrival.state.visits[0].id

        let logged = machine.handle(.drinkLogged(at: minutes(10)), state: arrival.state)
        let exit = machine.handle(.exited(venueID: target.venueID, at: minutes(30)), state: logged.state)

        // The same exit also asks for the Session true-up, which
        // `SessionTrueUpTests` owns — this test is about the reminder.
        #expect(exit.effects.prefix(2) == [
            .recordExit(venueID: target.venueID, at: minutes(30)),
            .cancelSessionReminder(visitID: visitID)
        ])
        #expect(exit.state.visits[0].sessionReminderScheduledFor == nil)
        // Cancelled before it was due, so it was never spent.
        #expect(exit.state.visits[0].sessionRemindersFired == 0)
    }

    @Test("\"Not drinking tonight\" cancels the reminder and keeps the visit quiet")
    func suppressionCancels() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)
        let visitID = arrival.state.visits[0].id

        let logged = machine.handle(.drinkLogged(at: minutes(10)), state: arrival.state)
        let declined = machine.handle(.declined(visitID: visitID, at: minutes(20)), state: logged.state)

        #expect(declined.effects == [.cancelSessionReminder(visitID: visitID)])
        #expect(declined.state.visits[0].sessionReminderScheduledFor == nil)

        // A later drink at a silenced visit re-arms nothing.
        let after = machine.handle(.drinkLogged(at: minutes(40)), state: declined.state)
        #expect(reminderDates(after).isEmpty)
    }

    @Test("An exit that lands after the reminder fired spends it rather than refunding it")
    func exitAfterFireDateBanksTheReminder() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)

        let logged = machine.handle(.drinkLogged(at: minutes(10)), state: arrival.state)
        let exit = machine.handle(.exited(venueID: target.venueID, at: minutes(90)), state: logged.state)

        // Nothing to cancel — and no `cancelSessionReminder` hiding among the
        // true-up the same exit asks for.
        #expect(!exit.effects.contains { effect in
            if case .cancelSessionReminder = effect { return true }
            return false
        })
        #expect(exit.state.visits[0].sessionRemindersFired == 1)
    }

    // MARK: Re-entry

    @Test("Coming back inside re-arms the reminder on the drink's original clock")
    func reentryKeepsTheDrinkClock() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)

        let logged = machine.handle(.drinkLogged(at: minutes(10)), state: arrival.state)
        let exit = machine.handle(.exited(venueID: target.venueID, at: minutes(20)), state: logged.state)
        let back = enter(machine, at: minutes(30), state: exit.state)

        // Still one interval after the drink, not after the doorway.
        #expect(reminderDates(back) == [minutes(70)])
    }

    @Test("An interval that ran out while outside restarts at the door, it does not fire on arrival")
    func reentryAfterIntervalElapsedRestarts() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)

        let logged = machine.handle(.drinkLogged(at: minutes(10)), state: arrival.state)
        let exit = machine.handle(.exited(venueID: target.venueID, at: minutes(20)), state: logged.state)
        let back = enter(machine, at: minutes(100), state: exit.state)

        #expect(reminderDates(back) == [minutes(160)])
        // The window that elapsed outside was never a mid-Session window, so it
        // cost the visit nothing.
        #expect(back.state.visits[0].sessionRemindersFired == 0)
    }

    // MARK: The prompt

    @Test("The prompt names the venue and carries it into the notification")
    func promptContents() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)
        let logged = machine.handle(.drinkLogged(at: minutes(10)), state: arrival.state)

        guard let prompt = reminderPrompts(logged).first else {
            Issue.record("expected a mid-Session reminder")
            return
        }
        #expect(prompt.kind == .sessionReminder)
        #expect(prompt.placeName == "The Anchor")
        #expect(prompt.venueID == target.venueID)
        #expect(prompt.category == .sessionReminder)
        #expect(prompt.notificationCategoryIdentifier == TallyNotificationCategory.sessionReminder.identifier)

        let request = RadarNotificationBuilder.request(for: prompt, fireDate: minutes(70), now: minutes(10))
        #expect(request.content.title == "Still at The Anchor")
        #expect(request.content.body == "Anything to add?")
        #expect(request.identifier == prompt.requestIdentifier)

        // The system takes a duration, not a date: one interval after the drink
        // that armed it. Compared with a second of slack because the trigger
        // stores what it is given, not what we computed.
        let trigger = request.trigger as? UNTimeIntervalNotificationTrigger
        #expect(trigger != nil)
        #expect(abs((trigger?.timeInterval ?? 0) - 60 * 60) < 1)

        // "+1 drink" needs the venue on the way back out to auto-tag the log.
        let payload = RadarActionPayload(userInfo: RadarActionPayload(prompt: prompt).userInfo)
        #expect(payload?.kind == .sessionReminder)
        #expect(payload?.venueID == target.venueID)
        #expect(payload?.visitID == prompt.visitID)
    }

    @Test("The category offers +1 drink and Not drinking tonight, and is registered")
    func categoryActions() {
        let category = RadarNotificationCategories.sessionReminder

        #expect(category.identifier == TallyNotificationCategory.sessionReminder.identifier)
        #expect(category.actions.map(\.identifier) == [
            RadarIdentifiers.logDrinkAction,
            RadarIdentifiers.notDrinkingAction
        ])
        #expect(RadarService.notificationCategories.contains(category))
    }

    @Test("The reminder is a Bar Radar prompt: quiet hours never touch it (SPEC §5)")
    func quietHoursExempt() {
        #expect(TallyNotificationCategory.sessionReminder.quietHoursPolicy == .ignore)
        #expect(TallyNotificationCategory.sessionReminder.respectsQuietHours == false)
        #expect(TallyNotificationCategory.sessionReminder.isImplemented)
        #expect(TallyNotificationCategory.userConfigurable.contains(.sessionReminder))
    }

    // MARK: Persistence

    @Test("A pending reminder survives the background launch that has to deliver it")
    func pendingReminderRoundTrips() throws {
        let machine = self.machine()
        let arrival = enter(machine, at: start)
        let logged = machine.handle(.drinkLogged(at: minutes(10)), state: arrival.state)

        let data = try JSONEncoder().encode(logged.state)
        let restored = try JSONDecoder().decode(RadarVisitState.self, from: data)

        #expect(restored == logged.state)
        #expect(restored.visits[0].sessionReminderScheduledFor == minutes(70))
        #expect(restored.visits[0].venueName == "The Anchor")
    }

    @Test("A visit stored before this feature existed still decodes")
    func legacyVisitDecodes() throws {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "venueID": "\(RadarFixture.anchorID.uuidString)",
            "startedAt": \(start.timeIntervalSinceReferenceDate),
            "lastEnteredAt": \(start.timeIntervalSinceReferenceDate),
            "dwellScheduled": true,
            "isSuppressed": false
        }
        """

        let visit = try JSONDecoder().decode(RadarVisit.self, from: Data(json.utf8))

        #expect(visit.venueName == nil)
        #expect(visit.sessionRemindersFired == 0)
        #expect(visit.sessionReminderScheduledFor == nil)
        #expect(visit.dwellScheduled)
    }
}

// MARK: - Session true-up

/// SPEC §2's Session true-up:
///
/// > when a Session with ≥1 drink closes, one reconciliation prompt: *"Session at
/// > The Anchor ended — 4 drinks, 1 water. Look right?"* … Fires on every close,
/// > one per Session: a geofence exit delivers immediately (quiet-hours exempt);
/// > a timeout close (home, or no geofence) delivers with quiet-hours *postpone*
/// > semantics.
///
/// Two delivery paths, and this file can reach both without a simulator: the exit
/// path is a `RadarVisitMachine` effect, and the timeout path is arithmetic over a
/// `DerivedSession` plus the quiet-hours window. Nothing here asserts on delivered
/// notifications — only on what the pure layer decides.
@Suite("Bar Radar — Session true-up (SPEC §2)")
@MainActor
struct SessionTrueUpTests {

    private let target = RadarFixture.target()
    private let start = RadarFixture.at(hour: 20)

    private func minutes(_ count: Double) -> Date { start.addingTimeInterval(count * 60) }

    private func machine() -> RadarVisitMachine { RadarVisitMachine() }

    private func enter(
        _ machine: RadarVisitMachine,
        at date: Date,
        state: RadarVisitState = RadarVisitState()
    ) -> RadarVisitMachine.Outcome {
        machine.handle(.entered(target: target, at: date), state: state)
    }

    private func trueUps(_ outcome: RadarVisitMachine.Outcome) -> [RadarEffect] {
        outcome.effects.filter { effect in
            if case .deliverTrueUp = effect { return true }
            return false
        }
    }

    // MARK: Fixtures

    private static let quietNight = QuietHours(isEnabled: true, startMinutes: 0, endMinutes: 8 * 60)

    private func event(
        _ offsetMinutes: Double,
        type: DrinkType = .alcoholic,
        venueID: UUID? = nil
    ) -> DrinkEventSnapshot {
        DrinkEventSnapshot(type: type, timestamp: minutes(offsetMinutes), venueID: venueID)
    }

    /// The one Session a set of fixture events derives to.
    private func session(
        _ events: [DrinkEventSnapshot],
        exits: [SessionDeriver.VenueExit] = []
    ) -> DerivedSession {
        SessionDeriver().derive(events: events, venueExits: exits).last!
    }

    // MARK: - Exit path (the machine)

    @Test("An exit after a logged drink asks for the true-up, after recording the close")
    func exitWithDrinksAsksForTrueUp() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)
        let logged = machine.handle(.drinkLogged(at: minutes(10)), state: arrival.state)

        let exit = machine.handle(.exited(venueID: target.venueID, at: minutes(40)), state: logged.state)

        // Last, and after `.recordExit`: the true-up describes a Session that the
        // exit closes, and the service derives it from the log in that order.
        #expect(exit.effects.first == .recordExit(venueID: target.venueID, at: minutes(40)))
        #expect(exit.effects.last == .deliverTrueUp(venueID: target.venueID, closedAt: minutes(40)))
    }

    @Test("An exit with nothing logged asks for nothing — there is no Session to reconcile")
    func exitWithoutDrinksIsSilent() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)

        let exit = machine.handle(.exited(venueID: target.venueID, at: minutes(40)), state: arrival.state)

        #expect(trueUps(exit).isEmpty)
    }

    @Test("An exit for a venue with no known visit asks for nothing")
    func exitWithoutVisitIsSilent() {
        let outcome = machine().handle(
            .exited(venueID: target.venueID, at: minutes(40)),
            state: RadarVisitState()
        )
        // Without a visit there is no evidence anything was logged here; the
        // projected half covers this Session instead.
        #expect(outcome.effects == [.recordExit(venueID: target.venueID, at: minutes(40))])
    }

    @Test("One per exit: a repeated exit event does not ask twice")
    func repeatedExitAsksOnce() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)
        let logged = machine.handle(.drinkLogged(at: minutes(10)), state: arrival.state)

        let first = machine.handle(.exited(venueID: target.venueID, at: minutes(40)), state: logged.state)
        let second = machine.handle(.exited(venueID: target.venueID, at: minutes(45)), state: first.state)

        #expect(trueUps(first).count == 1)
        #expect(second.effects.isEmpty)
    }

    @Test("Stepping out and back in, then leaving for good, asks once per departure")
    func reentryThenExit() {
        let machine = self.machine()
        let arrival = enter(machine, at: start)
        let logged = machine.handle(.drinkLogged(at: minutes(10)), state: arrival.state)

        let stepOut = machine.handle(.exited(venueID: target.venueID, at: minutes(20)), state: logged.state)
        let back = enter(machine, at: minutes(30), state: stepOut.state)
        let home = machine.handle(.exited(venueID: target.venueID, at: minutes(120)), state: back.state)

        // Each departure closes the Session as far as `SessionDeriver` is
        // concerned, so each asks — and the service's per-Session ledger is what
        // makes SPEC §2's "one per Session" hold across the two.
        #expect(trueUps(stepOut) == [.deliverTrueUp(venueID: target.venueID, closedAt: minutes(20))])
        #expect(trueUps(home) == [.deliverTrueUp(venueID: target.venueID, closedAt: minutes(120))])
    }

    // MARK: - Timeout path (the projection)

    @Test("Every drink re-projects the close: the fire date is always the last drink's +3 h")
    func everyDrinkRepushesTheFireDate() {
        let window = SessionDeriver.Configuration.defaultInactivityWindow
        // One night's drinks, replayed one at a time — which is exactly how the
        // projection sees them: it re-derives on every logged drink.
        let night = [event(0), event(30), event(75)]

        let first = session(Array(night.prefix(1)))
        #expect(first.closesAt == minutes(0).addingTimeInterval(window))

        let second = session(Array(night.prefix(2)))
        #expect(second.closesAt == minutes(30).addingTimeInterval(window))
        // Same Session, so the same request identifier — replaced, never stacked.
        #expect(second.id == first.id)

        let third = session(night)
        #expect(third.closesAt == minutes(75).addingTimeInterval(window))
        #expect(third.id == first.id)
    }

    @Test("Replace, not stack: the request identifier is the Session's, not the moment's")
    func identifierIsKeyedBySession() {
        let night = [event(0), event(30)]
        let early = session(Array(night.prefix(1)))
        let later = session(night)

        let promptA = SessionTrueUp.prompt(for: early, placeName: "The Anchor")
        let promptB = SessionTrueUp.prompt(for: later, placeName: "The Anchor")

        #expect(promptA?.requestIdentifier == promptB?.requestIdentifier)
        #expect(
            promptA?.requestIdentifier
                == "\(TallyNotificationCategory.sessionTrueUp.identifier).\(early.id.uuidString)"
        )

        // A different Session gets a different one, or the second night would
        // silently replace the first.
        let other = session([event(600)])
        #expect(other.id != early.id)
        #expect(SessionTrueUp.prompt(for: other, placeName: "")?.requestIdentifier != promptA?.requestIdentifier)
    }

    @Test("A close inside quiet hours is deferred to the end of the window")
    func quietWindowDeferral() {
        // 23:30 + 3 h = 02:30, inside the default midnight–08:00 window.
        let closesAt = RadarFixture.at(hour: 2, minute: 30)
        let fireDate = SessionTrueUp.fireDate(closesAt: closesAt, quietHours: Self.quietNight)

        #expect(fireDate == RadarFixture.at(hour: 8))
    }

    @Test("A close outside quiet hours keeps its own time")
    func outsideTheWindowIsUnchanged() {
        let closesAt = RadarFixture.at(hour: 21)
        #expect(SessionTrueUp.fireDate(closesAt: closesAt, quietHours: Self.quietNight) == closesAt)
    }

    @Test("Quiet hours turned off defer nothing")
    func quietHoursOffDefersNothing() {
        let off = QuietHours(isEnabled: false, startMinutes: 0, endMinutes: 8 * 60)
        let closesAt = RadarFixture.at(hour: 2, minute: 30)
        #expect(SessionTrueUp.fireDate(closesAt: closesAt, quietHours: off) == closesAt)
    }

    @Test("The category postpones through quiet hours rather than dropping (SPEC §2)")
    func categoryPolicy() {
        #expect(TallyNotificationCategory.sessionTrueUp.quietHoursPolicy == .postpone)
        #expect(TallyNotificationCategory.sessionTrueUp.respectsQuietHours)
        #expect(TallyNotificationCategory.sessionTrueUp.isImplemented)
        #expect(TallyNotificationCategory.userConfigurable.contains(.sessionTrueUp))
    }

    // MARK: - The retro "+1 drink"

    @Test("\"+1 drink\" lands inside the Session it corrects, not at the start of the next one")
    func retroDrinkLandsInsideTheTimeoutClosedSession() {
        let existing = [event(0), event(30)]
        let closed = session(existing)

        let correction = DrinkEventSnapshot(timestamp: SessionTrueUp.logTimestamp(for: closed))
        let reconciled = SessionDeriver().derive(events: existing + [correction])

        #expect(reconciled.count == 1)
        #expect(reconciled[0].id == closed.id)
        #expect(reconciled[0].alcoholicCount == 3)

        // And the boundary is why the inset exists: `SessionDeriver`'s 3 h gap is
        // exclusive, so a drink stamped exactly at `closesAt` opens a *new*
        // Session — the opposite of a correction.
        let onTheBoundary = DrinkEventSnapshot(timestamp: closed.closesAt)
        #expect(SessionDeriver().derive(events: existing + [onTheBoundary]).count == 2)
    }

    @Test("It lands inside an exit-closed Session too, where the exit itself is the boundary")
    func retroDrinkLandsInsideTheExitClosedSession() {
        let venueID = RadarFixture.anchorID
        let existing = [event(0, venueID: venueID), event(30, venueID: venueID)]
        let exits = [SessionDeriver.VenueExit(venueID: venueID, occurredAt: minutes(60))]

        let closed = session(existing, exits: exits)
        #expect(closed.closesAt == minutes(60))

        let correction = DrinkEventSnapshot(
            timestamp: SessionTrueUp.logTimestamp(for: closed),
            venueID: venueID
        )
        let reconciled = SessionDeriver().derive(events: existing + [correction], venueExits: exits)

        #expect(reconciled.count == 1)
        #expect(reconciled[0].id == closed.id)
        #expect(reconciled[0].alcoholicCount == 3)

        // On the exit's own timestamp it would split, because an exit inside the
        // interval between two drinks ends the Session.
        let onTheExit = DrinkEventSnapshot(timestamp: closed.closesAt, venueID: venueID)
        #expect(SessionDeriver().derive(events: existing + [onTheExit], venueExits: exits).count == 2)
    }

    @Test("A correction is never dated before the Session it corrects")
    func logTimestampIsFlooredAtTheLastDrink() {
        let venueID = RadarFixture.anchorID
        // The degenerate case: an exit landing on the only drink's own timestamp.
        let only = [event(0, venueID: venueID)]
        let exits = [SessionDeriver.VenueExit(venueID: venueID, occurredAt: minutes(0))]
        let closed = session(only, exits: exits)

        #expect(SessionTrueUp.logTimestamp(for: closed) == closed.endedAt)
    }

    // MARK: - The prompt

    @Test("The prompt reports the Session's own counts and carries them into the notification")
    func promptContents() {
        let events = [event(0), event(10), event(20, type: .nonAlcoholic), event(40)]
        let closed = session(events)

        guard let prompt = SessionTrueUp.prompt(for: closed, placeName: "The Anchor") else {
            Issue.record("expected a true-up")
            return
        }

        #expect(prompt.kind == .trueUp)
        #expect(prompt.category == .sessionTrueUp)
        #expect(prompt.visitID == nil)
        #expect(prompt.trueUp?.sessionID == closed.id)
        #expect(prompt.trueUp?.alcoholicCount == 3)
        #expect(prompt.trueUp?.nonAlcoholicCount == 1)

        let request = RadarNotificationBuilder.request(for: prompt, fireDate: nil, now: closed.closesAt)
        #expect(request.content.title == "Session at The Anchor ended")
        #expect(request.content.body == "3 drinks, 1 water. Look right?")
        #expect(request.identifier == prompt.requestIdentifier)
        // The exit path delivers now; only the projected half carries a trigger.
        #expect(request.trigger == nil)

        let scheduled = RadarNotificationBuilder.request(
            for: prompt,
            fireDate: closed.closesAt,
            now: closed.endedAt
        )
        let trigger = scheduled.trigger as? UNTimeIntervalNotificationTrigger
        #expect(trigger != nil)
        #expect(abs((trigger?.timeInterval ?? 0) - 3 * 60 * 60) < 1)
    }

    @Test("An untagged Session does not name a place it does not know")
    func untaggedSession() {
        let closed = session([event(0)])
        let prompt = SessionTrueUp.prompt(for: closed, placeName: "")

        #expect(prompt?.venueID == nil)
        #expect(RadarNotificationBuilder.request(for: prompt!).content.title == "Session ended")
    }

    @Test("A Session with nothing in it is not worth reconciling")
    func emptySessionHasNoTrueUp() {
        let empty = DerivedSession(
            id: UUID(),
            startedAt: start,
            endedAt: start,
            closesAt: minutes(180),
            venueID: nil,
            events: [],
            isMaterialized: true
        )
        #expect(SessionTrueUp.trueUp(for: empty) == nil)
        #expect(SessionTrueUp.prompt(for: empty, placeName: "The Anchor") == nil)
    }

    @Test(
        "The body states counts and drops the clause it has no number for",
        arguments: [
            (4, 1, "4 drinks, 1 water. Look right?"),
            (1, 0, "1 drink. Look right?"),
            (4, 0, "4 drinks. Look right?"),
            (0, 2, "2 waters. Look right?"),
            (1, 1, "1 drink, 1 water. Look right?")
        ]
    )
    func bodyCopy(alcoholic: Int, nonAlcoholic: Int, expected: String) {
        #expect(RadarCopy.TrueUp.body(alcoholic: alcoholic, nonAlcoholic: nonAlcoholic) == expected)
    }

    @Test("The category offers Looks right and +1 drink, and is registered")
    func categoryActions() {
        let category = RadarNotificationCategories.trueUp

        #expect(category.identifier == TallyNotificationCategory.sessionTrueUp.identifier)
        #expect(category.actions.map(\.identifier) == [
            RadarIdentifiers.looksRightAction,
            RadarIdentifiers.logDrinkAction
        ])
        #expect(RadarService.notificationCategories.contains(category))
    }

    @Test("The Session survives the trip into a notification and back, close moment included")
    func payloadRoundTrip() {
        let closed = session([event(0), event(30, type: .nonAlcoholic)])
        let prompt = SessionTrueUp.prompt(for: closed, placeName: "The Anchor")!
        let payload = RadarActionPayload(userInfo: RadarActionPayload(prompt: prompt).userInfo)

        #expect(payload?.kind == .trueUp)
        #expect(payload?.visitID == nil)
        #expect(payload?.trueUp == prompt.trueUp)
        // The one field "+1 drink" cannot do without: without it the correction
        // would be stamped at the tap and open a Session of its own.
        #expect(payload?.trueUp?.logAt == SessionTrueUp.logTimestamp(for: closed))
    }

    // MARK: - One per Session (the ledger)

    @Test("A Session that has had its prompt never gets another")
    func oneDeliveryPerSession() {
        let store = RadarStore.ephemeral()
        let sessionID = UUID()
        let now = RadarFixture.night

        #expect(!store.hasSpentTrueUp(sessionID: sessionID, asOf: now))

        store.recordTrueUpDelivered(sessionID: sessionID, at: now)
        #expect(store.hasSpentTrueUp(sessionID: sessionID, asOf: now))
        // Even much later, when the same Session is derived all over again.
        #expect(store.hasSpentTrueUp(sessionID: sessionID, asOf: now.addingTimeInterval(86_400)))
        #expect(!store.hasSpentTrueUp(sessionID: UUID(), asOf: now))
    }

    @Test("A projection is replaceable until its date passes, and spent after")
    func scheduledIsSpentByItsFireDate() {
        let store = RadarStore.ephemeral()
        let sessionID = UUID()
        let now = RadarFixture.night

        store.recordTrueUpScheduled(sessionID: sessionID, fireDate: now.addingTimeInterval(3600), at: now)
        #expect(!store.hasSpentTrueUp(sessionID: sessionID, asOf: now))

        // The next drink pushes it out; still one record, still unspent.
        store.recordTrueUpScheduled(
            sessionID: sessionID,
            fireDate: now.addingTimeInterval(7200),
            at: now.addingTimeInterval(1800)
        )
        #expect(store.trueUpRecords(asOf: now).count == 1)
        #expect(store.trueUpRecord(sessionID: sessionID)?.scheduledFor == now.addingTimeInterval(7200))
        #expect(!store.hasSpentTrueUp(sessionID: sessionID, asOf: now.addingTimeInterval(3600)))

        // Its date arrives with nothing having retracted it: an ignored
        // notification produces no callback, so the date is the receipt.
        #expect(store.hasSpentTrueUp(sessionID: sessionID, asOf: now.addingTimeInterval(7200)))
    }

    @Test("An exit that beats the projection takes it over rather than adding to it")
    func exitReplacesTheProjection() {
        let store = RadarStore.ephemeral()
        let sessionID = UUID()
        let now = RadarFixture.night

        store.recordTrueUpScheduled(sessionID: sessionID, fireDate: now.addingTimeInterval(7200), at: now)
        store.recordTrueUpDelivered(sessionID: sessionID, at: now.addingTimeInterval(600))

        #expect(store.trueUpRecords(asOf: now).count == 1)
        // The replaced projection is not a second prompt, and must not read as one.
        #expect(store.trueUpRecord(sessionID: sessionID)?.scheduledFor == nil)
        #expect(store.hasSpentTrueUp(sessionID: sessionID, asOf: now))
    }

    @Test("Erase-all forgets which Sessions were reconciled")
    func resetClearsTheLedger() {
        let store = RadarStore.ephemeral()
        let sessionID = UUID()

        store.recordTrueUpDelivered(sessionID: sessionID, at: RadarFixture.night)
        store.reset()

        #expect(!store.hasSpentTrueUp(sessionID: sessionID, asOf: RadarFixture.night))
    }
}

// MARK: - Recovery context on the true-up

/// SPEC §4 — *Session rebound classification*, the half that lands on the
/// true-up.
///
/// > **Session rebound classification** on Session detail and the true-up: peak
/// > drinking density per 90 min classifies the Session *paced / elevated /
/// > compressed*, with one factual line about the modeled next-morning rebound.
///
/// Two things are under test and the second is the one that matters most: that
/// the line says exactly what the model says when recovery context is on, and
/// that the body is **byte-identical** to its pre-recovery self when it is off —
/// SPEC §4's "zero footprint when off" is a promise about this exact string.
///
/// The flag is injected at every call rather than written to `UserDefaults`: the
/// planner takes it as a parameter (defaulted to `RecoveryContext.isEnabled()`)
/// precisely so a test never has to touch a global default, and so these cases
/// cannot leak into the suites above.
@Suite("Session true-up — recovery context (SPEC §4)")
@MainActor
struct SessionTrueUpRecoveryTests {

    private let start = RadarFixture.at(hour: 20)

    private func minutes(_ count: Double) -> Date { start.addingTimeInterval(count * 60) }

    private func event(_ offsetMinutes: Double, type: DrinkType = .alcoholic) -> DrinkEventSnapshot {
        DrinkEventSnapshot(type: type, timestamp: minutes(offsetMinutes))
    }

    private func session(_ events: [DrinkEventSnapshot]) -> DerivedSession {
        SessionDeriver().derive(events: events).last!
    }

    /// SPEC §5's own example night, drunk fast enough to compress: four
    /// alcoholic drinks and a water inside an hour.
    private var compressedNight: DerivedSession {
        session([event(0), event(20), event(30, type: .nonAlcoholic), event(40), event(60)])
    }

    // MARK: - Off (the default)

    @Test("Recovery context off leaves the body exactly as it was")
    func offIsByteIdentical() {
        let closed = compressedNight
        let prompt = SessionTrueUp.prompt(for: closed, placeName: "The Anchor", recoveryEnabled: false)

        #expect(prompt?.reboundClass == nil)

        let body = RadarNotificationBuilder.request(for: prompt!).content.body
        #expect(body == "4 drinks, 1 water. Look right?")
        // Byte-identical to the copy this app sent before the recovery layer
        // existed — which is the same thing as the pre-recovery call still
        // compiling and still answering the same string.
        #expect(body == RadarCopy.TrueUp.body(alcoholic: 4, nonAlcoholic: 1))
        #expect(!body.contains("\n"))
    }

    @Test("The title is untouched either way — recovery context adds a line, it does not rewrite one")
    func titleIsUnchanged() {
        let closed = compressedNight
        let on = SessionTrueUp.prompt(for: closed, placeName: "The Anchor", recoveryEnabled: true)!
        let off = SessionTrueUp.prompt(for: closed, placeName: "The Anchor", recoveryEnabled: false)!

        #expect(RadarNotificationBuilder.request(for: on).content.title == "Session at The Anchor ended")
        #expect(RadarNotificationBuilder.request(for: off).content.title == "Session at The Anchor ended")
    }

    // MARK: - On

    @Test("Recovery context on adds the model's own line, under the counts")
    func onAddsTheSecondLine() {
        let closed = compressedNight
        let prompt = SessionTrueUp.prompt(for: closed, placeName: "The Anchor", recoveryEnabled: true)

        #expect(prompt?.reboundClass == .compressed)

        let request = RadarNotificationBuilder.request(for: prompt!)
        #expect(request.content.title == "Session at The Anchor ended")
        #expect(
            request.content.body == """
            4 drinks, 1 water. Look right?
            Compressed — this pattern models the strongest next-morning suppression.
            """
        )
        // The words are the model's, not this module's: paraphrasing the line
        // that says "modeled" is how a model becomes a claim (SPEC §4).
        #expect(
            request.content.body.split(separator: "\n").last.map(String.init)
                == FibrinolysisModel.ReboundClass.compressed.summary
        )
    }

    @Test(
        "Density, not total, picks the line",
        arguments: [
            // One drink every 100 min: never two inside a 90-minute stretch.
            ([0.0, 100.0, 200.0], FibrinolysisModel.ReboundClass.paced),
            ([0.0, 30.0], .elevated),
            ([0.0, 30.0, 60.0], .elevated),
            ([0.0, 20.0, 40.0, 60.0], .compressed),
            // Four drinks spread over a long night stay paced — the same total,
            // a different modeled morning, which is the whole point of §4.
            ([0.0, 100.0, 200.0, 300.0], .paced)
        ]
    )
    func classificationPerDensity(offsets: [Double], expected: FibrinolysisModel.ReboundClass) {
        let closed = session(offsets.map { event($0) })
        let prompt = SessionTrueUp.prompt(for: closed, placeName: "The Anchor", recoveryEnabled: true)

        #expect(prompt?.reboundClass == expected)
        #expect(
            RadarNotificationBuilder.request(for: prompt!).content.body.hasSuffix(expected.summary)
        )
    }

    @Test("A night with nothing alcoholic in it gets no line, recovery context on or off")
    func zeroAlcoholSaysNothing() {
        let closed = session([event(0, type: .nonAlcoholic), event(30, type: .nonAlcoholic)])
        let prompt = SessionTrueUp.prompt(for: closed, placeName: "The Anchor", recoveryEnabled: true)

        // `FibrinolysisModel.classify` answers `.paced` for a night with no
        // pulses in it; "modeled next-morning rebound low" about two glasses of
        // water would be a sentence about nothing.
        #expect(prompt?.reboundClass == nil)
        #expect(RadarNotificationBuilder.request(for: prompt!).content.body == "2 waters. Look right?")
    }

    // MARK: - The rule both surfaces share

    @Test("The Session detail row and the true-up ask the same question")
    func detailRowSharesTheRule() {
        let closed = compressedNight

        #expect(closed.reboundClass(recoveryEnabled: true) == .compressed)
        #expect(closed.reboundClass(recoveryEnabled: false) == nil)
        #expect(
            closed.reboundClass(recoveryEnabled: true)
                == SessionTrueUp.prompt(for: closed, placeName: "", recoveryEnabled: true)?.reboundClass
        )

        // The row the UI suite reaches for (SPEC §4 asks for exactly this one).
        #expect(HistoryA11y.reboundClass == "history.reboundClass")
    }

    @Test("The classifier is injectable, and the line it picks is density alone")
    func classifierIsInjectable() {
        // Every curve parameter moved at once. `classify` counts drinks in a
        // fixed 90-minute window, so none of them can move the line — the curve
        // card's tuning and the true-up's sentence are independent by design.
        let tuned = FibrinolysisModel(
            configuration: FibrinolysisModel.Configuration(
                peakDelay: 90 * 60,
                compressionWindow: 6 * 3600,
                unitPulse: 40
            )
        )
        let closed = session([event(0), event(30)])

        #expect(closed.reboundClass(recoveryEnabled: true, model: tuned) == .elevated)
        #expect(closed.reboundClass(recoveryEnabled: true) == .elevated)
        #expect(
            SessionTrueUp.prompt(
                for: closed,
                placeName: "",
                recoveryEnabled: true,
                model: tuned
            )?.reboundClass == .elevated
        )
    }

    // MARK: - The payload

    @Test("The class is copy, not payload: \"+1 drink\" carries exactly what it carried before")
    func payloadIsUnchanged() {
        let closed = compressedNight
        let on = SessionTrueUp.prompt(for: closed, placeName: "The Anchor", recoveryEnabled: true)!
        let off = SessionTrueUp.prompt(for: closed, placeName: "The Anchor", recoveryEnabled: false)!

        // Same `userInfo` either way — the retro-log needs the close moment and
        // the counts, and nothing about a modeled morning changes where a
        // correction lands.
        #expect(RadarActionPayload(prompt: on).userInfo == RadarActionPayload(prompt: off).userInfo)
        #expect(RadarActionPayload(userInfo: RadarActionPayload(prompt: on).userInfo)?.trueUp == on.trueUp)
        // And the same request identifier, so recovery context can be flipped
        // mid-Session without stacking a second banner for the same night.
        #expect(on.requestIdentifier == off.requestIdentifier)
    }
}

// MARK: - Tier 2 gating

@Suite("Bar Radar — discovery gating (SPEC §2 Tier 2)")
@MainActor
struct DiscoveryGateTests {

    private let gate = DiscoveryGate()

    private func context(
        radar: Bool = true,
        discovery: Bool = true,
        home: VenueSnapshot? = nil,
        suppressed: [SuppressedPlaceSnapshot] = [],
        monitored: [RadarTarget] = [],
        prompts: [Date] = []
    ) -> DiscoveryGate.Context {
        DiscoveryGate.Context(
            isRadarEnabled: radar,
            isDiscoveryEnabled: discovery,
            home: home,
            suppressedPlaces: suppressed,
            monitoredTargets: monitored,
            recentPromptDates: prompts
        )
    }

    private let saltyDog = RadarFixture.candidate(name: "The Salty Dog", distance: 20)

    // MARK: Hours

    @Test(
        "The default 4 pm–2 am window crosses midnight",
        arguments: [
            (16, true), (21, true), (23, true), (0, true), (1, true),
            (2, false), (3, false), (9, false), (15, false)
        ]
    )
    func plausibleHours(hour: Int, expected: Bool) {
        #expect(gate.isWithinPlausibleHours(RadarFixture.at(hour: hour)) == expected)
    }

    @Test("A window that does not cross midnight is a plain range")
    func daytimeWindow() {
        let daytime = DiscoveryGate(
            configuration: DiscoveryGate.Configuration(startMinutes: 11 * 60, endMinutes: 15 * 60)
        )
        #expect(daytime.isWithinPlausibleHours(RadarFixture.at(hour: 12)))
        #expect(!daytime.isWithinPlausibleHours(RadarFixture.at(hour: 16)))
        #expect(!daytime.isWithinPlausibleHours(RadarFixture.at(hour: 2)))
    }

    @Test("Outside the window, nothing is asked of MapKit")
    func outsideHoursDiscards() {
        let decision = gate.decide(
            visit: RadarFixture.visit(),
            candidates: [saltyDog],
            context: context(),
            asOf: RadarFixture.at(hour: 11)
        )
        #expect(decision.rejection == .outsideHours)
    }

    // MARK: Toggles

    @Test("Both toggles gate discovery")
    func toggles() {
        let visit = RadarFixture.visit()
        #expect(
            gate.decide(visit: visit, candidates: [saltyDog], context: context(radar: false), asOf: RadarFixture.night)
                .rejection == .radarDisabled
        )
        #expect(
            gate.decide(visit: visit, candidates: [saltyDog], context: context(discovery: false), asOf: RadarFixture.night)
                .rejection == .discoveryDisabled
        )
    }

    // MARK: Weekly cap

    @Test("Three prompts in the trailing week is the cap")
    func weeklyCap() {
        let now = RadarFixture.night
        let recent = [1.0, 2.0, 4.0].map { now.addingTimeInterval(-$0 * 86_400) }

        #expect(
            gate.decide(visit: RadarFixture.visit(), candidates: [saltyDog], context: context(prompts: recent), asOf: now)
                .rejection == .weeklyCapReached
        )
    }

    @Test("The cap is rolling, not calendar: prompts older than a week fall out")
    func rollingCap() {
        let now = RadarFixture.night
        let stale = [8.0, 9.0, 30.0].map { now.addingTimeInterval(-$0 * 86_400) }

        #expect(
            gate.decide(visit: RadarFixture.visit(), candidates: [saltyDog], context: context(prompts: stale), asOf: now)
                .isPrompt
        )
    }

    @Test("Two prompts in the week still leaves room for a third")
    func underCap() {
        let now = RadarFixture.night
        let recent = [1.0, 3.0].map { now.addingTimeInterval(-$0 * 86_400) }

        #expect(
            gate.decide(visit: RadarFixture.visit(), candidates: [saltyDog], context: context(prompts: recent), asOf: now)
                .isPrompt
        )
    }

    // MARK: Places

    @Test("A visit inside the Home geofence is never a discovery")
    func homeExcluded() {
        let home = RadarFixture.venue(
            id: RadarFixture.homeID,
            name: "Home",
            category: .home,
            offsetMeters: 30,
            radius: 100
        )
        #expect(
            gate.decide(
                visit: RadarFixture.visit(),
                candidates: [saltyDog],
                context: context(home: home),
                asOf: RadarFixture.night
            ).rejection == .insideHome
        )
    }

    @Test("A Home geofence you are outside of does not block anything")
    func awayFromHome() {
        let home = RadarFixture.venue(
            id: RadarFixture.homeID,
            name: "Home",
            category: .home,
            offsetMeters: 800,
            radius: 100
        )
        #expect(
            gate.decide(
                visit: RadarFixture.visit(),
                candidates: [saltyDog],
                context: context(home: home),
                asOf: RadarFixture.night
            ).isPrompt
        )
    }

    @Test("A suppressed place stays quiet")
    func suppressedByProximity() {
        let suppressed = SuppressedPlaceSnapshot(
            latitude: RadarFixture.anchorLatitude,
            longitude: RadarFixture.longitude(offsetByMeters: 20),
            radiusMeters: 75,
            name: "Not a bar"
        )
        #expect(
            gate.decide(
                visit: RadarFixture.visit(),
                candidates: [saltyDog],
                context: context(suppressed: [suppressed]),
                asOf: RadarFixture.night
            ).rejection == .suppressedPlace
        )
    }

    @Test("Suppression also matches by MapKit identity")
    func suppressedByMapItem() {
        let suppressed = SuppressedPlaceSnapshot(
            latitude: RadarFixture.anchorLatitude,
            longitude: RadarFixture.longitude(offsetByMeters: 5_000),
            radiusMeters: 75,
            mapItemID: saltyDog.mapItemID,
            name: saltyDog.name
        )
        #expect(
            gate.decide(
                visit: RadarFixture.visit(),
                candidates: [saltyDog],
                context: context(suppressed: [suppressed]),
                asOf: RadarFixture.night
            ).rejection == .suppressedPlace
        )
    }

    @Test("A visit inside a Tier 1 geofence belongs to Tier 1")
    func coveredByGeofence() {
        let target = RadarFixture.target(RadarFixture.venue(offsetMeters: 10, radius: 75))
        #expect(
            gate.decide(
                visit: RadarFixture.visit(),
                candidates: [saltyDog],
                context: context(monitored: [target]),
                asOf: RadarFixture.night
            ).rejection == .coveredByGeofence
        )
    }

    @Test("A visit that already ended is discarded")
    func departedVisit() {
        let visit = RadarFixture.visit(departure: RadarFixture.night)
        #expect(
            gate.decide(visit: visit, candidates: [saltyDog], context: context(), asOf: RadarFixture.night)
                .rejection == .alreadyDeparted
        )
    }

    // MARK: Candidates

    @Test("A single nightlife candidate inside the accuracy radius prompts")
    func singleCandidate() {
        let decision = gate.decide(
            visit: RadarFixture.visit(accuracy: 40),
            candidates: [saltyDog],
            context: context(),
            asOf: RadarFixture.night
        )
        guard case .prompt(let candidate) = decision else {
            Issue.record("expected a prompt, got \(decision)")
            return
        }
        #expect(candidate.name == "The Salty Dog")
    }

    @Test("An ambiguous cluster of bars is discarded on the spot")
    func ambiguousCluster() {
        let decision = gate.decide(
            visit: RadarFixture.visit(accuracy: 60),
            candidates: [saltyDog, RadarFixture.candidate(name: "The Rusty Anchor", distance: 45)],
            context: context(),
            asOf: RadarFixture.night
        )
        #expect(decision.rejection == .ambiguous)
    }

    @Test("Nothing nearby is discarded")
    func noCandidate() {
        #expect(
            gate.decide(visit: RadarFixture.visit(), candidates: [], context: context(), asOf: RadarFixture.night)
                .rejection == .noCandidate
        )
    }

    @Test("A restaurant is not a discovery target — lunch is not a Session")
    func nightlifeOnly() {
        let bistro = RadarFixture.candidate(name: "Bistro", category: .restaurant, distance: 10)
        #expect(
            gate.decide(visit: RadarFixture.visit(), candidates: [bistro], context: context(), asOf: RadarFixture.night)
                .rejection == .noCandidate
        )
    }

    @Test("A bar beyond the visit's radius does not count")
    func outsideRadius() {
        let faraway = RadarFixture.candidate(name: "The Distant Arms", distance: 300)
        #expect(
            gate.decide(
                visit: RadarFixture.visit(accuracy: 40),
                candidates: [faraway],
                context: context(),
                asOf: RadarFixture.night
            ).rejection == .noCandidate
        )
    }

    @Test("A fuzzy fix widens the radius; a tiny one is floored at the venue radius")
    func radiusFloorAndWidening() {
        #expect(gate.searchRadius(for: RadarFixture.visit(accuracy: 5)) == 75)
        #expect(gate.searchRadius(for: RadarFixture.visit(accuracy: 180)) == 180)
    }

    @Test("A candidate just inside a widened radius still prompts")
    func widenedRadiusPrompts() {
        let candidate = RadarFixture.candidate(name: "The Salty Dog", distance: 140)
        #expect(
            gate.decide(
                visit: RadarFixture.visit(accuracy: 150),
                candidates: [candidate],
                context: context(),
                asOf: RadarFixture.night
            ).isPrompt
        )
    }
}

// MARK: - Payload round trip

@Suite("Bar Radar — notification payloads")
@MainActor
struct RadarActionPayloadTests {

    @Test("A Tier 1 prompt survives the trip into a notification and back")
    func tierOneRoundTrip() {
        let prompt = RadarPrompt(
            kind: .arrival,
            visitID: UUID(),
            placeName: "The Anchor",
            venueID: RadarFixture.anchorID
        )
        let payload = RadarActionPayload(userInfo: RadarActionPayload(prompt: prompt).userInfo)

        #expect(payload?.kind == .arrival)
        #expect(payload?.visitID == prompt.visitID)
        #expect(payload?.venueID == RadarFixture.anchorID)
        #expect(payload?.place == nil)
    }

    @Test("A discovered POI survives, which is what \"Not a bar\" needs")
    func tierTwoRoundTrip() {
        let place = RadarPlace(
            name: "The Salty Dog",
            latitude: RadarFixture.anchorLatitude,
            longitude: RadarFixture.anchorLongitude,
            mapItemID: "poi.salty"
        )
        let prompt = RadarPrompt(
            kind: .discovery,
            visitID: UUID(),
            placeName: place.name,
            place: place
        )
        let payload = RadarActionPayload(userInfo: RadarActionPayload(prompt: prompt).userInfo)

        #expect(payload?.place == place)
        #expect(payload?.placeName == "The Salty Dog")
    }

    @Test("Another stream's notification is not ours")
    func foreignPayload() {
        #expect(RadarActionPayload(userInfo: ["tallyCategory": "weeklyDigest"]) == nil)
    }

    @Test("Bar Radar is exempt from quiet hours (SPEC §5)")
    func quietHoursExemption() {
        for category in [
            TallyNotificationCategory.barRadarArrival,
            .barRadarDwell,
            .barRadarDiscovery,
            .sessionReminder
        ] {
            #expect(category.respectsQuietHours == false)
            #expect(category.quietHoursPolicy == .ignore)
        }
    }

    @Test("The arrival prompt only carries the mute button once it has been earned")
    func muteVariant() {
        var prompt = RadarPrompt(
            kind: .arrival,
            visitID: UUID(),
            placeName: "The Anchor",
            venueID: RadarFixture.anchorID
        )
        #expect(prompt.notificationCategoryIdentifier == TallyNotificationCategory.barRadarArrival.identifier)

        prompt.offersMute = true
        #expect(prompt.notificationCategoryIdentifier.hasSuffix(".withMute"))
    }
}

// MARK: - Store

@Suite("Bar Radar — persistence")
@MainActor
struct RadarStoreTests {

    @Test("Exits are stored in the shape SessionDeriver consumes")
    func exits() {
        let store = RadarStore.ephemeral()
        let now = RadarFixture.night

        store.recordExit(venueID: RadarFixture.anchorID, at: now)
        store.recordExit(venueID: RadarFixture.saltyDogID, at: now.addingTimeInterval(-3600))

        let exits = store.venueExits(asOf: now)
        #expect(exits.count == 2)
        #expect(exits.contains { $0.venueID == RadarFixture.anchorID && $0.occurredAt == now })
    }

    @Test("Exits older than a day cannot close anything and are dropped")
    func exitRetention() {
        let store = RadarStore.ephemeral()
        let now = RadarFixture.night

        store.recordExit(venueID: RadarFixture.anchorID, at: now.addingTimeInterval(-3 * 86_400))
        #expect(store.venueExits(asOf: now).isEmpty)
    }

    @Test("Two dismissals at the same spot reach the auto-suppress threshold")
    func spotDismissals() {
        let store = RadarStore.ephemeral()
        let spot = RadarFixture.visit().coordinate

        #expect(store.recordDismissal(at: spot, name: "Somewhere") == 1)
        #expect(store.recordDismissal(at: spot, name: "Somewhere") == 2)
        #expect(DiscoveryGate.Configuration.default.dismissalsBeforeSuppression == 2)
    }

    @Test("Dismissals at different spots are counted separately")
    func distinctSpots() {
        let store = RadarStore.ephemeral()

        #expect(store.recordDismissal(at: RadarFixture.visit(offsetMeters: 0).coordinate) == 1)
        #expect(store.recordDismissal(at: RadarFixture.visit(offsetMeters: 500).coordinate) == 1)
    }

    @Test("Arrival dismissals are counted per venue, for the mute offer")
    func arrivalDismissals() {
        let store = RadarStore.ephemeral()

        #expect(store.recordArrivalDismissal(venueID: RadarFixture.anchorID) == 1)
        #expect(store.recordArrivalDismissal(venueID: RadarFixture.anchorID) == 2)
        #expect(store.arrivalDismissals(venueID: RadarFixture.saltyDogID) == 0)

        store.clearArrivalDismissals(venueID: RadarFixture.anchorID)
        #expect(store.arrivalDismissals(venueID: RadarFixture.anchorID) == 0)
    }

    @Test("Erase-all forgets every suppression rule")
    func reset() {
        let store = RadarStore.ephemeral()
        store.recordExit(venueID: RadarFixture.anchorID, at: RadarFixture.night)
        store.recordDiscoveryPrompt(at: RadarFixture.night)
        store.recordArrivalDismissal(venueID: RadarFixture.anchorID)

        store.reset()

        #expect(store.venueExits(asOf: RadarFixture.night).isEmpty)
        #expect(store.discoveryPromptDates(asOf: RadarFixture.night).isEmpty)
        #expect(store.arrivalDismissals(venueID: RadarFixture.anchorID) == 0)
    }
}
