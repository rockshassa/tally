import Foundation
import SwiftData
import TallyKit
import Testing
@testable import tally

/// "Start a Session?" answered in the picker.
///
/// A Bar Radar tap-through with nothing logged used to resolve the venue and
/// stop there — the pick only reached a drink if a later fix happened to land
/// inside the venue's radius. The pick and the first drink are now one step:
/// choosing where you are logs the drink there.
@Suite("Start a session — the pick logs the first drink")
@MainActor
struct StartSessionPickTests {

    // MARK: Fixtures

    private func makeContext() throws -> ModelContext {
        ModelContext(try TallyStore.makeInMemoryContainer())
    }

    private func makeMemory() -> CheckInMemory {
        let defaults = UserDefaults(suiteName: "tally.tests.\(UUID().uuidString)") ?? .standard
        let memory = CheckInMemory(defaults: defaults)
        memory.reset()
        return memory
    }

    private func makeCoordinator(_ context: ModelContext, memory: CheckInMemory) -> PlaceCoordinator {
        PlaceCoordinator(
            modelContext: context,
            locationService: MockLocationService(stagedFix: nil),
            poiSearch: MockPOISearchService(nearbyResults: []),
            memory: memory
        )
    }

    private var candidate: VenueCandidate {
        VenueCandidate(
            id: "poi.anchor",
            name: "The Anchor",
            category: .bar,
            latitude: 51.5074,
            longitude: -0.1278,
            distanceMeters: 40,
            mapItemID: "poi.anchor"
        )
    }

    // MARK: - Presenting

    @Test("With nothing logged, the tap-through is a 'Start a session' picker")
    func noSessionStartsSession() throws {
        let coordinator = makeCoordinator(try makeContext(), memory: makeMemory())

        coordinator.presentPickerForCurrentFix(suggesting: candidate)

        let request = try #require(coordinator.pendingPicker)
        #expect(request.startsSession)
        #expect(request.title() == "Start a session")
        #expect(request.detail != nil)
    }

    @Test("Mid-session, the tap-through only asks where you are")
    func activeSessionOnlyTags() throws {
        let context = try makeContext()
        let coordinator = makeCoordinator(context, memory: makeMemory())
        try EventStore.logDrink(type: .alcoholic, timestamp: Date().addingTimeInterval(-600), in: context)

        coordinator.presentPickerForCurrentFix(suggesting: candidate)

        let request = try #require(coordinator.pendingPicker)
        #expect(!request.startsSession)
        #expect(request.title() == "Where are you?")
        #expect(request.detail == nil)
    }

    // MARK: - Picking

    @Test("Picking logs one drink, already tagged to the venue")
    func pickLogsTaggedDrink() throws {
        let context = try makeContext()
        let memory = makeMemory()
        let coordinator = makeCoordinator(context, memory: memory)

        coordinator.presentPickerForCurrentFix(suggesting: candidate)
        let request = try #require(coordinator.pendingPicker)
        let venueID = try #require(coordinator.resolvePicker(request, with: candidate))

        let events = try context.fetch(FetchDescriptor<DrinkEvent>())
        #expect(events.count == 1)
        #expect(events.first?.type == .alcoholic)
        #expect(events.first?.venue?.id == venueID)

        // The Session starts tagged, and later drinks auto-tag silently.
        let session = try #require(try SessionDeriver().derive(in: context).last)
        #expect(session.venueID == venueID)
        #expect(memory.decision(for: session.id) == .confirmed(venueID))
        #expect(coordinator.pendingPicker == nil)
    }

    @Test("Picking goes through the app's log path when one is wired")
    func pickUsesInjectedLogger() throws {
        let context = try makeContext()
        let coordinator = makeCoordinator(context, memory: makeMemory())

        var loggedVenue: String?
        coordinator.firstDrinkLogger = { venue, context in
            loggedVenue = venue.name
            return (try? EventStore.logDrink(type: .alcoholic, venue: venue, in: context))?.id
        }

        coordinator.presentPickerForCurrentFix(suggesting: candidate)
        let request = try #require(coordinator.pendingPicker)
        coordinator.resolvePicker(request, with: candidate)

        #expect(loggedVenue == "The Anchor")
    }

    @Test("Mid-session, picking tags the outing and logs nothing")
    func midSessionPickLogsNothing() throws {
        let context = try makeContext()
        let coordinator = makeCoordinator(context, memory: makeMemory())
        let existing = try EventStore.logDrink(type: .alcoholic, timestamp: Date().addingTimeInterval(-600), in: context)

        coordinator.presentPickerForCurrentFix(suggesting: candidate)
        let request = try #require(coordinator.pendingPicker)
        let venueID = try #require(coordinator.resolvePicker(request, with: candidate))

        #expect(try context.fetch(FetchDescriptor<DrinkEvent>()).count == 1)
        #expect(existing.venue?.id == venueID)
    }

    @Test("Backing out logs nothing")
    func dismissLogsNothing() throws {
        let context = try makeContext()
        let coordinator = makeCoordinator(context, memory: makeMemory())

        coordinator.presentPickerForCurrentFix(suggesting: candidate)
        coordinator.dismissPicker()

        #expect(try context.fetch(FetchDescriptor<DrinkEvent>()).isEmpty)
    }
}
