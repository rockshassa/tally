import Foundation
import Observation
import SwiftData
import TallyKit

/// SPEC §6: "the app **reconciles on next open** — offering venue tagging for
/// recent untagged widget events." SPEC §7 sends watch events down the same
/// path: "watch events land untagged and go through the same reconciliation
/// flow as widget events on next phone-app open."
///
/// Finds them, groups them by Session (you tag an outing, not six taps), and
/// remembers what you already waved off so the prompt never nags.
@MainActor
@Observable
public final class ReconciliationService {

    // MARK: Item

    /// One outing's worth of untagged off-app drinks.
    public struct Item: Identifiable, Hashable, Sendable {

        public let sessionID: UUID
        public let startedAt: Date
        public let endedAt: Date

        /// The untagged widget/watch events. Tagging applies to the *whole*
        /// Session, but these are what flagged it.
        public let events: [DrinkEventSnapshot]

        /// All events in the Session, which is what actually gets tagged.
        public let sessionEventIDs: [UUID]

        /// Coordinates from a sibling event, when the Session has any — a watch
        /// log next to a phone log usually does (SPEC §7).
        public let anchorFix: LocationFix?

        public var id: UUID { sessionID }

        public var eventIDs: [UUID] { events.map(\.id) }

        /// "3 drinks from your Watch", "2 drinks from the widget".
        public var sourceSummary: String {
            let sources = Set(events.map(\.source))
            let noun = events.count == 1 ? "drink" : "drinks"
            if sources == [.watch] { return "\(events.count) \(noun) from your Watch" }
            if sources == [.widget] { return "\(events.count) \(noun) from the widget" }
            return "\(events.count) \(noun) logged outside the app"
        }

        public var whenSummary: String {
            "\(SessionFormatting.longDate(startedAt)) · \(SessionFormatting.timeRange(from: startedAt, to: endedAt))"
        }
    }

    // MARK: State

    public private(set) var items: [Item] = []

    public var hasPendingWork: Bool { !items.isEmpty }

    // MARK: Dependencies

    private let modelContext: ModelContext
    private let deriver: SessionDeriver
    private let lookback: TimeInterval
    private let defaults: UserDefaults

    private static let handledKey = "tally.place.reconciliationHandled"
    private static let maxHandled = 400

    /// SPEC §6 says "recent" — two days covers a night out plus the morning
    /// after, and keeps the prompt from resurfacing ancient history.
    nonisolated public static let defaultLookback: TimeInterval = 48 * 60 * 60

    public init(
        modelContext: ModelContext,
        deriver: SessionDeriver = SessionDeriver(),
        lookback: TimeInterval = ReconciliationService.defaultLookback,
        defaults: UserDefaults = .standard
    ) {
        self.modelContext = modelContext
        self.deriver = deriver
        self.lookback = lookback
        self.defaults = defaults
    }

    // MARK: Scan

    /// Cheap enough to call on every foreground.
    public func refresh(asOf now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-lookback)
        let handled = handledEventIDs()

        guard let sessions = try? deriver.derive(in: modelContext) else {
            items = []
            return
        }

        items = sessions.compactMap { session -> Item? in
            // Already named — nothing to reconcile.
            guard session.venueID == nil else { return nil }

            let flagged = session.events.filter {
                $0.needsVenueReconciliation && $0.timestamp >= cutoff && !handled.contains($0.id)
            }
            guard !flagged.isEmpty else { return nil }

            return Item(
                sessionID: session.id,
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                events: flagged,
                sessionEventIDs: session.eventIDs,
                anchorFix: VenueAssignmentView.anchor(for: session.events)
            )
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    /// One-shot check for a host that wants to know whether presenting is worth
    /// it before building anything.
    public static func hasPendingWork(
        in context: ModelContext,
        lookback: TimeInterval = ReconciliationService.defaultLookback,
        asOf now: Date = Date()
    ) -> Bool {
        let service = ReconciliationService(modelContext: context, lookback: lookback)
        service.refresh(asOf: now)
        return service.hasPendingWork
    }

    // MARK: Resolution

    /// Tags the whole Session, matching what a check-in would have done had the
    /// fix arrived in time (SPEC §2).
    public func assign(_ candidate: VenueCandidate, to item: Item) {
        guard let venue = try? VenueWriter.resolveVenue(for: candidate, in: modelContext) else { return }
        try? VenueWriter.tag(eventIDs: item.sessionEventIDs, with: venue, in: modelContext)
        markHandled(item.eventIDs)
        refresh()
    }

    /// "Leave it untagged." Remembered, so next launch doesn't ask again — the
    /// Session is still assignable by hand from History whenever you like.
    public func skip(_ item: Item) {
        markHandled(item.eventIDs)
        refresh()
    }

    public func skipAll() {
        markHandled(items.flatMap(\.eventIDs))
        refresh()
    }

    public func savedVenues() -> [VenueSnapshot] {
        ((try? EventStore.venues(in: modelContext)) ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Handled bookkeeping

    private func handledEventIDs() -> Set<UUID> {
        let raw = defaults.stringArray(forKey: Self.handledKey) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private func markHandled(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var raw = defaults.stringArray(forKey: Self.handledKey) ?? []
        raw.append(contentsOf: ids.map(\.uuidString))
        if raw.count > Self.maxHandled {
            raw = Array(raw.suffix(Self.maxHandled))
        }
        defaults.set(raw, forKey: Self.handledKey)
    }
}
