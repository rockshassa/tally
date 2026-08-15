import CoreLocation
import Foundation
import SwiftData
import TallyKit

/// The post-sync merge passes SPEC §1 and §8 call for.
///
/// CloudKit gives us last-writer-wins on fields and dedupe-by-record on rows,
/// and neither is enough for the two cases the schema deliberately left to the
/// app:
///
/// 1. **Venues have no unique constraint** (CloudKit doesn't support them), so
///    two devices that visit the same bar before syncing each create their own
///    `Venue`. SPEC §1: match by `mapItemID`, else by name + proximity, then
///    "collapse them and repoint events and materialized Sessions".
/// 2. **Materialized `Session`s are keyed by an app-level UUID**, not by their
///    CloudKit record name. Two devices materializing the same Session derive
///    the same `id` but mint two records, and both arrive.
///
/// Every operation here is idempotent and order-independent: running it twice,
/// or on a store that is already clean, changes nothing and reports nothing.
///
/// **Where it runs:** the phone only. Dedupe once and the deletions sync
/// everywhere, so the watch never has to do this — and two devices racing to
/// collapse the same pair would just create work for each other.
public enum SyncMergeService {

    /// SPEC §1 venue dedupe radius for the name-match path. Deliberately tighter
    /// than `VenueWriter.dedupeProximityMeters` (60 m), which is a *live*
    /// judgement made against a fresh fix with known accuracy; this one runs
    /// blind over two devices' stored coordinates, so it stays conservative —
    /// a false merge destroys a venue, a missed merge leaves a duplicate the
    /// user can ignore.
    public static let proximityMeters: CLLocationDistance = 50

    // MARK: - Report

    public struct Report: Equatable, Sendable {

        public var duplicateVenuesRemoved: Int = 0
        public var eventsRepointed: Int = 0
        public var sessionsRepointed: Int = 0
        public var duplicateSessionsRemoved: Int = 0

        public init() {}

        public var isEmpty: Bool {
            duplicateVenuesRemoved == 0
                && eventsRepointed == 0
                && sessionsRepointed == 0
                && duplicateSessionsRemoved == 0
        }

        mutating func absorb(_ other: Report) {
            duplicateVenuesRemoved += other.duplicateVenuesRemoved
            eventsRepointed += other.eventsRepointed
            sessionsRepointed += other.sessionsRepointed
            duplicateSessionsRemoved += other.duplicateSessionsRemoved
        }
    }

    // MARK: - Entry point

    /// Runs both passes. Venues first: collapsing them repoints Session records,
    /// and the Session pass then merges what is left by `id`.
    @discardableResult
    public static func run(in context: ModelContext) throws -> Report {
        var report = try mergeVenues(in: context)
        report.absorb(try mergeSessions(in: context))
        return report
    }

    // MARK: - Venues (SPEC §1)

    @discardableResult
    public static func mergeVenues(in context: ModelContext) throws -> Report {
        var report = Report()

        // Oldest first, so the survivor is the record that existed before the
        // duplicate arrived, and the outcome does not depend on fetch order.
        let venues = try context.fetch(FetchDescriptor<Venue>()).sorted(by: isOlder)
        guard venues.count > 1 else { return report }

        var survivors: [Venue] = []

        for venue in venues {
            // Compared against survivors as they stand, so a survivor that just
            // inherited a `mapItemID` from a loser can match on the strong key
            // for the rest of the pass.
            if let survivor = survivors.first(where: { isDuplicate($0, venue) }) {
                report.absorb(absorb(venue, into: survivor, in: context))
            } else {
                survivors.append(venue)
            }
        }

        if !report.isEmpty { try context.save() }
        return report
    }

    /// SPEC §1: "matched by `mapItemID`, or by name + proximity for user-defined
    /// venues."
    ///
    /// Two *different* MapKit ids are two different venues even in the same
    /// building — a bar and the restaurant above it share an address — so the
    /// strong key is decisive in both directions when both sides have one.
    static func isDuplicate(_ lhs: Venue, _ rhs: Venue) -> Bool {
        if let left = lhs.mapItemID, let right = rhs.mapItemID {
            return left == right
        }

        let name = normalized(lhs.name)
        guard !name.isEmpty, name == normalized(rhs.name) else { return false }

        return distance(lhs, rhs) <= proximityMeters
    }

