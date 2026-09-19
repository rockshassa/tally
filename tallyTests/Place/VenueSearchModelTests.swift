import CoreLocation
import Foundation
import TallyKit
import Testing
@testable import tally

/// SPEC §2's "as you type", as a race that has to come out the same way every
/// time.
///
/// > The search field searches MapKit **as you type**: debounced (~300 ms), one
/// > in-flight request at a time, stale responses discarded.
///
/// The debounce is injected at 10 ms so the suite runs in milliseconds; every
/// other number here is the model's own. `MockPOISearchService` records each
/// request, which is what turns "one in-flight request at a time" into an
/// assertion rather than a hope.

private enum Fixture {

    static let latitude = 51.5074
    static let longitude = -0.1278

    static let fix = LocationFix(latitude: latitude, longitude: longitude, horizontalAccuracy: 10)

    static func poi(_ name: String, distance: CLLocationDistance = 100) -> VenueCandidate {
        VenueCandidate(
            id: "poi.\(name.lowercased())",
            name: name,
            category: .bar,
            latitude: latitude,
            longitude: longitude,
            distanceMeters: distance,
            mapItemID: "poi.\(name.lowercased())"
        )
    }

    /// Long enough for a 10 ms debounce plus a hop through the service, short
    /// enough that a hung test fails fast.
    ///
    /// Only used where the assertion is that *nothing* happened — everywhere
    /// else the suite waits for the condition instead of for the clock, because
    /// every test in this bundle shares one main actor and a fixed sleep on a
    /// congested one is a coin toss.
    static let settle: Duration = .milliseconds(300)
}

@Suite("Venue search — the typing model")
@MainActor
struct VenueSearchModelTests {

    private func model(
        _ service: MockPOISearchService,
        anchor: LocationFix? = Fixture.fix
    ) -> VenueSearchModel {
        VenueSearchModel(service: service, anchor: anchor, debounce: .milliseconds(10))
    }

