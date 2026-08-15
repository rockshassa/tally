import Foundation
import SwiftData

/// Computes the Session list from the event log (SPEC §2).
///
/// The whole point is determinism: every device, given the same events, the same
/// materialized records, and the same Bar Radar exits, produces byte-identical
/// Sessions with identical IDs — regardless of insert order, sync arrival order,
/// or array shuffling. That is what lets Sessions be derived rather than stored,
/// which in turn is what makes the CloudKit surface trivial (SPEC §1, §8).
///
/// Rules implemented, verbatim from SPEC §2:
/// * a Session opens with the first drink after ≥ 3 h of inactivity;
/// * consecutive events belong to the same Session while each is within 3 h of
///   the previous **and** inside the same venue geofence (or has no venue);
/// * a Session closes 3 h after its last drink — its recorded end time is that
///   last drink's timestamp — or immediately when a Bar Radar exit event fires,
///   whichever comes first;
/// * identity is the first event's UUID;
/// * materialized records take precedence: events inside a materialized window
///   belong to it, and derivation runs over the remainder.
public struct SessionDeriver: Sendable {

    // MARK: - Configuration

    public struct Configuration: Hashable, Sendable {

        /// SPEC §2: 3 hours.
        public static let defaultInactivityWindow: TimeInterval = 3 * 60 * 60

        /// Gap that opens a new Session, and the delay after the last drink at
        /// which a Session closes.
        public var inactivityWindow: TimeInterval

        /// SPEC §2: moving to a different venue splits the Session. Events with
        /// no venue never split — they join whatever is open.
        public var splitsOnVenueChange: Bool

        public init(
            inactivityWindow: TimeInterval = Configuration.defaultInactivityWindow,
            splitsOnVenueChange: Bool = true
        ) {
            self.inactivityWindow = max(0, inactivityWindow)
            self.splitsOnVenueChange = splitsOnVenueChange
        }

        public static let `default` = Configuration()
    }

    // MARK: - Bar Radar exit hook

    /// A Bar Radar geofence exit (SPEC §2). Closes any open Session at that venue
    /// immediately, ahead of the natural 3 h timeout.
    ///
    /// Exits are an *input* to derivation, never stored state, so the result stays
    /// a pure function of the log plus this list.
    public struct VenueExit: Hashable, Sendable {

        public let venueID: UUID
        public let occurredAt: Date

        public init(venueID: UUID, occurredAt: Date) {
            self.venueID = venueID
            self.occurredAt = occurredAt
        }

        static func isOrderedBefore(_ lhs: VenueExit, _ rhs: VenueExit) -> Bool {
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
            return lhs.venueID.uuidString < rhs.venueID.uuidString
        }
    }

    // MARK: - Init

    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Derivation

    /// The one entry point. Pure, total, and order-independent.
    ///
    /// - Returns: Sessions ordered by `startedAt`, ties broken by ID. Materialized
    ///   records always appear, even if no event currently falls in their window —
    ///   that is the "no event edit can dangle a materialized reference" guarantee.
    public func derive(
        events rawEvents: [DrinkEventSnapshot],
        materialized rawMaterialized: [MaterializedSession] = [],
        venueExits rawExits: [VenueExit] = []
    ) -> [DerivedSession] {

        let events = Self.canonical(rawEvents)
        let windows = Self.canonical(rawMaterialized)
        let exits = Self.canonical(rawExits)

        // 1. Materialized windows claim their events first. Overlapping windows
        //    are resolved by canonical order, so the earliest-starting record wins
        //    a contested event — deterministically, on every device.
        var claimed: [UUID: [DrinkEventSnapshot]] = [:]
        var remainder: [DrinkEventSnapshot] = []
        remainder.reserveCapacity(events.count)

        for event in events {
            if let window = windows.first(where: { $0.contains(event.timestamp) }) {
                claimed[window.id, default: []].append(event)
            } else {
                remainder.append(event)
            }
        }

        var sessions: [DerivedSession] = windows.map { window in
            DerivedSession(
                id: window.id,
                startedAt: window.startedAt,
                endedAt: window.endedAt,
                closesAt: closeTime(lastEventAt: window.endedAt, venueID: window.venueID, exits: exits),
                venueID: window.venueID,
                events: claimed[window.id] ?? [],
                isMaterialized: true,
                note: window.note,
                pinned: window.pinned
            )
        }

        // 2. Derivation runs over whatever is left.
        sessions.append(contentsOf: deriveUnmaterialized(remainder, exits: exits))

        return sessions.sorted(by: DerivedSession.isOrderedBefore)
    }

    /// Convenience overload reading straight from a `ModelContext`.
    public func derive(
        in context: ModelContext,
        venueExits: [VenueExit] = []
    ) throws -> [DerivedSession] {
        derive(
            events: try EventStore.snapshots(in: context),
            materialized: try EventStore.materializedSessions(in: context),
            venueExits: venueExits
        )
    }

