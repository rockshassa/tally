import CoreLocation
import Foundation
import TallyKit

/// A place the inference pipeline thinks you might be at (SPEC §2).
///
/// Candidates come from two sources — saved venues whose geofence you're inside,
/// and MapKit POIs near the fix — and are otherwise interchangeable, so the
/// check-in sheet and the History venue picker both speak this one type.
nonisolated public struct VenueCandidate: Identifiable, Hashable, Sendable {

    /// Stable within one search: the MapKit identifier, the saved venue's UUID,
    /// or a coordinate-derived fallback.
    public let id: String

    public let name: String
    public let category: VenueCategory

    public let latitude: Double
    public let longitude: Double

    /// Distance from the fix that produced this candidate.
    public let distanceMeters: CLLocationDistance

    /// MapKit identity, used to dedupe venues across devices (SPEC §1).
    public let mapItemID: String?

    /// The raw POI category, shown on the chip when it's more specific than
    /// `category` ("Brewery" rather than "Bar").
    public let categoryLabel: String

    /// Set when this candidate is already a saved `Venue` — confirming reuses it
    /// instead of creating a duplicate.
    public let existingVenueID: UUID?

    public init(
        id: String,
        name: String,
        category: VenueCategory,
        latitude: Double,
        longitude: Double,
        distanceMeters: CLLocationDistance,
        mapItemID: String? = nil,
        categoryLabel: String? = nil,
        existingVenueID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.distanceMeters = distanceMeters
        self.mapItemID = mapItemID
        self.categoryLabel = categoryLabel ?? category.displayName
        self.existingVenueID = existingVenueID
    }

    /// A saved venue as a candidate, measured from `fix` when there is one.
    public init(venue: VenueSnapshot, fix: LocationFix?) {
        self.init(
            id: venue.id.uuidString,
            name: venue.name,
            category: venue.category,
            latitude: venue.latitude,
            longitude: venue.longitude,
            distanceMeters: fix?.distance(toLatitude: venue.latitude, longitude: venue.longitude) ?? 0,
            mapItemID: venue.mapItemID,
            categoryLabel: venue.category.displayName,
            existingVenueID: venue.id
        )
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public var isSaved: Bool { existingVenueID != nil }

    /// "Bar · 40 m away", the chip in the check-in sheet mockup.
    public var chipText: String {
        "\(categoryLabel) · \(distanceMeters.tallyShortDistanceDescription) away"
    }

    public var systemImageName: String {
        switch category {
        case .home: "house.fill"
        case .bar: "wineglass.fill"
        case .restaurant: "fork.knife"
        case .other: "mappin.circle.fill"
        }
    }

    /// Nearest first, name as a deterministic tiebreaker.
    public static func isOrderedBefore(_ lhs: VenueCandidate, _ rhs: VenueCandidate) -> Bool {
        if lhs.distanceMeters != rhs.distanceMeters { return lhs.distanceMeters < rhs.distanceMeters }
        return lhs.id < rhs.id
    }
}

// MARK: - Check-in payload

/// Everything the check-in sheet needs, and nothing it doesn't (SPEC §2 step 3).
///
/// The integrator's `checkInSheet(context:)` slot is handed one of these.
nonisolated public struct CheckInContext: Identifiable, Hashable, Sendable {

    /// The derived Session this check-in would tag. Also the sheet's identity —
    /// one prompt per outing, never one per drink (SPEC §2).
    public let sessionID: UUID

    /// The event whose fix produced the prompt.
    public let eventID: UUID

    /// The confident candidate: nearest, and within accuracy + 50 m.
    public let primary: VenueCandidate

    /// "Somewhere else nearby…" — everything else the search turned up.
    public let alternates: [VenueCandidate]

    public let fix: LocationFix

    public var id: UUID { sessionID }

    public init(
        sessionID: UUID,
        eventID: UUID,
        primary: VenueCandidate,
        alternates: [VenueCandidate] = [],
        fix: LocationFix
    ) {
        self.sessionID = sessionID
        self.eventID = eventID
        self.primary = primary
        self.alternates = alternates
        self.fix = fix
    }

    public var allCandidates: [VenueCandidate] {
        ([primary] + alternates).sorted(by: VenueCandidate.isOrderedBefore)
    }
}

// MARK: - Pipeline result

/// What the pipeline decided for one logged drink (SPEC §2 steps 1–4).
nonisolated public enum VenueInferenceOutcome: Hashable, Sendable {

    /// No fix at all — permission denied, retro-logged, or the ~5 s budget
    /// expired. The event keeps its timestamp and nothing else.
    case noFix

    /// Step 1: the fix fell inside a saved venue's geofence. Auto-tagged, no prompt.
    case savedVenue(UUID)

    /// Already checked in (or checked out) this Session — auto-tag or stay quiet,
    /// but never ask twice (SPEC §2: "you get asked once per outing").
    case sessionMemory(UUID?)

    /// Step 3: a single confident candidate. The sheet should be offered.
    case prompt(CheckInContext)

    /// Step 4: ambiguous or nothing found — coordinates only, assignable later
    /// from History.
    case coordinatesOnly
}
