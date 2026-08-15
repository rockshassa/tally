import Foundation
import SwiftData
import Testing
@testable import TallyKit

/// Gate 0 invariant: double-delivered event UUIDs merge idempotently
/// (PLAN Wave 0, SPEC §1 and §7).
@Suite("EventStore")
@MainActor
struct EventStoreTests {

    private func makeContext() throws -> ModelContext {
        ModelContext(try TallyStore.makeInMemoryContainer())
    }

    // MARK: - Dedupe

    @Test("Upserting the same event twice inserts one row")
    func upsertIsIdempotent() throws {
        let context = try makeContext()
        let snapshot = Fixture.event(1, hours: 0, .alcoholic, source: .watch)

        #expect(try EventStore.upsert(snapshot, in: context) == .inserted)
        #expect(try EventStore.upsert(snapshot, in: context) == .unchanged)
        #expect(try EventStore.upsert(snapshot, in: context) == .unchanged)

        let stored = try EventStore.allEvents(in: context)
        #expect(stored.count == 1)
        #expect(stored[0].id == Fixture.uuid(1))
        #expect(stored[0].source == .watch)
    }

    @Test("Both transports can deliver the same event without duplicating it")
    func doubleDeliveryFromTwoTransports() throws {
        // SPEC §7: WatchConnectivity and CloudKit can both deliver the same event.
        let context = try makeContext()
        let batch = (1...5).map { Fixture.event($0, hours: Double($0), .alcoholic, source: .watch) }

        try EventStore.upsert(batch, in: context)
        try EventStore.upsert(batch.shuffled(), in: context)
        try EventStore.upsert(batch.reversed(), in: context)

        #expect(try EventStore.allEvents(in: context).count == 5)
    }

    @Test("Merge order does not change the stored set")
    func mergeOrderIsIrrelevant() throws {
        let batch = (1...8).map {
            Fixture.event($0, hours: Double($0) * 0.5, $0.isMultiple(of: 2) ? .nonAlcoholic : .alcoholic)
        }

        let forward = try makeContext()
        try EventStore.upsert(batch, in: forward)

        let shuffled = try makeContext()
        try EventStore.upsert(batch.shuffled(), in: shuffled)

        #expect(try EventStore.snapshots(in: forward) == (try EventStore.snapshots(in: shuffled)))
    }

    @Test("An edited event updates in place rather than duplicating")
    func upsertUpdatesInPlace() throws {
        let context = try makeContext()
        let original = Fixture.event(1, hours: 0, .alcoholic)
        try EventStore.upsert(original, in: context)

        let corrected = DrinkEventSnapshot(
            id: original.id,
            type: .nonAlcoholic,
            timestamp: original.timestamp,
            source: .app
        )
        #expect(try EventStore.upsert(corrected, in: context) == .updated)

        let stored = try EventStore.allEvents(in: context)
        #expect(stored.count == 1)
        #expect(stored[0].type == .nonAlcoholic)
    }

    @Test("Upserted events keep their venue relationship")
    func upsertResolvesVenue() throws {
        let context = try makeContext()
        let venue = Venue(id: Fixture.anchorVenueID, name: "The Anchor", category: .bar)
        context.insert(venue)
        try context.save()

        try EventStore.upsert(
            Fixture.event(1, hours: 0, .alcoholic, venue: Fixture.anchorVenueID),
            in: context
        )

        let stored = try #require(try EventStore.allEvents(in: context).first)
        #expect(stored.venue?.id == Fixture.anchorVenueID)
        #expect(stored.snapshot.venueID == Fixture.anchorVenueID)
    }

    // MARK: - Logging and undo (SPEC §1)

    @Test("Logging a drink round-trips through the store")
    func logDrinkRoundTrips() throws {
        let context = try makeContext()
        try EventStore.logDrink(type: .alcoholic, timestamp: Fixture.origin, source: .widget, in: context)

        let stored = try #require(try EventStore.allEvents(in: context).first)
        #expect(stored.type == .alcoholic)
        #expect(stored.source == .widget)
        #expect(stored.hasCoordinates == false)
        #expect(stored.snapshot.needsVenueReconciliation, "SPEC §6: widget events get reconciled on next open")
    }

