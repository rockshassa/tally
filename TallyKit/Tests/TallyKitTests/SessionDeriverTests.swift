import Foundation
import Testing
@testable import TallyKit

/// Gate 0 invariants for `SessionDeriver` (PLAN Wave 0, SPEC §2).
@Suite("SessionDeriver")
struct SessionDeriverTests {

    let deriver = SessionDeriver()

    // MARK: - Determinism

    @Test("Shuffled insert order produces an identical Session list with identical IDs")
    func determinismUnderShuffledInsertOrder() {
        let events: [DrinkEventSnapshot] = [
            Fixture.event(1, hours: 0, .alcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(2, hours: 0.5, .nonAlcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(3, hours: 1.0, .alcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(4, hours: 2.0, .alcoholic, venue: Fixture.anchorVenueID),
            // 4 h gap: new Session.
            Fixture.event(5, hours: 6.0, .alcoholic),
            Fixture.event(6, hours: 6.5, .nonAlcoholic),
            // Next night at a different venue.
            Fixture.event(7, hours: 30, .alcoholic, venue: Fixture.saltyDogVenueID),
            Fixture.event(8, hours: 31, .nonAlcoholic, venue: Fixture.saltyDogVenueID),
            Fixture.event(9, hours: 32, .alcoholic, venue: Fixture.saltyDogVenueID),
            Fixture.event(10, hours: 50, .nonAlcoholic, venue: Fixture.homeVenueID)
        ]

        let canonical = deriver.derive(events: events).signature
        #expect(canonical.count == 4)

        for _ in 0..<50 {
            #expect(deriver.derive(events: events.shuffled()).signature == canonical)
        }
    }

    @Test("Repeated runs over the same input are identical")
    func determinismAcrossRepeatedRuns() {
        let events = (1...20).map {
            Fixture.event($0, hours: Double($0) * 0.4, $0.isMultiple(of: 3) ? .nonAlcoholic : .alcoholic)
        }
        let first = deriver.derive(events: events).signature
        for _ in 0..<10 {
            #expect(deriver.derive(events: events).signature == first)
        }
    }

    @Test("Double-delivered event UUIDs merge idempotently")
    func duplicateDeliveryIsIdempotent() {
        let events: [DrinkEventSnapshot] = [
            Fixture.event(1, hours: 0),
            Fixture.event(2, hours: 1, .nonAlcoholic),
            Fixture.event(3, hours: 2)
        ]

        let once = deriver.derive(events: events)
        let twice = deriver.derive(events: (events + events).shuffled())

        #expect(once.signature == twice.signature)
        #expect(twice.count == 1)
        #expect(twice[0].events.count == 3)
    }

    // MARK: - Boundaries (SPEC §2)

    @Test("A gap shorter than 3 h keeps one Session")
    func gapUnderThreeHoursContinues() {
        let events = [
            Fixture.event(1, hours: 0),
            Fixture.event(2, hours: 2.99)
        ]
        let sessions = deriver.derive(events: events)
        #expect(sessions.count == 1)
        #expect(sessions[0].eventIDs == [Fixture.uuid(1), Fixture.uuid(2)])
    }

    @Test("A gap of exactly 3 h opens a new Session")
    func gapOfExactlyThreeHoursSplits() {
        let events = [
            Fixture.event(1, hours: 0),
            Fixture.event(2, hours: 3.0)
        ]
        let sessions = deriver.derive(events: events)
        #expect(sessions.count == 2)
        #expect(sessions[0].id == Fixture.uuid(1))
        #expect(sessions[1].id == Fixture.uuid(2))
    }

    @Test("Identity is the first event's UUID")
    func identityIsFirstEventUUID() {
        let events = [
            Fixture.event(7, hours: 0),
            Fixture.event(3, hours: 1),
            Fixture.event(5, hours: 2)
        ]
        let sessions = deriver.derive(events: events.shuffled())
        #expect(sessions.count == 1)
        #expect(sessions[0].id == Fixture.uuid(7))
    }

    @Test("Recorded end is the last drink's timestamp; the Session closes 3 h later")
    func endIsLastDrinkAndCloseIsThreeHoursLater() {
        let events = [
            Fixture.event(1, hours: 0),
            Fixture.event(2, hours: 1.5)
        ]
        let session = deriver.derive(events: events)[0]
        #expect(session.startedAt == Fixture.at(0))
        #expect(session.endedAt == Fixture.at(1.5))
        #expect(session.closesAt == Fixture.at(4.5))
        #expect(session.duration == 1.5 * Fixture.hour)
    }

    @Test("A venue change splits the Session even inside the 3 h window")
    func venueChangeSplits() {
        let events = [
            Fixture.event(1, hours: 0, .alcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(2, hours: 0.5, .alcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(3, hours: 1.0, .alcoholic, venue: Fixture.saltyDogVenueID)
        ]
        let sessions = deriver.derive(events: events)
        #expect(sessions.count == 2)
        #expect(sessions[0].venueID == Fixture.anchorVenueID)
        #expect(sessions[0].eventIDs == [Fixture.uuid(1), Fixture.uuid(2)])
        #expect(sessions[1].venueID == Fixture.saltyDogVenueID)
    }

    @Test("An untagged event never splits a venue Session")
    func untaggedEventContinuesVenueSession() {
        let events = [
            Fixture.event(1, hours: 0, .alcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(2, hours: 0.5, .nonAlcoholic),
            Fixture.event(3, hours: 1.0, .alcoholic, venue: Fixture.anchorVenueID)
        ]
        let sessions = deriver.derive(events: events)
        #expect(sessions.count == 1)
        #expect(sessions[0].venueID == Fixture.anchorVenueID)
    }

    @Test("A check-in on a later drink adopts the venue for the whole Session")
    func lateCheckInAdoptsVenue() {
        // SPEC §2: you get asked once per outing; the first drink is often logged
        // before the check-in sheet is confirmed.
        let events = [
            Fixture.event(1, hours: 0, .alcoholic),
            Fixture.event(2, hours: 0.4, .alcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(3, hours: 1.0, .alcoholic, venue: Fixture.anchorVenueID)
        ]
        let sessions = deriver.derive(events: events)
        #expect(sessions.count == 1)
        #expect(sessions[0].venueID == Fixture.anchorVenueID)
        #expect(sessions[0].eventIDs.count == 3)
    }

    @Test("Retro-logged events with no location join by time alone")
    func retroLoggedEventJoinsByTime() {
        let events = [
            Fixture.event(1, hours: 0, .alcoholic, venue: Fixture.anchorVenueID),
            // Retro-log: SPEC §1 says no location attached.
            Fixture.event(2, hours: 1.0, .nonAlcoholic)
        ]
        let sessions = deriver.derive(events: events)
        #expect(sessions.count == 1)
        #expect(sessions[0].events[1].venueID == nil)
    }

    @Test("Retro-logging an earlier first drink re-keys an unmaterialized Session")
    func retroLogRekeysUnmaterializedSession() {
        let original = [
            Fixture.event(2, hours: 1.0),
            Fixture.event(3, hours: 2.0)
        ]
        #expect(deriver.derive(events: original)[0].id == Fixture.uuid(2))

        let withRetroLog = original + [Fixture.event(1, hours: 0.2)]
        let sessions = deriver.derive(events: withRetroLog)
        #expect(sessions.count == 1)
        #expect(sessions[0].id == Fixture.uuid(1))
        #expect(sessions[0].startedAt == Fixture.at(0.2))
    }

    @Test("Undoing the first drink re-keys an unmaterialized Session")
    func undoOfFirstEventRekeysUnmaterializedSession() {
        let events = [
            Fixture.event(1, hours: 0),
            Fixture.event(2, hours: 1),
            Fixture.event(3, hours: 2)
        ]
        #expect(deriver.derive(events: events)[0].id == Fixture.uuid(1))

        let afterUndo = Array(events.dropFirst())
        let sessions = deriver.derive(events: afterUndo)
        #expect(sessions.count == 1)
        #expect(sessions[0].id == Fixture.uuid(2))
    }

    // MARK: - Bar Radar exit hook (SPEC §2)

    @Test("A Bar Radar exit closes the Session immediately")
    func venueExitClosesSessionEarly() {
        let events = [
            Fixture.event(1, hours: 0, .alcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(2, hours: 1, .alcoholic, venue: Fixture.anchorVenueID)
        ]
        let exit = SessionDeriver.VenueExit(venueID: Fixture.anchorVenueID, occurredAt: Fixture.at(1.5))

        let session = deriver.derive(events: events, venueExits: [exit])[0]
        #expect(session.endedAt == Fixture.at(1.0), "end time stays the last drink's timestamp")
        #expect(session.closesAt == Fixture.at(1.5), "but the Session closes at the exit")
        #expect(session.isActive(asOf: Fixture.at(1.4)))
        #expect(!session.isActive(asOf: Fixture.at(1.6)))
    }

    @Test("A drink after a Bar Radar exit starts a new Session inside the 3 h window")
    func drinkAfterExitStartsNewSession() {
        let events = [
            Fixture.event(1, hours: 0, .alcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(2, hours: 2, .alcoholic, venue: Fixture.anchorVenueID)
        ]
        let exit = SessionDeriver.VenueExit(venueID: Fixture.anchorVenueID, occurredAt: Fixture.at(1))

        let sessions = deriver.derive(events: events, venueExits: [exit])
        #expect(sessions.count == 2)
        #expect(sessions[0].id == Fixture.uuid(1))
        #expect(sessions[1].id == Fixture.uuid(2))
    }

    @Test("An exit at a different venue leaves the Session alone")
    func exitAtOtherVenueIsIgnored() {
        let events = [
            Fixture.event(1, hours: 0, .alcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(2, hours: 2, .alcoholic, venue: Fixture.anchorVenueID)
        ]
        let exit = SessionDeriver.VenueExit(venueID: Fixture.saltyDogVenueID, occurredAt: Fixture.at(1))
        #expect(deriver.derive(events: events, venueExits: [exit]).count == 1)
    }

    @Test("Exit ordering does not affect the result")
    func exitOrderIsIrrelevant() {
        let events = [
            Fixture.event(1, hours: 0, .alcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(2, hours: 2, .alcoholic, venue: Fixture.anchorVenueID),
            Fixture.event(3, hours: 4, .alcoholic, venue: Fixture.anchorVenueID)
        ]
        let exits = [
            SessionDeriver.VenueExit(venueID: Fixture.anchorVenueID, occurredAt: Fixture.at(1)),
            SessionDeriver.VenueExit(venueID: Fixture.anchorVenueID, occurredAt: Fixture.at(3)),
            SessionDeriver.VenueExit(venueID: Fixture.saltyDogVenueID, occurredAt: Fixture.at(2))
        ]
        let canonical = deriver.derive(events: events, venueExits: exits).signature
        for _ in 0..<20 {
            #expect(deriver.derive(events: events.shuffled(), venueExits: exits.shuffled()).signature == canonical)
        }
    }

    // MARK: - Materialization precedence (SPEC §2)

    @Test("Events inside a materialized window belong to it")
    func materializedWindowClaimsItsEvents() {
        let events = [
            Fixture.event(1, hours: 0),
            Fixture.event(2, hours: 1),
            Fixture.event(3, hours: 2)
        ]
        let record = MaterializedSession(
            id: Fixture.uuid(1),
            startedAt: Fixture.at(0),
            endedAt: Fixture.at(2),
            venueID: Fixture.anchorVenueID,
            note: "Dave's birthday",
            pinned: true
        )

        let sessions = deriver.derive(events: events, materialized: [record])
        #expect(sessions.count == 1)
        #expect(sessions[0].isMaterialized)
        #expect(sessions[0].id == Fixture.uuid(1))
        #expect(sessions[0].note == "Dave's birthday")
        #expect(sessions[0].pinned)
        #expect(sessions[0].venueID == Fixture.anchorVenueID)
        #expect(sessions[0].eventIDs.count == 3)
    }

    @Test("Derivation runs over the remainder outside materialized windows")
    func derivationRunsOverRemainder() {
        let events = [
            Fixture.event(1, hours: 0),
            Fixture.event(2, hours: 1),
            // Inside the 3 h window of event 2, but outside the materialized record.
            Fixture.event(3, hours: 2.5),
            Fixture.event(4, hours: 30)
        ]
        let record = MaterializedSession(
            id: Fixture.uuid(1),
            startedAt: Fixture.at(0),
            endedAt: Fixture.at(1)
        )

        let sessions = deriver.derive(events: events, materialized: [record])
        #expect(sessions.count == 3)
        #expect(sessions[0].id == Fixture.uuid(1))
        #expect(sessions[0].eventIDs == [Fixture.uuid(1), Fixture.uuid(2)])
        #expect(sessions[1].id == Fixture.uuid(3), "event 3 is outside the window, so it opens its own Session")
        #expect(!sessions[1].isMaterialized)
        #expect(sessions[2].id == Fixture.uuid(4))
    }

    @Test("A materialized record survives when every event in it is deleted")
    func materializedRecordNeverDangles() {
        // SPEC §2: "later event edits can no longer dangle a reference."
        let record = MaterializedSession(
            id: Fixture.uuid(1),
            startedAt: Fixture.at(0),
            endedAt: Fixture.at(2),
            note: "Dave's birthday"
        )

        let sessions = deriver.derive(events: [], materialized: [record])
        #expect(sessions.count == 1)
        #expect(sessions[0].id == Fixture.uuid(1))
        #expect(sessions[0].events.isEmpty)
        #expect(sessions[0].drinkCount == 0)
        #expect(sessions[0].note == "Dave's birthday")
    }

    @Test("A retro-log into a materialized window joins it without changing the ID")
    func retroLogIntoMaterializedWindowKeepsID() {
        let record = MaterializedSession(
            id: Fixture.uuid(5),
            startedAt: Fixture.at(0),
            endedAt: Fixture.at(3)
        )
        let events = [Fixture.event(5, hours: 0), Fixture.event(6, hours: 3)]

        let before = deriver.derive(events: events, materialized: [record])
        #expect(before[0].id == Fixture.uuid(5))

        // Retro-log an *earlier* event that still falls inside the window.
        let after = deriver.derive(
            events: events + [Fixture.event(4, hours: 0.5)],
            materialized: [record]
        )
        #expect(after.count == 1)
        #expect(after[0].id == Fixture.uuid(5), "the record owns the identity")
        #expect(after[0].eventIDs.count == 3)
    }

    @Test("Overlapping materialized windows resolve deterministically")
    func overlappingWindowsResolveDeterministically() {
        let first = MaterializedSession(id: Fixture.uuid(1), startedAt: Fixture.at(0), endedAt: Fixture.at(2))
        let second = MaterializedSession(id: Fixture.uuid(2), startedAt: Fixture.at(1), endedAt: Fixture.at(3))
        let events = [Fixture.event(10, hours: 1.5)]

        let canonical = deriver.derive(events: events, materialized: [first, second]).signature
        #expect(deriver.derive(events: events, materialized: [second, first]).signature == canonical)

        let sessions = deriver.derive(events: events, materialized: [second, first])
        #expect(sessions.first(where: { $0.id == Fixture.uuid(1) })?.eventIDs == [Fixture.uuid(10)])
        #expect(sessions.first(where: { $0.id == Fixture.uuid(2) })?.eventIDs.isEmpty == true)
    }

    @Test("Materialized and derived Sessions come back interleaved in time order")
    func outputIsOrderedByStart() {
        let record = MaterializedSession(id: Fixture.uuid(20), startedAt: Fixture.at(10), endedAt: Fixture.at(11))
        let events = [
            Fixture.event(1, hours: 0),
            Fixture.event(20, hours: 10.5),
            Fixture.event(30, hours: 40)
        ]
        let sessions = deriver.derive(events: events, materialized: [record])
        #expect(sessions.map(\.startedAt) == [Fixture.at(0), Fixture.at(10), Fixture.at(40)])
    }

    // MARK: - Queries

    @Test("The active Session is the one still inside its close window")
    func activeSessionTracksTheClock() {
        let events = [
            Fixture.event(1, hours: 0),
            Fixture.event(2, hours: 1)
        ]
        #expect(deriver.activeSession(events: events, asOf: Fixture.at(2))?.id == Fixture.uuid(1))
        #expect(deriver.activeSession(events: events, asOf: Fixture.at(3.99))?.id == Fixture.uuid(1))
        #expect(deriver.activeSession(events: events, asOf: Fixture.at(4.01)) == nil)
    }

    @Test("An event can be traced back to its Session")
    func sessionContainingEvent() {
        let events = [
            Fixture.event(1, hours: 0),
            Fixture.event(2, hours: 1),
            Fixture.event(3, hours: 20)
        ]
        #expect(deriver.session(containing: Fixture.uuid(2), events: events)?.id == Fixture.uuid(1))
        #expect(deriver.session(containing: Fixture.uuid(3), events: events)?.id == Fixture.uuid(3))
        #expect(deriver.session(containing: Fixture.uuid(99), events: events) == nil)
    }

    @Test("An empty log derives nothing")
    func emptyLogDerivesNothing() {
        #expect(deriver.derive(events: []).isEmpty)
        #expect(deriver.activeSession(events: []) == nil)
    }

    @Test("A single event is a complete Session")
    func singleEventIsASession() {
        let sessions = deriver.derive(events: [Fixture.event(1, hours: 0)])
        #expect(sessions.count == 1)
        #expect(sessions[0].startedAt == sessions[0].endedAt)
        #expect(sessions[0].duration == 0)
        #expect(sessions[0].drinkCount == 1)
    }

    @Test("A configurable inactivity window is honoured")
    func configurableInactivityWindow() {
        let short = SessionDeriver(configuration: .init(inactivityWindow: 30 * 60))
        let events = [Fixture.event(1, hours: 0), Fixture.event(2, hours: 1)]
        #expect(short.derive(events: events).count == 2)
        #expect(SessionDeriver().derive(events: events).count == 1)
    }
}
