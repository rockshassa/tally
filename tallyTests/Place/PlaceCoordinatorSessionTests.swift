import CoreLocation
import Foundation
import SwiftData
import TallyKit
import Testing
@testable import tally

/// SPEC §1's live Session card, all the way through to the store.
///
/// > While a Session is active (§2), the counter shows a live Session card …
/// > **Tapping the card opens the check-in picker (§2)** to assign — or
/// > change — the Session's venue: the one picker, not a second UI.
///
/// Three things have to be true and none of them is visible from a view:
/// picking writes the venue onto *every* drink in the outing (and onto the
/// materialized record when there is one), backing out records nothing —
/// nobody asked a question — and opening the card's picker takes over any
/// check-in prompt still outstanding for the same Session.
@Suite("Live session card — the picker it opens")
@MainActor
struct PlaceCoordinatorSessionTests {

    // MARK: Fixtures

    private static let latitude = 51.5074
    private static let longitude = -0.1278

    private let fix = LocationFix(latitude: latitude, longitude: longitude, horizontalAccuracy: 10)

    private func makeContext() throws -> ModelContext {
        ModelContext(try TallyStore.makeInMemoryContainer())
    }

    /// A private defaults suite per test: `CheckInMemory` persists, and a test
    /// that leaked into `.standard` would answer the next one's question.
    private func makeMemory() -> CheckInMemory {
        let defaults = UserDefaults(suiteName: "tally.tests.\(UUID().uuidString)") ?? .standard
        let memory = CheckInMemory(defaults: defaults)
        memory.reset()
        return memory
    }

    private func makeCoordinator(
        _ context: ModelContext,
        memory: CheckInMemory,
        nearby: [VenueCandidate] = []
    ) -> PlaceCoordinator {
        PlaceCoordinator(
            modelContext: context,
            locationService: MockLocationService(stagedFix: fix),
            poiSearch: MockPOISearchService(nearbyResults: nearby),
            memory: memory
        )
    }

    private var candidate: VenueCandidate {
        VenueCandidate(
            id: "poi.anchor",
            name: "The Anchor",
            category: .bar,
            latitude: Self.latitude,
            longitude: Self.longitude,
            distanceMeters: 40,
            mapItemID: "poi.anchor"
        )
    }

    /// Two drinks half an hour apart — one outing by SPEC §2's 3 h rule.
    @discardableResult
    private func logOuting(in context: ModelContext, at start: Date) throws -> [DrinkEvent] {
        [
            try EventStore.logDrink(type: .alcoholic, timestamp: start, in: context),
            try EventStore.logDrink(type: .alcoholic, timestamp: start.addingTimeInterval(1_800), in: context)
        ]
    }

    private func session(in context: ModelContext) throws -> DerivedSession {
        let sessions = try SessionDeriver().derive(in: context)
        return try #require(sessions.last)
    }

    // MARK: - Resolving

    @Test("Picking a venue tags every drink in the outing")
    func resolveTagsEveryEvent() throws {
        let context = try makeContext()
        let memory = makeMemory()
        let coordinator = makeCoordinator(context, memory: memory)

        let events = try logOuting(in: context, at: Date().addingTimeInterval(-3_600))
        let session = try session(in: context)
        let request = CheckInPickerRequest(session: SessionTarget(session: session))

        let venueID = try #require(coordinator.resolvePicker(request, with: candidate))

        for event in events {
            #expect(event.venue?.id == venueID)
        }
        // SPEC §2: later drinks in the outing auto-tag silently, which is what
        // the memory is for.
        #expect(memory.decision(for: session.id) == .confirmed(venueID))
        #expect(coordinator.lastResolvedVenueID == venueID)
        #expect(coordinator.pendingPicker == nil)
    }

    @Test("A materialized session is repointed alongside its events")
    func resolveRepointsMaterializedRecord() throws {
        let context = try makeContext()
        let memory = makeMemory()
        let coordinator = makeCoordinator(context, memory: memory)

        let start = Date().addingTimeInterval(-3_600)
        try logOuting(in: context, at: start)

        // Materialize it the way History does: the derived ID becomes the
        // record's identity (SPEC §2).
        let derived = try session(in: context)
        context.insert(TallyKit.Session(materializing: derived))
        try context.save()

        let materialized = try session(in: context)
        #expect(materialized.isMaterialized)

        let request = CheckInPickerRequest(session: SessionTarget(session: materialized))
        let venueID = try #require(coordinator.resolvePicker(request, with: candidate))

        let record = try #require(try EventStore.session(id: materialized.id, in: context))
        #expect(record.venue?.id == venueID)
        #expect(try SessionDeriver().derive(in: context).last?.venueID == venueID)
    }

