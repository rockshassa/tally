import Foundation
import SwiftData

/// A single logged drink (SPEC §1).
///
/// CloudKit-safety rules enforced here and audited by `CloudKitSafetyTests`:
/// * no `@Attribute(.unique)` — identity is the app-level `id` UUID and every
///   merge dedupes by it;
/// * every attribute is optional or has a default;
/// * every relationship is optional and has an explicit inverse (declared on
///   `Venue`);
/// * the `type`/`source` enums are stored as raw-value strings with defaults.
@Model
public final class DrinkEvent {

    /// App-level identity. Not a unique constraint — dedupe is done in code by
    /// `EventStore.upsert(_:in:)` so CloudKit stays happy (SPEC §1, §7).
    public var id: UUID = UUID()

    /// Raw storage for `type`. Use `type` in application code.
    public var typeRaw: String = DrinkType.alcoholic.rawValue

    public var timestamp: Date = Date.distantPast

    /// nil when location permission is denied or the drink was retro-logged.
    public var latitude: Double?
    public var longitude: Double?
    public var horizontalAccuracy: Double?

    /// Raw storage for `source`. Use `source` in application code.
    public var sourceRaw: String = EventSource.app.rawValue

    /// Optional relationship; the inverse lives on `Venue.events`.
    public var venue: Venue?

    public init(
        id: UUID = UUID(),
        type: DrinkType = .alcoholic,
        timestamp: Date = Date(),
        latitude: Double? = nil,
        longitude: Double? = nil,
        horizontalAccuracy: Double? = nil,
        source: EventSource = .app,
        venue: Venue? = nil
    ) {
        self.id = id
        self.typeRaw = type.rawValue
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.sourceRaw = source.rawValue
        self.venue = venue
    }

    // MARK: Enum accessors (computed — not persisted directly)

    public var type: DrinkType {
        get { DrinkType(rawValue: typeRaw) ?? .alcoholic }
        set { typeRaw = newValue.rawValue }
    }

    public var source: EventSource {
        get { EventSource(rawValue: sourceRaw) ?? .app }
        set { sourceRaw = newValue.rawValue }
    }

    public var hasCoordinates: Bool {
        latitude != nil && longitude != nil
    }

    /// Value-type projection used by every pure computation in TallyKit.
    public var snapshot: DrinkEventSnapshot {
        DrinkEventSnapshot(
            id: id,
            type: type,
            timestamp: timestamp,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: horizontalAccuracy,
            source: source,
            venueID: venue?.id
        )
    }
}