    // MARK: - Queries

    /// The Session currently accepting drinks, if any — the live Session card
    /// on the Tally screen (SPEC §1, §2).
    public func activeSession(
        events: [DrinkEventSnapshot],
        materialized: [MaterializedSession] = [],
        venueExits: [VenueExit] = [],
        asOf now: Date = Date()
    ) -> DerivedSession? {
        derive(events: events, materialized: materialized, venueExits: venueExits)
            .last { $0.startedAt <= now && $0.isActive(asOf: now) }
    }

    /// Which Session an event belongs to. Used by History and by venue
    /// auto-tagging of subsequent drinks (SPEC §2).
    public func session(
        containing eventID: UUID,
        events: [DrinkEventSnapshot],
        materialized: [MaterializedSession] = [],
        venueExits: [VenueExit] = []
    ) -> DerivedSession? {
        derive(events: events, materialized: materialized, venueExits: venueExits)
            .first { $0.events.contains { $0.id == eventID } }
    }

    // MARK: - Core walk

    private func deriveUnmaterialized(
        _ events: [DrinkEventSnapshot],
        exits: [VenueExit]
    ) -> [DerivedSession] {

        guard !events.isEmpty else { return [] }

        var sessions: [DerivedSession] = []
        var current: [DrinkEventSnapshot] = []
        var currentVenueID: UUID?

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            sessions.append(
                DerivedSession(
                    id: first.id,
                    startedAt: first.timestamp,
                    endedAt: last.timestamp,
                    closesAt: closeTime(lastEventAt: last.timestamp, venueID: currentVenueID, exits: exits),
                    venueID: currentVenueID,
                    events: current,
                    isMaterialized: false
                )
            )
            current.removeAll(keepingCapacity: true)
            currentVenueID = nil
        }

        for event in events {
            if let previous = current.last {
                if continues(from: previous, to: event, sessionVenueID: currentVenueID, exits: exits) {
                    current.append(event)
                    // SPEC §2: a check-in on the second drink adopts the venue for
                    // the outing; untagged events never override a known venue.
                    if currentVenueID == nil { currentVenueID = event.venueID }
                    continue
                }
                flush()
            }
            current.append(event)
            currentVenueID = event.venueID
        }
        flush()

        return sessions
    }

    private func continues(
        from previous: DrinkEventSnapshot,
        to next: DrinkEventSnapshot,
        sessionVenueID: UUID?,
        exits: [VenueExit]
    ) -> Bool {

        // "within 3 h of the previous"
        let gap = next.timestamp.timeIntervalSince(previous.timestamp)
        guard gap < configuration.inactivityWindow else { return false }

        // "and inside the same venue geofence (or has no venue)"
        if configuration.splitsOnVenueChange,
           let sessionVenueID,
           let nextVenueID = next.venueID,
           nextVenueID != sessionVenueID {
            return false
        }

        // "or immediately when a Bar Radar exit event fires, whichever comes first"
        if let sessionVenueID, hasExit(for: sessionVenueID, in: previous.timestamp...next.timestamp, exits: exits) {
            return false
        }

        return true
    }

    private func hasExit(
        for venueID: UUID,
        in range: ClosedRange<Date>,
        exits: [VenueExit]
    ) -> Bool {
        exits.contains { $0.venueID == venueID && range.contains($0.occurredAt) }
    }

    /// SPEC §2: closes 3 h after the last drink, or at the Bar Radar exit,
    /// whichever comes first.
    private func closeTime(lastEventAt: Date, venueID: UUID?, exits: [VenueExit]) -> Date {
        let natural = lastEventAt.addingTimeInterval(configuration.inactivityWindow)
        guard let venueID else { return natural }
        let exit = exits.first {
            $0.venueID == venueID && $0.occurredAt >= lastEventAt && $0.occurredAt < natural
        }
        return exit?.occurredAt ?? natural
    }

    // MARK: - Canonicalization

    /// Sorts into the one canonical order and drops duplicate UUIDs.
    ///
    /// This is where insert-order independence and UUID-dedupe idempotence come
    /// from: everything downstream sees the same array no matter what came in.
    static func canonical(_ events: [DrinkEventSnapshot]) -> [DrinkEventSnapshot] {
        var seen = Set<UUID>()
        return events
            .sorted(by: DrinkEventSnapshot.isOrderedBefore)
            .filter { seen.insert($0.id).inserted }
    }

    static func canonical(_ sessions: [MaterializedSession]) -> [MaterializedSession] {
        var seen = Set<UUID>()
        return sessions
            .sorted(by: MaterializedSession.isOrderedBefore)
            .filter { seen.insert($0.id).inserted }
    }

    static func canonical(_ exits: [VenueExit]) -> [VenueExit] {
        var seen = Set<VenueExit>()
        return exits
            .sorted(by: VenueExit.isOrderedBefore)
            .filter { seen.insert($0).inserted }
    }
}
