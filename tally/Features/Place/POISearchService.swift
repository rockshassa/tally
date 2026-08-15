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

    /// Free-text search, used by History's manual venue assignment.
    func search(_ query: String, near coordinate: CLLocationCoordinate2D?) async -> [VenueCandidate]
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

    public func search(_ query: String, near coordinate: CLLocationCoordinate2D?) async -> [VenueCandidate] {

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.resultTypes = [.pointOfInterest]
        if let coordinate {
            request.region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 20_000,
                longitudinalMeters: 20_000
            )
        }

        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }

        let fix = coordinate.map {
            LocationFix(latitude: $0.latitude, longitude: $0.longitude, horizontalAccuracy: 0)
        }
        // Manual search is deliberately unfiltered by category — if you say you
        // were at a bowling alley, you were at a bowling alley.
        return Self.candidates(from: response.mapItems, fix: fix, filterToCategories: false)
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
@MainActor
public final class MockPOISearchService: POISearching {

    public var nearbyResults: [VenueCandidate]
    public var searchResults: [VenueCandidate]

    public private(set) var nearbyCallCount = 0

    public init(nearbyResults: [VenueCandidate] = [], searchResults: [VenueCandidate] = []) {
        self.nearbyResults = nearbyResults
        self.searchResults = searchResults
    }

    public func nearbyVenues(around fix: LocationFix, radiusMeters: CLLocationDistance) async -> [VenueCandidate] {
        nearbyCallCount += 1
        return nearbyResults.sorted(by: VenueCandidate.isOrderedBefore)
    }

    public func search(_ query: String, near coordinate: CLLocationCoordinate2D?) async -> [VenueCandidate] {
        searchResults
    }
}
