import Foundation

// Value-type projections of the SwiftData models.
//
// Everything derived — Session boundaries, points, streaks, badges — is computed
// from these, never from `@Model` instances. That keeps the derivation pure,
// `Sendable`, testable without a `ModelContext`, and identical on every device
// (SPEC §1: derive, don't store).

// MARK: - DrinkEventSnapshot

public struct DrinkEventSnapshot: Identifiable, Hashable, Sendable, Codable {

    public let id: UUID
    public let type: DrinkType
    public let timestamp: Date
    public let latitude: Double?
    public let longitude: Double?
    public let horizontalAccuracy: Double?
    public let source: EventSource
    public let venueID: UUID?

    public init(
        id: UUID = UUID(),
        type: DrinkType = .alcoholic,
        timestamp: Date = Date(),
        latitude: Double? = nil,
        longitude: Double? = nil,
        horizontalAccuracy: Double? = nil,
        source: EventSource = .app,
        venueID: UUID? = nil
    ) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.source = source
        self.venueID = venueID
    }

    public init(_ event: DrinkEvent) {
        self.init(
            id: event.id,
            type: event.type,
            timestamp: event.timestamp,
            latitude: event.latitude,
            longitude: event.longitude,
            horizontalAccuracy: event.horizontalAccuracy,
            source: event.source,
            venueID: event.venue?.id
        )
    }

    public var hasCoordinates: Bool { latitude != nil && longitude != nil }

    /// Needs venue reconciliation on next app open (SPEC §6): logged off-device
    /// or off-app and never got a fix.
    public var needsVenueReconciliation: Bool {
        source.needsReconciliation && venueID == nil
    }

    /// The total order every deterministic computation in TallyKit sorts by.
    /// Timestamp first, UUID string as the tiebreaker — so insert order, sync
    /// arrival order, and array shuffling can never change a result.
    public static func isOrderedBefore(_ lhs: DrinkEventSnapshot, _ rhs: DrinkEventSnapshot) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

// MARK: - MaterializedSession

/// Value projection of a persisted `Session` record (SPEC §2 materialize-on-touch).
public struct MaterializedSession: Identifiable, Hashable, Sendable, Codable {

    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let venueID: UUID?
    public let note: String?
    public let pinned: Bool

    public init(
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        venueID: UUID? = nil,
        note: String? = nil,
        pinned: Bool = false
    ) {
        self.id = id
        // Windows are normalized so a malformed record can never swallow the
        // whole log or invert containment checks.
        self.startedAt = min(startedAt, endedAt)
        self.endedAt = max(startedAt, endedAt)
        self.venueID = venueID
        self.note = note
        self.pinned = pinned
    }

    public init(_ session: Session) {
        self.init(
            id: session.id,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            venueID: session.venue?.id,
            note: session.note,
            pinned: session.pinned
        )
    }

    /// Inclusive on both ends: an event logged exactly at a boundary belongs to
    /// the record rather than dangling outside it.
    public func contains(_ date: Date) -> Bool {
        date >= startedAt && date <= endedAt
    }

    public static func isOrderedBefore(_ lhs: MaterializedSession, _ rhs: MaterializedSession) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

// MARK: - VenueSnapshot

public struct VenueSnapshot: Identifiable, Hashable, Sendable, Codable {

    public let id: UUID
    public let name: String
    public let category: VenueCategory
    public let latitude: Double
    public let longitude: Double
    public let radiusMeters: Double
    public let source: VenueSource
    public let mapItemID: String?
    public let muted: Bool

    public init(
        id: UUID = UUID(),
        name: String = "",
        category: VenueCategory = .other,
        latitude: Double = 0,
        longitude: Double = 0,
        radiusMeters: Double = 75,
        source: VenueSource = .userDefined,
        mapItemID: String? = nil,
        muted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.source = source
        self.mapItemID = mapItemID
        self.muted = muted
    }

    public init(_ venue: Venue) {
        self.init(
            id: venue.id,
            name: venue.name,
            category: venue.category,
            latitude: venue.latitude,
            longitude: venue.longitude,
            radiusMeters: venue.radiusMeters,
            source: venue.source,
            mapItemID: venue.mapItemID,
            muted: venue.muted
        )
    }
}

public extension Sequence where Element == VenueSnapshot {
    /// Convenience lookup table for the scoring engine and UI.
    var byID: [UUID: VenueSnapshot] {
        reduce(into: [:]) { $0[$1.id] = $1 }
    }
}

// MARK: - SuppressedPlaceSnapshot

public struct SuppressedPlaceSnapshot: Identifiable, Hashable, Sendable, Codable {

    public let id: UUID
    public let latitude: Double
    public let longitude: Double
    public let radiusMeters: Double
    public let mapItemID: String?
    public let name: String?

    public init(
        id: UUID = UUID(),
        latitude: Double = 0,
        longitude: Double = 0,
        radiusMeters: Double = 75,
        mapItemID: String? = nil,
        name: String? = nil
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.mapItemID = mapItemID
        self.name = name
    }

    public init(_ place: SuppressedPlace) {
        self.init(
            id: place.id,
            latitude: place.latitude,
            longitude: place.longitude,
            radiusMeters: place.radiusMeters,
            mapItemID: place.mapItemID,
            name: place.name
        )
    }
}
