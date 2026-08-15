import Foundation
import SwiftData
import TallyKit

/// Which venues have earned a geofence (SPEC §2 Tier 1).
///
/// > **Frequented** = a venue with ≥ 3 Sessions in the trailing 90 days, derived
/// > from the event log (never stored, per §1). Home and muted venues are
/// > excluded. […] the top frequented venues by recency, staying under the
/// > system's ~20-region cap.
///
/// Pure and total: hand it Sessions and venue snapshots and it hands back the
/// exact set of regions CoreLocation should be monitoring. Nothing here touches
/// CoreLocation, and nothing about the region budget leaks into the rest of the
/// feature.
nonisolated public struct FrequentedVenues: Sendable {

    // MARK: - Configuration

    nonisolated public struct Configuration: Hashable, Sendable {

        /// SPEC §2: "the trailing 90 days".
        public var lookback: TimeInterval

        /// SPEC §2: "≥ 3 Sessions".
        public var minimumSessions: Int

        /// SPEC §2: "staying under the system's ~20-region cap".
        ///
        /// 18 rather than 20: the cap is per-app and shared with anything else
        /// the process registers, so spending the last two would make a future
        /// region silently fail to register instead of failing here, where it
        /// can be reasoned about.
        public var regionBudget: Int

        public init(
            lookback: TimeInterval = 90 * 24 * 60 * 60,
            minimumSessions: Int = 3,
            regionBudget: Int = 18
        ) {
            self.lookback = max(0, lookback)
            self.minimumSessions = max(1, minimumSessions)
            self.regionBudget = max(0, regionBudget)
        }

        public static let `default` = Configuration()
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Derivation

    /// The geofence set, most recently visited first.
    ///
    /// - Parameters:
    ///   - sessions: every Session in the log. Filtering to the window happens
    ///     here so callers cannot disagree about where the window starts.
    ///   - venues: the saved venues. Anything a Session points at that no longer
    ///     exists is dropped rather than monitored blind.
    public func targets(
        sessions: [DerivedSession],
        venues: [VenueSnapshot],
        asOf now: Date = Date()
    ) -> [RadarTarget] {

        let cutoff = now.addingTimeInterval(-configuration.lookback)
        let byID = venues.byID

        var counts: [UUID: Int] = [:]
        var mostRecent: [UUID: Date] = [:]

        for session in sessions {
            guard let venueID = session.venueID else { continue }
            // The window is on the Session's start: an outing that began inside
            // the 90 days counts, whichever side of the boundary it ended on.
            guard session.startedAt >= cutoff, session.startedAt <= now else { continue }

            guard let venue = byID[venueID] else { continue }
            // SPEC §2: "Home and muted venues are excluded" — and SPEC §1's mute
            // flag is exactly this opt-out.
            guard !venue.category.isHome, !venue.muted else { continue }

            counts[venueID, default: 0] += 1
            if let existing = mostRecent[venueID] {
                mostRecent[venueID] = max(existing, session.startedAt)
            } else {
                mostRecent[venueID] = session.startedAt
            }
        }

        return counts
            .compactMap { venueID, count -> RadarTarget? in
                guard count >= configuration.minimumSessions else { return nil }
                guard let venue = byID[venueID], let last = mostRecent[venueID] else { return nil }
                return RadarTarget(venue: venue, sessionCount: count, lastSessionAt: last)
            }
            .sorted(by: RadarTarget.isOrderedBefore)
            .prefix(configuration.regionBudget)
            .map { $0 }
    }

    /// Convenience overload reading straight from the store.
    ///
    /// Bar Radar exits are fed back into derivation (SPEC §2: a Session "closes
    /// … immediately when a Bar Radar exit event fires"), so the Session list the
    /// geofence set is computed from is the same one History shows.
    public func targets(
        in context: ModelContext,
        deriver: SessionDeriver = SessionDeriver(),
        venueExits: [SessionDeriver.VenueExit] = [],
        asOf now: Date = Date()
    ) -> [RadarTarget] {
        guard
            let sessions = try? deriver.derive(in: context, venueExits: venueExits),
            let venues = try? EventStore.venues(in: context)
        else { return [] }
        return targets(sessions: sessions, venues: venues, asOf: now)
    }
}
