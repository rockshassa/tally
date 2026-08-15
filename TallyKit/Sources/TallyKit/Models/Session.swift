import Foundation
import SwiftData

/// A **materialized** Session record (SPEC §1, §2).
///
/// Most Sessions are never persisted: `SessionDeriver` computes them from the
/// event log and keys them by their first event's UUID, so every device derives
/// an identical list and there is zero sync surface. The first time a Session is
/// *touched* — annotated, pinned, or shared — the app persists one of these
/// records capturing the derived ID, the boundaries, and the venue. From then on
/// the record owns the identity: events falling inside its window belong to it
/// and derivation runs over the remainder.
///
/// Counts are never stored here (SPEC §1: derive, don't store, aggregates).
@Model
public final class Session {

    /// The deterministic derived ID (first event's UUID), captured at
    /// materialization. Two devices materializing the same Session produce the
    /// same ID, so sync dedupes by UUID like everything else.
    public var id: UUID = UUID()

    public var startedAt: Date = Date.distantPast
    public var endedAt: Date = Date.distantPast

    /// User annotation, e.g. "Dave's birthday".
    public var note: String?

    public var pinned: Bool = false

    /// Optional relationship; the inverse lives on `Venue.sessions`.
    public var venue: Venue?

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        endedAt: Date = Date(),
        note: String? = nil,
        pinned: Bool = false,
        venue: Venue? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.note = note
        self.pinned = pinned
        self.venue = venue
    }

    /// Materializes a derived Session so it can carry a note or a pin.
    public convenience init(materializing derived: DerivedSession, venue: Venue? = nil) {
        self.init(
            id: derived.id,
            startedAt: derived.startedAt,
            endedAt: derived.endedAt,
            note: derived.note,
            pinned: derived.pinned,
            venue: venue
        )
    }

    public var snapshot: MaterializedSession {
        MaterializedSession(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            venueID: venue?.id,
            note: note,
            pinned: pinned
        )
    }
}