    /// Folds `loser` into `survivor` and deletes it.
    ///
    /// Field merges all lean the same way: never lose information a user put
    /// there by hand, and never shrink a geofence.
    private static func absorb(_ loser: Venue, into survivor: Venue, in context: ModelContext) -> Report {
        var report = Report()

        // A hand-created venue that turns out to be a known POI earns the strong
        // key, exactly as `VenueWriter.resolveVenue` does on the live path.
        if survivor.mapItemID == nil, let mapItemID = loser.mapItemID {
            survivor.mapItemID = mapItemID
        }

        if normalized(survivor.name).isEmpty, !normalized(loser.name).isEmpty {
            survivor.name = loser.name
        }

        // Home is set deliberately in onboarding (SPEC §2); an inferred category
        // must never overwrite it, and `.other` is what we fall back to when a
        // raw value is unknown, so anything else is better information.
        if loser.category == .home {
            survivor.category = .home
        } else if survivor.category == .other, loser.category != .other {
            survivor.category = loser.category
        }

        survivor.radiusMeters = max(survivor.radiusMeters, loser.radiusMeters)

        // Muting is an opt-out (SPEC §2). Dropping it would start Bar Radar
        // prompting again at a venue the user silenced.
        if loser.muted { survivor.muted = true }

        survivor.createdAt = min(survivor.createdAt, loser.createdAt)

        // Repoint before deleting: the relationships are `.nullify`, so a delete
        // first would untag the events instead of moving them.
        let events = loser.events ?? []
        for event in events { event.venue = survivor }
        report.eventsRepointed = events.count

        let sessions = loser.sessions ?? []
        for session in sessions { session.venue = survivor }
        report.sessionsRepointed = sessions.count

        context.delete(loser)
        report.duplicateVenuesRemoved = 1

        return report
    }

    // MARK: - Materialized Sessions (SPEC §2, §8)

    /// Collapses `Session` records that share an app-level `id`.
    ///
    /// Only annotations are merged — never counts, which stay derived (SPEC §1).
    @discardableResult
    public static func mergeSessions(in context: ModelContext) throws -> Report {
        var report = Report()

        let sessions = try context.fetch(FetchDescriptor<Session>())
        guard sessions.count > 1 else { return report }

        for (_, duplicates) in Dictionary(grouping: sessions, by: \.id) where duplicates.count > 1 {
            let ordered = duplicates.sorted(by: isOlder)
            guard let survivor = ordered.first else { continue }

            for loser in ordered.dropFirst() {
                // Note and pin favour information over absence: an annotation
                // typed on one device and a bare record synced from another must
                // resolve to the annotation.
                if trimmedNote(survivor) == nil, let note = trimmedNote(loser) {
                    survivor.note = note
                }
                if loser.pinned { survivor.pinned = true }
                if survivor.venue == nil { survivor.venue = loser.venue }

                // The union of the two windows, so no event that belonged to
                // either record falls back out into free derivation (SPEC §2
                // materialization precedence).
                survivor.startedAt = min(survivor.startedAt, loser.startedAt)
                survivor.endedAt = max(survivor.endedAt, loser.endedAt)

                context.delete(loser)
                report.duplicateSessionsRemoved += 1
            }
        }

        if !report.isEmpty { try context.save() }
        return report
    }

    // MARK: - Ordering

    /// Venue survivor order: the record that existed first wins, with the UUID
    /// string as a total-order tiebreak so the result never depends on fetch
    /// order (the same rule `DrinkEventSnapshot.isOrderedBefore` uses).
    static func isOlder(_ lhs: Venue, _ rhs: Venue) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Session survivor order — "keep the earlier-created".
    ///
    /// `Session` carries no `createdAt`, and adding one would be a schema change
    /// this wave is not allowed to make, so the boundaries stand in for it: two
    /// records with the same `id` derive from the same first event, and the one
    /// materialized earlier has the earlier (shorter) recorded window, since a
    /// Session's end time only moves forward as drinks are added.
    ///
    /// The last resort must be computed from *replicated* content, never from
    /// `persistentModelID`: that id is per-store, so two synced devices would
    /// order the same pair differently, pick different survivors, and each
    /// delete the record the other kept — propagating both deletes. Content
    /// both devices see identically orders identically everywhere.
    static func isOlder(_ lhs: Session, _ rhs: Session) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        if lhs.endedAt != rhs.endedAt { return lhs.endedAt < rhs.endedAt }
        return contentKey(lhs) < contentKey(rhs)
    }

    /// A total order over a Session's replicated fields.
    private static func contentKey(_ session: Session) -> String {
        [
            session.note ?? "",
            session.pinned ? "1" : "0",
            session.venue?.id.uuidString ?? "",
        ].joined(separator: "|")
    }

    // MARK: - Comparison helpers

    /// Case- and diacritic-insensitive, whitespace-trimmed: "the anchor" and
    /// "The Anchor " are the same bar typed twice.
    static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func distance(_ lhs: Venue, _ rhs: Venue) -> CLLocationDistance {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
            .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
    }

    private static func trimmedNote(_ session: Session) -> String? {
        guard let note = session.note?.trimmingCharacters(in: .whitespacesAndNewlines),
              !note.isEmpty else { return nil }
        return note
    }
}
