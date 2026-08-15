import Foundation
import Testing
import TallyKit
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

        #expect(logged.effects == [.cancelDwell(visitID: visitID)])
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

        #expect(second.effects.isEmpty)
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
            .barRadarDiscovery
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
