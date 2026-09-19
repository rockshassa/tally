import CoreLocation
import Foundation
import MapKit
import TallyKit

/// MapKit lookups, behind a protocol so the pipeline can be driven from a
/// fixture (Gate 1: "with a mocked fix and POI result…").
@MainActor
public protocol POISearching: AnyObject {

    /// SPEC §2 step 2: points of interest around the fix, filtered to the
    /// nightlife/brewery/restaurant/cafe categories, nearest first.
    func nearbyVenues(around fix: LocationFix, radiusMeters: CLLocationDistance) async -> [VenueCandidate]

    /// SPEC §2's venue search: the passes `VenueSearchPlan` describes, run in
    /// order, stopping at the first one that finds anything.
    ///
    /// Throws rather than returning `[]` on a MapKit failure, because the field
    /// has to tell *Search unavailable* from *No match* (SPEC §2).
    func search(_ request: VenueSearchRequest) async throws -> [VenueCandidate]
}

// MARK: - Live implementation

@MainActor
public final class POISearchService: POISearching {

    /// SPEC §2: "nightlife/bar/brewery/restaurant/cafe". MapKit has no separate
    /// "bar" category — bars live under `.nightlife`.
    public static let categories: [MKPointOfInterestCategory] = [
        .nightlife,
        .brewery,
        .distillery,
        .winery,
        .restaurant,
        .cafe
    ]

    public init() {}

    public func nearbyVenues(
        around fix: LocationFix,
        radiusMeters: CLLocationDistance
    ) async -> [VenueCandidate] {

        let request = MKLocalPointsOfInterestRequest(
            center: fix.coordinate,
            radius: min(max(radiusMeters, 50), MKLocalPointsOfInterestRequest.maxRadius)
        )
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: Self.categories)

        guard let response = try? await MKLocalSearch(request: request).start() else {
            // A failed lookup is indistinguishable from "nothing nearby" as far as
            // the user is concerned: the drink is logged either way (SPEC §2 step 4).
            return []
        }
        return Self.candidates(from: response.mapItems, fix: fix)
    }

    /// SPEC §2: "tried bar-first …, and **widened** — any place, then a wider
    /// region — only when the narrower pass finds nothing, so 'bowling alley'
    /// still works."
    ///
    /// The widening is why this is a loop and not one lookup: a bar called
    /// *Bowl* must beat the bowling alley, and the bowling alley must still be
    /// reachable when no bar answers to the name.
    public func search(_ request: VenueSearchRequest) async throws -> [VenueCandidate] {

        guard !request.trimmedQuery.isEmpty else { return [] }

        for pass in VenueSearchPlan.passes(for: request) {
            let found = try await run(pass)
            if !found.isEmpty { return found }
        }
        return []
    }

    /// One `MKLocalSearch`. The only place in this file that can throw.
    private func run(_ pass: VenueSearchRequest) async throws -> [VenueCandidate] {

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = pass.trimmedQuery
        request.resultTypes = [.pointOfInterest]

        if pass.scope == .bars {
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: Self.categories)
        }
        if let anchor = pass.anchor {
            // `radiusMeters` is a radius; the region takes a span, so the box
            // reaches that far in every direction.
            request.region = MKCoordinateRegion(
                center: anchor.coordinate,
                latitudinalMeters: pass.radiusMeters * 2,
                longitudinalMeters: pass.radiusMeters * 2
            )
        }

        do {
            let response = try await MKLocalSearch(request: request).start()
            // The category filter is MapKit's job on the `.bars` pass and
            // nobody's on the others — if you say you were at a bowling alley,
            // you were at a bowling alley.
            return Self.candidates(from: response.mapItems, fix: pass.anchor, filterToCategories: false)
        } catch let error as MKError where error.code == .placemarkNotFound {
            // "Nothing there" is an answer, not a failure: the next pass widens.
            return []
        } catch {
            throw VenueSearchError.lookupFailed(String(describing: error))
        }
    }

    // MARK: Mapping

    static func candidates(
        from mapItems: [MKMapItem],
        fix: LocationFix?,
        filterToCategories: Bool = true
    ) -> [VenueCandidate] {

        var seen = Set<String>()

        return mapItems
            .compactMap { item -> VenueCandidate? in
                guard let name = item.name, !name.isEmpty else { return nil }
                if filterToCategories {
                    guard let poi = item.pointOfInterestCategory, categories.contains(poi) else { return nil }
                }

                let coordinate = item.location.coordinate
                guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }

                let mapItemID = item.identifier?.rawValue
                let identity = mapItemID ?? "\(name)@\(coordinate.latitude),\(coordinate.longitude)"
                guard seen.insert(identity).inserted else { return nil }

                return VenueCandidate(
                    id: identity,
                    name: name,
                    category: VenueCategory(item.pointOfInterestCategory),
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    distanceMeters: fix?.distance(to: coordinate) ?? 0,
                    mapItemID: mapItemID,
                    categoryLabel: item.pointOfInterestCategory?.tallyDisplayName
                        ?? VenueCategory(item.pointOfInterestCategory).displayName
                )
            }
            .sorted(by: VenueCandidate.isOrderedBefore)
    }
}

