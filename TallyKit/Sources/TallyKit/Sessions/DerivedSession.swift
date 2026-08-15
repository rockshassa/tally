import Foundation

/// One outing (SPEC §2). The product's name for a Session, everywhere in the UI.
///
/// A `DerivedSession` is a computed value, never a stored row — except for the
/// identity/annotation half of materialized ones, which comes from a `Session`
/// record. Counts are always derived from the contained events (SPEC §1).
public struct DerivedSession: Identifiable, Hashable, Sendable {

    /// The first event's UUID for unmaterialized Sessions; the record's captured
    /// ID once materialized. Deterministic across devices either way.
    public let id: UUID

    /// First event's timestamp, or the materialized record's recorded start.
    public let startedAt: Date

    /// SPEC §2: "its recorded end time is that last drink's timestamp."
    public let endedAt: Date

    /// When the Session stops accepting new events: `endedAt` + the inactivity
    /// window, or earlier if a Bar Radar exit fired first (SPEC §2).
    public let closesAt: Date

    public let venueID: UUID?

    /// The Session's events, in canonical order.
    public let events: [DrinkEventSnapshot]

    /// True when a `Session` record owns this identity (SPEC §2).
    public let isMaterialized: Bool

    public let note: String?
    public let pinned: Bool

    public init(
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        closesAt: Date,
        venueID: UUID?,
        events: [DrinkEventSnapshot],
        isMaterialized: Bool,
        note: String? = nil,
        pinned: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.closesAt = closesAt
        self.venueID = venueID
        self.events = events
        self.isMaterialized = isMaterialized
        self.note = note
        self.pinned = pinned
    }

    // MARK: Derived counts (SPEC §1: never persisted)

    public var eventIDs: [UUID] { events.map(\.id) }

    public var alcoholicCount: Int {
        events.reduce(into: 0) { $0 += ($1.type == .alcoholic ? 1 : 0) }
    }

    public var nonAlcoholicCount: Int {
        events.reduce(into: 0) { $0 += ($1.type == .nonAlcoholic ? 1 : 0) }
    }

    public var drinkCount: Int { events.count }

    /// NA drinks logged between two alcoholic drinks in this Session (SPEC §3).
    public var spacerCount: Int { Spacers.count(in: events) }

    public var spacerEventIDs: [UUID] {
        Spacers.indices(in: events).map { events[$0].id }
    }

    /// SPEC §2: duration of the outing.
    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    /// NA : alcoholic. `nil` when there are no alcoholic drinks — an all-NA
    /// outing has no meaningful ratio, it just wins.
    public var nonAlcoholicRatio: Double? {
        guard alcoholicCount > 0 else { return nil }
        return Double(nonAlcoholicCount) / Double(alcoholicCount)
    }

    /// Still accepting drinks — drives the live Session card (SPEC §1, §2).
    public func isActive(asOf now: Date) -> Bool { now < closesAt }

    public func isClosed(asOf now: Date) -> Bool { !isActive(asOf: now) }

    /// The window an event must fall in to belong to this Session once it has
    /// been materialized.
    public func contains(_ date: Date) -> Bool {
        date >= startedAt && date <= endedAt
    }

    public static func isOrderedBefore(_ lhs: DerivedSession, _ rhs: DerivedSession) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

// MARK: - Spacers

/// Spacer detection, shared by `DerivedSession` and `ScoringEngine` so there is
/// exactly one definition (SPEC §3).
///
/// A spacer is an NA drink with at least one alcoholic drink before it *and* at
/// least one after it, within the same Session. Each qualifying NA drink counts;
/// two NA drinks back to back between the same pair of alcoholic drinks are two
/// spacers.
enum Spacers {

    static func indices(in events: [DrinkEventSnapshot]) -> [Int] {
        guard
            let firstAlcohol = events.firstIndex(where: { $0.type == .alcoholic }),
            let lastAlcohol = events.lastIndex(where: { $0.type == .alcoholic }),
            firstAlcohol < lastAlcohol
        else { return [] }

        return events.indices.filter { index in
            index > firstAlcohol && index < lastAlcohol && events[index].type == .nonAlcoholic
        }
    }

    static func count(in events: [DrinkEventSnapshot]) -> Int {
        indices(in: events).count
    }

    /// `Badge.pacer` predicate (SPEC §3: "alternated all night") — every
    /// consecutive pair of alcoholic drinks is separated by at least one NA drink.
    static func alternatedThroughout(
        _ events: [DrinkEventSnapshot],
        minimumAlcoholicDrinks: Int
    ) -> Bool {
        let alcoholIndices = events.indices.filter { events[$0].type == .alcoholic }
        guard alcoholIndices.count >= minimumAlcoholicDrinks else { return false }

        for (lower, upper) in zip(alcoholIndices, alcoholIndices.dropFirst()) {
            let hasSpacerBetween = events[(lower + 1)..<upper].contains { $0.type == .nonAlcoholic }
            if !hasSpacerBetween { return false }
        }
        return true
    }
}