    @Test("Undo removes the most recent event of that type today and no-ops at zero")
    func undoRemovesMostRecentOfType() throws {
        let context = try makeContext()
        let day = Fixture.onDay(0, hour: 12)

        try EventStore.logDrink(type: .alcoholic, timestamp: day, in: context)
        try EventStore.logDrink(type: .alcoholic, timestamp: day.addingTimeInterval(3600), in: context)
        try EventStore.logDrink(type: .nonAlcoholic, timestamp: day.addingTimeInterval(1800), in: context)

        #expect(try EventStore.undoMostRecent(type: .alcoholic, onDayContaining: day, calendar: Fixture.calendar, in: context))

        let remaining = try EventStore.allEvents(in: context)
        #expect(remaining.count == 2)
        #expect(remaining.filter { $0.type == .alcoholic }.map(\.timestamp) == [day])

        #expect(try EventStore.undoMostRecent(type: .alcoholic, onDayContaining: day, calendar: Fixture.calendar, in: context))
        #expect(
            try EventStore.undoMostRecent(type: .alcoholic, onDayContaining: day, calendar: Fixture.calendar, in: context) == false,
            "no-op at zero"
        )
        #expect(try EventStore.allEvents(in: context).count == 1)
    }

    @Test("Undo never reaches into another day")
    func undoIsScopedToItsDay() throws {
        let context = try makeContext()
        try EventStore.logDrink(type: .alcoholic, timestamp: Fixture.onDay(0, hour: 20), in: context)

        let noop = try EventStore.undoMostRecent(
            type: .alcoholic,
            onDayContaining: Fixture.onDay(1, hour: 20),
            calendar: Fixture.calendar,
            in: context
        )
        #expect(noop == false)
        #expect(try EventStore.allEvents(in: context).count == 1)
    }

    // MARK: - Materialization (SPEC §2)

    @Test("Materializing a derived Session is idempotent and preserves the derived ID")
    func materializeIsIdempotent() throws {
        let context = try makeContext()
        let events = [
            Fixture.event(1, hours: 0, .alcoholic),
            Fixture.event(2, hours: 1, .nonAlcoholic)
        ]
        try EventStore.upsert(events, in: context)

        let derived = try #require(try SessionDeriver().derive(in: context).first)
        let record = try EventStore.materialize(derived, in: context)
        #expect(record.id == derived.id)
        #expect(record.id == Fixture.uuid(1))

        _ = try EventStore.materialize(derived, in: context)
        #expect(try context.fetch(FetchDescriptor<Session>()).count == 1)

        let redderived = try SessionDeriver().derive(in: context)
        #expect(redderived.count == 1)
        #expect(redderived[0].isMaterialized)
        #expect(redderived[0].eventIDs == [Fixture.uuid(1), Fixture.uuid(2)])
    }

    @Test("A materialized Session survives deletion of every event in it")
    func materializedSessionSurvivesEventDeletion() throws {
        let context = try makeContext()
        try EventStore.upsert([Fixture.event(1, hours: 0), Fixture.event(2, hours: 1)], in: context)

        let derived = try #require(try SessionDeriver().derive(in: context).first)
        _ = try EventStore.materialize(derived, in: context)

        for event in try EventStore.allEvents(in: context) { context.delete(event) }
        try context.save()

        let sessions = try SessionDeriver().derive(in: context)
        #expect(sessions.count == 1)
        #expect(sessions[0].id == derived.id)
        #expect(sessions[0].events.isEmpty)
    }

    // MARK: - Erase (SPEC §9)

    @Test("Erase-all empties every model")
    func eraseAllClearsTheStore() throws {
        let context = try makeContext()
        let venue = Venue(id: Fixture.anchorVenueID, name: "The Anchor", category: .bar)
        context.insert(venue)
        context.insert(SuppressedPlace(latitude: 1, longitude: 2))
        try context.save()
        try EventStore.upsert(Fixture.event(1, hours: 0, .alcoholic, venue: Fixture.anchorVenueID), in: context)

        try EventStore.eraseAll(in: context)

        #expect(try EventStore.allEvents(in: context).isEmpty)
        #expect(try EventStore.venues(in: context).isEmpty)
        #expect(try EventStore.materializedSessions(in: context).isEmpty)
        #expect(try context.fetch(FetchDescriptor<SuppressedPlace>()).isEmpty)
    }

    // MARK: - Counts (SPEC §6, §7)

    @Test("Today's counts are shared by every surface")
    func todayCounts() throws {
        let context = try makeContext()
        let day = Fixture.onDay(0, hour: 19)
        try EventStore.logDrink(type: .alcoholic, timestamp: day, in: context)
        try EventStore.logDrink(type: .alcoholic, timestamp: day.addingTimeInterval(600), in: context)
        try EventStore.logDrink(type: .nonAlcoholic, timestamp: day.addingTimeInterval(1200), in: context)
        try EventStore.logDrink(type: .alcoholic, timestamp: Fixture.onDay(1, hour: 19), in: context)

        let counts = try TodayCounts.load(on: day, calendar: Fixture.calendar, in: context)
        #expect(counts.alcoholic == 2)
        #expect(counts.nonAlcoholic == 1)
    }
}