    @Test("An existing venue is reused, never duplicated (SPEC §1)")
    func resolveReusesASavedVenue() throws {
        let context = try makeContext()
        let memory = makeMemory()
        let coordinator = makeCoordinator(context, memory: memory)

        let existing = Venue(
            name: "The Anchor",
            category: .bar,
            latitude: Self.latitude,
            longitude: Self.longitude,
            source: .mapKitPOI,
            mapItemID: "poi.anchor"
        )
        context.insert(existing)
        try context.save()

        try logOuting(in: context, at: Date().addingTimeInterval(-3_600))
        let session = try session(in: context)

        let venueID = coordinator.resolvePicker(
            CheckInPickerRequest(session: SessionTarget(session: session)),
            with: candidate
        )

        #expect(venueID == existing.id)
        #expect(try context.fetch(FetchDescriptor<Venue>()).count == 1)
    }

    // MARK: - Dismissing

    @Test("Backing out of the card's picker records nothing — nobody asked")
    func dismissRecordsNothing() throws {
        let context = try makeContext()
        let memory = makeMemory()
        let coordinator = makeCoordinator(context, memory: memory)

        try logOuting(in: context, at: Date().addingTimeInterval(-3_600))
        let session = try session(in: context)

        coordinator.dismissPicker(CheckInPickerRequest(session: SessionTarget(session: session)))

        #expect(memory.decision(for: session.id) == nil)
        #expect(coordinator.pendingPicker == nil)
    }

    @Test("A check-in origin still records its dismissal — that one was a question")
    func dismissFromACheckInStillRecords() throws {
        let context = try makeContext()
        let memory = makeMemory()
        let coordinator = makeCoordinator(context, memory: memory)

        let sessionID = UUID()
        let prompt = CheckInPrompt(
            sessionID: sessionID,
            eventID: UUID(),
            primary: candidate,
            fix: fix
        )

        coordinator.dismissPicker(CheckInPickerRequest(prompt: prompt))

        #expect(memory.decision(for: sessionID) == .dismissed)
    }

    // MARK: - Presenting

    @Test("The card's picker takes over an outstanding check-in prompt")
    func presentingClearsAnOutstandingPrompt() async throws {
        let context = try makeContext()
        let memory = makeMemory()
        let coordinator = makeCoordinator(context, memory: memory, nearby: [candidate])

        let event = try EventStore.logDrink(type: .alcoholic, timestamp: Date(), in: context)
        let outcome = await coordinator.attachPlace(toEventWith: event.id)

        guard case .prompt(let prompt) = outcome else {
            Issue.record("A single confident candidate should have prompted, got \(outcome)")
            return
        }
        #expect(coordinator.pendingCheckIn != nil)

        coordinator.presentPicker(forSessionWith: prompt.sessionID)

        // One outing, one sheet.
        #expect(coordinator.pendingCheckIn == nil)
        #expect(coordinator.pendingPicker?.sessionID == prompt.sessionID)
        #expect(coordinator.pendingPicker?.id == prompt.sessionID)
        #expect(coordinator.pendingPicker?.isFromNotification == false)
        #expect(coordinator.pendingPicker?.sessionTarget?.eventIDs == [event.id])
    }

    @Test("The picker is anchored on where the drinks were logged")
    func presentingAnchorsOnTheOuting() throws {
        let context = try makeContext()
        let memory = makeMemory()
        let coordinator = makeCoordinator(context, memory: memory)

        try EventStore.logDrink(
            type: .alcoholic,
            timestamp: Date().addingTimeInterval(-600),
            latitude: Self.latitude,
            longitude: Self.longitude,
            horizontalAccuracy: 12,
            in: context
        )
        let session = try session(in: context)

        coordinator.presentPicker(forSessionWith: session.id)

        #expect(coordinator.pendingPicker?.fix?.latitude == Self.latitude)
        #expect(coordinator.pendingPicker?.sessionTarget?.isMaterialized == false)
    }

    @Test("A session that isn't there opens nothing")
    func unknownSessionOpensNothing() throws {
        let context = try makeContext()
        let coordinator = makeCoordinator(context, memory: makeMemory())

        coordinator.presentPicker(forSessionWith: UUID())

        #expect(coordinator.pendingPicker == nil)
    }
}
