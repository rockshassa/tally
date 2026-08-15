import Foundation
import SwiftData

/// A place where drinks happen (SPEC §1, §2).
///
/// Venue dedupe is an app-level concern (SPEC §1): matched by `mapItemID`, or by
/// name + proximity for user-defined venues. There is deliberately no unique
/// constraint on any attribute.
@Model
public final class Venue {

    public var id: UUID = UUID()
    public var name: String = ""

    /// Raw storage for `category`.
    public var categoryRaw: String = VenueCategory.other.rawValue

    public var latitude: Double = 0
    public var longitude: Double = 0

    /// Geofence radius (SPEC §1: default 75 m, home 100 m).
    public var radiusMeters: Double = 75

    /// Raw storage for `source`.
    public var sourceRaw: String = VenueSource.userDefined.rawValue

    /// MapKit identifier for POI venues; nil for user-defined ones.
    public var mapItemID: String?

    /// Opts this venue out of Bar Radar (SPEC §2).
    public var muted: Bool = false

    public var createdAt: Date = Date.distantPast

    /// Inverse of `DrinkEvent.venue`. Optional to-many, nullify on delete —
    /// deleting a venue untags its events rather than destroying them.
    @Relationship(deleteRule: .nullify, inverse: \DrinkEvent.venue)
    public var events: [DrinkEvent]?

    /// Inverse of `Session.venue`.
    @Relationship(deleteRule: .nullify, inverse: \Session.venue)
    public var sessions: [Session]?

    public init(
        id: UUID = UUID(),
        name: String = "",
        category: VenueCategory = .other,
        latitude: Double = 0,
        longitude: Double = 0,
        radiusMeters: Double? = nil,
        source: VenueSource = .userDefined,
        mapItemID: String? = nil,
        muted: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.categoryRaw = category.rawValue
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters ?? category.defaultRadiusMeters
        self.sourceRaw = source.rawValue
        self.mapItemID = mapItemID
        self.muted = muted
        self.createdAt = createdAt
        self.events = []
        self.sessions = []
    }

    // MARK: Enum accessors (computed — not persisted directly)

    public var category: VenueCategory {
        get { VenueCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    public var source: VenueSource {
        get { VenueSource(rawValue: sourceRaw) ?? .userDefined }
        set { sourceRaw = newValue.rawValue }
    }

    public var snapshot: VenueSnapshot {
        VenueSnapshot(
            id: id,
            name: name,
            category: category,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: radiusMeters,
            source: source,
            mapItemID: mapItemID,
            muted: muted
        )
    }
}