    /// Waits for the thing being asserted rather than for a number of
    /// milliseconds. The whole bundle shares one main actor, so a fixed sleep
    /// measures the machine's load as much as the model's behaviour.
    private func wait(
        upTo timeout: Duration = .seconds(10),
        until condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits for a search to reach one of its resting states.
    private func settle(_ model: VenueSearchModel) async throws {
        try await wait { model.state != .searching }
    }

    // MARK: Debounce

    @Test("Three characters typed quickly are one request, for the last of them")
    func debouncesToOneRequest() async throws {
        let service = MockPOISearchService(searchResults: [Fixture.poi("The Anchor")])
        let model = model(service)

        model.query = "a"
        model.query = "an"
        model.query = "anc"

        try await settle(model)

        #expect(service.searchCallCount == 1)
        #expect(service.searchRequests.first?.trimmedQuery == "anc")
        #expect(model.state == .results)
        #expect(model.results.map(\.name) == ["The Anchor"])
    }

    @Test("A single character is not a search")
    func doesNotSearchBelowTheThreshold() async throws {
        let service = MockPOISearchService(searchResults: [Fixture.poi("The Anchor")])
        let model = model(service)

        model.query = "a"
        try await Task.sleep(for: Fixture.settle)

        #expect(service.searchCallCount == 0)
        #expect(model.state == .idle)
        #expect(model.results.isEmpty)
    }

    @Test("Clearing the field goes straight back to idle, with nothing to show")
    func clearingResets() async throws {
        let service = MockPOISearchService(searchResults: [Fixture.poi("The Anchor")])
        let model = model(service)

        model.query = "anchor"
        try await settle(model)
        #expect(model.state == .results)

        model.clear()

        // Synchronously: the list must not keep showing last night's answers
        // while a cancellation lands.
        #expect(model.state == .idle)
        #expect(model.results.isEmpty)

        try await Task.sleep(for: Fixture.settle)
        #expect(service.searchCallCount == 1)
    }

    // MARK: Staleness

    @Test("A slow older response never overwrites a newer result")
    func staleResponsesAreDiscarded() async throws {
        let service = MockPOISearchService()
        service.resultsByQuery["slow"] = [Fixture.poi("Slow Bar")]
        service.resultsByQuery["quick"] = [Fixture.poi("Quick Bar")]
        service.searchDelaysByQuery["slow"] = .milliseconds(400)

        let model = model(service)

        model.query = "slow"
        // The slow request has to be genuinely in flight before the second
        // query overtakes it, or there is no race left to lose.
        try await wait { service.searchCallCount == 1 }
        #expect(service.searchCallCount == 1)

        model.query = "quick"
        try await wait { model.results.map(\.name) == ["Quick Bar"] }

        #expect(service.searchCallCount == 2)
        #expect(model.results.map(\.name) == ["Quick Bar"])
        #expect(model.state == .results)

        // The cancelled pass comes back with its old answer; it must stay lost.
        try await Task.sleep(for: Fixture.settle)
        #expect(model.results.map(\.name) == ["Quick Bar"])
    }

    // MARK: States

    @Test("MapKit answering nothing is empty — not unavailable")
    func emptyIsNotUnavailable() async throws {
        let service = MockPOISearchService(searchResults: [])
        let model = model(service)

        model.query = "nowhere"
        try await settle(model)

        #expect(model.state == .empty)
        #expect(model.results.isEmpty)
    }

    @Test("A thrown lookup reads as unavailable — SPEC §2's distinct failure")
    func failureIsUnavailable() async throws {
        let service = MockPOISearchService(searchResults: [Fixture.poi("The Anchor")])
        service.searchError = VenueSearchError.lookupFailed("offline")
        let model = model(service)

        model.query = "anchor"
        try await settle(model)

        #expect(model.state == .unavailable)
        #expect(model.results.isEmpty)
    }

    @Test("Recovering from a failure clears the failure")
    func recoversAfterFailure() async throws {
        let service = MockPOISearchService(searchResults: [Fixture.poi("The Anchor")])
        service.searchError = VenueSearchError.lookupFailed("offline")
        let model = model(service)

        model.query = "anchor"
        try await settle(model)
        #expect(model.state == .unavailable)

        service.searchError = nil
        model.query = "anchors"
        try await wait { model.state == .results }

        #expect(model.state == .results)
        #expect(model.results.map(\.name) == ["The Anchor"])
    }

    @Test("Typing sets searching before anything has been asked")
    func reportsSearchingImmediately() {
        let service = MockPOISearchService()
        let model = model(service)

        model.query = "anchor"

        #expect(model.state == .searching)
        #expect(service.searchCallCount == 0)
    }

    // MARK: The request

    @Test("The request carries the anchor, the radius, and the bar-first scope")
    func buildsTheRequest() async throws {
        let service = MockPOISearchService()
        let model = model(service)

        model.query = "anchor"
        try await wait { service.searchCallCount == 1 }

        let request = try #require(service.searchRequests.first)
        #expect(request.anchor == Fixture.fix)
        #expect(request.radiusMeters == VenueSearchRequest.defaultRadiusMeters)
        #expect(request.scope == .bars)
    }

    @Test("Results come back ranked, not in MapKit's order")
    func ranksResults() async throws {
        let service = MockPOISearchService(searchResults: [
            Fixture.poi("Anchor Yard", distance: 40),
            Fixture.poi("The Anchor", distance: 4_000)
        ])
        let model = model(service, anchor: nil)

        model.query = "The Anchor"
        try await Task.sleep(for: Fixture.settle)

        #expect(model.results.map(\.name) == ["The Anchor", "Anchor Yard"])
    }

    @Test("Cancelling stops the pending search from ever landing")
    func cancelStopsAScheduledSearch() async throws {
        let service = MockPOISearchService(searchResults: [Fixture.poi("The Anchor")])
        let model = model(service)

        model.query = "anchor"
        model.cancel()

        try await Task.sleep(for: Fixture.settle)

        #expect(service.searchCallCount == 0)
    }
}
