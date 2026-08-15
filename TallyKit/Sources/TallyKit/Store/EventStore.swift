import Foundation
import SwiftData

/// The single sanctioned write/read path for the event log.
///
/// Every surface — app, widget, watch, notification action, WatchConnectivity
/// merge, CloudKit merge — goes through here, so UUID dedupe (SPEC §1, §7) is
/// idempotent by construction: delivering the same event twice is a no-op.
public enum EventStore {

    // MARK: - Reads

    public static func allEvents(in context: ModelContext) throws -> [DrinkEvent] {
        var descriptor = FetchDescriptor<DrinkEvent>()
        descriptor.sortBy = [SortDescriptor(\DrinkEvent.timestamp, order: .forward)]
        return try context.fetch(descriptor)
    }

    /// Events in a half-open interval, ordered.
    public static func events(
        from start: Date,
        to end: Date,
        in context: ModelContext
    ) throws -> [DrinkEvent] {
        var descriptor = FetchDescriptor<DrinkEvent>(
            predicate: #Predicate<DrinkEvent> { $0.timestamp >= start && $0.timestamp < end }
        )
        descriptor.sortBy = [SortDescriptor(\DrinkEvent.timestamp, order: .forward)]
        return try context.fetch(descriptor)
    }

    public static func events(
        onDayContaining date: Date,
        calendar: Calendar = .current,
        in context: ModelContext
    ) throws -> [DrinkEvent] {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return try events(from: start, to: end, in: context)
    }

    public static func event(id: UUID, in context: ModelContext) throws -> DrinkEvent? {
        var descriptor = FetchDescriptor<DrinkEvent>(predicate: #Predicate<DrinkEvent> { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    public static func snapshots(in context: ModelContext) throws -> [DrinkEventSnapshot] {
        try allEvents(in: context).map(\.snapshot)
    }

    public static func materializedSessions(in context: ModelContext) throws -> [MaterializedSession] {
        try context.fetch(FetchDescriptor<Session>()).map(\.snapshot)
    }

    public static func venues(in context: ModelContext) throws -> [VenueSnapshot] {
        try context.fetch(FetchDescriptor<Venue>()).map(\.snapshot)
    }

    public static func venue(id: UUID, in context: ModelContext) throws -> Venue? {
        var descriptor = FetchDescriptor<Venue>(predicate: #Predicate<Venue> { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    public static func session(id: UUID, in context: ModelContext) throws -> Session? {
        var descriptor = FetchDescriptor<Session>(predicate: #Predicate<Session> { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - Writes

    /// Logs a drink. The one-tap path used by the app, the widget intent, and the
    /// watch (SPEC §1). Location is optional and never blocks the tap (SPEC §2, §6).
    @discardableResult
    public static func logDrink(
        type: DrinkType,
        timestamp: Date = Date(),
        source: EventSource = .app,
        latitude: Double? = nil,
        longitude: Double? = nil,
        horizontalAccuracy: Double? = nil,
        venue: Venue? = nil,
        id: UUID = UUID(),
        in context: ModelContext
    ) throws -> DrinkEvent {
        let event = DrinkEvent(
            id: id,
            type: type,
            timestamp: timestamp,
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: horizontalAccuracy,
            source: source,
            venue: venue
        )
        context.insert(event)
        try context.save()
        return event
    }

    /// Undo semantics from SPEC §1: removes the *most recent* event of `type` on
    /// the given day, deleting it outright (location and venue included).
    /// Returns `false` — a no-op — when there is nothing to remove.
    @discardableResult
    public static func undoMostRecent(
        type: DrinkType,
        onDayContaining date: Date = Date(),
        calendar: Calendar = .current,
        in context: ModelContext
    ) throws -> Bool {
        let raw = type.rawValue
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        var descriptor = FetchDescriptor<DrinkEvent>(
            predicate: #Predicate<DrinkEvent> {
                $0.typeRaw == raw && $0.timestamp >= start && $0.timestamp < end
            }
        )
        descriptor.sortBy = [SortDescriptor(\DrinkEvent.timestamp, order: .reverse)]
        descriptor.fetchLimit = 1
        guard let victim = try context.fetch(descriptor).first else { return false }
        context.delete(victim)
        try context.save()
        return true
    }

    // MARK: - Merge / dedupe

    public enum UpsertOutcome: Hashable, Sendable {
        case inserted
        case updated
        case unchanged
    }

    /// Idempotent merge by app-level UUID (SPEC §1, §7).
    ///
    /// Both WatchConnectivity and CloudKit can deliver the same event, so double
    /// delivery must be harmless. Last-writer-wins is safe here because events
    /// are append-only plus explicit deletes (SPEC §8).
    @discardableResult
    public static func upsert(
        _ snapshot: DrinkEventSnapshot,
        in context: ModelContext
    ) throws -> UpsertOutcome {
        let resolvedVenue = try snapshot.venueID.flatMap { try EventStore.venue(id: $0, in: context) }

        guard let existing = try EventStore.event(id: snapshot.id, in: context) else {
            let created = DrinkEvent(
                id: snapshot.id,
                type: snapshot.type,
                timestamp: snapshot.timestamp,
                latitude: snapshot.latitude,
                longitude: snapshot.longitude,
                horizontalAccuracy: snapshot.horizontalAccuracy,
                source: snapshot.source,
                venue: resolvedVenue
            )
            context.insert(created)
            try context.save()
            return .inserted
        }

        if existing.snapshot == snapshot { return .unchanged }

        existing.type = snapshot.type
        existing.timestamp = snapshot.timestamp
        existing.latitude = snapshot.latitude
        existing.longitude = snapshot.longitude
        existing.horizontalAccuracy = snapshot.horizontalAccuracy
        existing.source = snapshot.source
        existing.venue = resolvedVenue
        try context.save()
        return .updated
    }

    /// Bulk idempotent merge. Order-independent.
    @discardableResult
    public static func upsert(
        _ snapshots: [DrinkEventSnapshot],
        in context: ModelContext
    ) throws -> [UUID: UpsertOutcome] {
        var outcomes: [UUID: UpsertOutcome] = [:]
        for snapshot in snapshots.sorted(by: DrinkEventSnapshot.isOrderedBefore) {
            outcomes[snapshot.id] = try upsert(snapshot, in: context)
        }
        return outcomes
    }

    // MARK: - Materialization

    /// Persists a derived Session so it can carry a note or a pin (SPEC §2).
    /// Idempotent: touching an already-materialized Session returns the record.
    @discardableResult
    public static func materialize(
        _ derived: DerivedSession,
        in context: ModelContext
    ) throws -> Session {
        if let existing = try EventStore.session(id: derived.id, in: context) { return existing }
        let resolvedVenue = try derived.venueID.flatMap { try EventStore.venue(id: $0, in: context) }
        let record = Session(materializing: derived, venue: resolvedVenue)
        context.insert(record)
        try context.save()
        return record
    }

    // MARK: - Erase

    /// Destructive wipe backing Settings → Erase all data (SPEC §9).
    public static func eraseAll(in context: ModelContext) throws {
        try context.delete(model: DrinkEvent.self)
        try context.delete(model: Session.self)
        try context.delete(model: SuppressedPlace.self)
        try context.delete(model: Venue.self)
        try context.save()
    }
}