// MARK: - Category bridging

public extension VenueCategory {

    /// SPEC §1 has four categories; MapKit has dozens. Anywhere that pours is a
    /// bar, anywhere that plates is a restaurant.
    nonisolated init(_ poi: MKPointOfInterestCategory?) {
        guard let poi else { self = .other; return }
        if MKPointOfInterestCategory.tallyBarCategories.contains(poi) {
            self = .bar
        } else if MKPointOfInterestCategory.tallyRestaurantCategories.contains(poi) {
            self = .restaurant
        } else {
            self = .other
        }
    }
}

extension MKPointOfInterestCategory {

    /// Anywhere whose business is pouring.
    nonisolated static let tallyBarCategories: Set<MKPointOfInterestCategory> = [
        .nightlife, .brewery, .distillery, .winery
    ]

    /// Anywhere whose business is plating.
    nonisolated static let tallyRestaurantCategories: Set<MKPointOfInterestCategory> = [
        .restaurant, .cafe, .bakery
    ]

    /// The specific label for the check-in chip — "Brewery" reads better than
    /// the bucket it maps into.
    nonisolated var tallyDisplayName: String {
        if self == .nightlife { return "Bar" }
        if self == .brewery { return "Brewery" }
        if self == .distillery { return "Distillery" }
        if self == .winery { return "Winery" }
        if self == .restaurant { return "Restaurant" }
        if self == .cafe { return "Café" }
        if self == .bakery { return "Bakery" }
        return "Place"
    }
}

// MARK: - Mock

/// Fixture-driven `POISearching` for previews and the Gate 1 acceptance items.
///
/// The search side records every request it is handed, which is how the Wave 4
/// acceptance item *"type three characters quickly: the service saw one
/// request"* is checked without a network, a simulator, or a clock.
@MainActor
public final class MockPOISearchService: POISearching {

    public var nearbyResults: [VenueCandidate]

    /// The answer for any query without a `resultsByQuery` entry.
    public var searchResults: [VenueCandidate]

    /// Per-query fixtures, keyed by the trimmed, lowercased query.
    public var resultsByQuery: [String: [VenueCandidate]] = [:]

    /// Held before answering. Read when the call starts, so each in-flight
    /// request keeps the delay it was launched with.
    public var searchDelay: Duration = .zero

    /// Per-query delays, for "a slow older response must not overwrite a newer
    /// one" — the one race that needs two different speeds at once.
    public var searchDelaysByQuery: [String: Duration] = [:]

    /// Thrown instead of answering. SPEC §2's *Search unavailable*.
    public var searchError: (any Error)?

    public private(set) var nearbyCallCount = 0

    /// Every request, in the order it arrived.
    public private(set) var searchRequests: [VenueSearchRequest] = []

    public var searchCallCount: Int { searchRequests.count }

    public init(
        nearbyResults: [VenueCandidate] = [],
        searchResults: [VenueCandidate] = [],
        resultsByQuery: [String: [VenueCandidate]] = [:]
    ) {
        self.nearbyResults = nearbyResults
        self.searchResults = searchResults
        self.resultsByQuery = resultsByQuery
    }

    public func nearbyVenues(around fix: LocationFix, radiusMeters: CLLocationDistance) async -> [VenueCandidate] {
        nearbyCallCount += 1
        return nearbyResults.sorted(by: VenueCandidate.isOrderedBefore)
    }

    public func search(_ request: VenueSearchRequest) async throws -> [VenueCandidate] {

        searchRequests.append(request)

        let key = request.trimmedQuery.lowercased()
        let delay = searchDelaysByQuery[key] ?? searchDelay
        if delay > .zero {
            // Deliberately swallowing cancellation: a cancelled pass still comes
            // back with its old answer, which is exactly the race
            // `VenueSearchModel`'s generation counter exists to lose.
            try? await Task.sleep(for: delay)
        }

        if let searchError { throw searchError }
        return resultsByQuery[key] ?? searchResults
    }
}
