import CoreLocation
import Foundation
import TallyKit

/// The pure half of SPEC §2's inference pipeline: geofence matching and the
/// confidence rule. No I/O, no store, no MapKit — so every decision the app
/// makes about where you are can be reasoned about (and tested) in isolation.
nonisolated public struct VenueInference: Sendable {

    // MARK: - Configuration

    nonisolated public struct Configuration: Hashable, Sendable {

        /// SPEC §2 step 2: POIs "within ~75 m".
        public var poiRadiusMeters: CLLocationDistance

        /// SPEC §2 step 3: confident when "distance < accuracy + 50 m".
        public var confidenceSlackMeters: CLLocationDistance

        /// How many alternates "Somewhere else nearby…" offers.
        public var maxAlternates: Int

        /// SPEC §6's ~5 s budget, shared by every logging surface.
        public var fixTimeout: TimeInterval

        public init(
            poiRadiusMeters: CLLocationDistance = 75,
            confidenceSlackMeters: CLLocationDistance = 50,
            maxAlternates: Int = 5,
            fixTimeout: TimeInterval = 5
        ) {
            self.poiRadiusMeters = poiRadiusMeters
            self.confidenceSlackMeters = confidenceSlackMeters
            self.maxAlternates = maxAlternates
            self.fixTimeout = fixTimeout
        }

        public static let `default` = Configuration()

        /// The radius actually searched: never smaller than the spec's 75 m, but
        /// widened when the fix itself is fuzzy, so a 120 m-accurate fix can still
        /// find the bar it's standing in.
        public func searchRadius(for fix: LocationFix) -> CLLocationDistance {
            max(poiRadiusMeters, fix.horizontalAccuracy + confidenceSlackMeters)
        }

        /// SPEC §2 step 3's threshold.
        public func confidenceThreshold(for fix: LocationFix) -> CLLocationDistance {
            fix.horizontalAccuracy + confidenceSlackMeters
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Step 1: user venues first

    /// SPEC §2 step 1: "If the fix falls inside a saved venue's geofence (Home,
    /// or a previously confirmed bar), auto-tag the event. No prompt."
    ///
    /// Home wins ties on purpose — drinks at home are never prompted for, and a
    /// bar across the street from your flat must not hijack that (SPEC §2).
    public func savedVenue(for fix: LocationFix, in venues: [VenueSnapshot]) -> VenueSnapshot? {

        let inside = venues
            .map { ($0, fix.distance(toLatitude: $0.latitude, longitude: $0.longitude)) }
            .filter { $0.1 <= $0.0.radiusMeters }

        guard !inside.isEmpty else { return nil }

        let home = inside.filter { $0.0.category.isHome }
        let pool = home.isEmpty ? inside : home

        return pool
            .sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                return $0.0.id.uuidString < $1.0.id.uuidString
            }
            .first?.0
    }

    // MARK: - Step 3: the confidence rule

    /// SPEC §2 step 3: "a single confident candidate (nearest POI, distance <
    /// accuracy + 50 m)".
    ///
    /// Returns `nil` for step 4's "ambiguous or no results" — which is also what
    /// a tie means: two POIs at the same distance is exactly the case where
    /// guessing would be worse than staying quiet.
    public func confidentCandidate(among candidates: [VenueCandidate], fix: LocationFix) -> VenueCandidate? {

        let threshold = configuration.confidenceThreshold(for: fix)
        let ordered = candidates.sorted(by: VenueCandidate.isOrderedBefore)

        guard let nearest = ordered.first, nearest.distanceMeters < threshold else { return nil }

        // A dead heat is not confidence.
        if let runnerUp = ordered.dropFirst().first, runnerUp.distanceMeters == nearest.distanceMeters {
            return nil
        }
        return nearest
    }

    /// The candidates the sheet offers behind "Somewhere else nearby…".
    public func alternates(among candidates: [VenueCandidate], excluding primary: VenueCandidate) -> [VenueCandidate] {
        candidates
            .filter { $0.id != primary.id }
            .sorted(by: VenueCandidate.isOrderedBefore)
            .prefix(configuration.maxAlternates)
            .map { $0 }
    }

    /// Merges saved venues into a POI result set so the picker never offers a
    /// duplicate of somewhere you've already confirmed. Saved entries win, since
    /// they carry the user's own name and category.
    public func merge(
        poiCandidates: [VenueCandidate],
        savedVenues: [VenueSnapshot],
        fix: LocationFix?,
        withinMeters: CLLocationDistance
    ) -> [VenueCandidate] {

        let saved = savedVenues
            .map { VenueCandidate(venue: $0, fix: fix) }
            .filter { fix == nil || $0.distanceMeters <= withinMeters }

        var result = saved
        for candidate in poiCandidates where !saved.contains(where: { $0.matches(candidate) }) {
            result.append(candidate)
        }
        return result.sorted(by: VenueCandidate.isOrderedBefore)
    }
}

// MARK: - Venue identity

public extension VenueCandidate {

    /// SPEC §1's dedupe rule, applied between two candidates: matched by
    /// `mapItemID`, or by name + proximity for user-defined ones.
    nonisolated func matches(_ other: VenueCandidate, proximityMeters: CLLocationDistance = 60) -> Bool {
        if let mine = mapItemID, let theirs = other.mapItemID { return mine == theirs }
        guard name.compare(other.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else {
            return false
        }
        let distance = CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
        return distance <= proximityMeters
    }

    /// The same rule against a stored venue.
    nonisolated func matches(_ venue: VenueSnapshot, proximityMeters: CLLocationDistance = 60) -> Bool {
        matches(VenueCandidate(venue: venue, fix: nil), proximityMeters: proximityMeters)
    }
}
