import Foundation
import SwiftData

/// A "don't ask here" marker written by the Bar Radar discovery tier (SPEC §2).
///
/// Two plain dismissals at the same spot auto-suppress it; "Not a bar" suppresses
/// it immediately. Suppressed places are listed (and can be un-suppressed) in
/// Settings (SPEC §9).
@Model
public final class SuppressedPlace {

    public var id: UUID = UUID()
    public var latitude: Double = 0
    public var longitude: Double = 0

    /// Default 75 m, matching the POI search radius (SPEC §1, §2).
    public var radiusMeters: Double = 75

    public var mapItemID: String?

    /// Display name captured at suppression time, when one was known.
    public var name: String?

    /// Ordering key for the Settings list. Not part of SPEC §1's field list;
    /// carries no aggregate meaning.
    public var createdAt: Date = Date.distantPast

    public init(
        id: UUID = UUID(),
        latitude: Double = 0,
        longitude: Double = 0,
        radiusMeters: Double = 75,
        mapItemID: String? = nil,
        name: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.mapItemID = mapItemID
        self.name = name
        self.createdAt = createdAt
    }

    public var snapshot: SuppressedPlaceSnapshot {
        SuppressedPlaceSnapshot(
            id: id,
            latitude: latitude,
            longitude: longitude,
            radiusMeters: radiusMeters,
            mapItemID: mapItemID,
            name: name
        )
    }
}
