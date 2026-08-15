import CoreLocation
import Foundation
import TallyKit

/// Every reason SPEC §2 gives for *not* prompting at a detected visit, as one
/// pure decision.
///
/// > **False-positive gating:** plausible hours only (default 4 pm–2 am,
/// > configurable), max 3 discovery prompts per week, never inside the Home
/// > geofence, never at suppressed places.
///
/// Tier 2 is the tier most likely to annoy, so its gating is deliberately the
/// most testable thing in the feature: no MapKit, no clock, no store — a visit,
/// some snapshots, and a `now`.
nonisolated public struct DiscoveryGate: Sendable {

    // MARK: - Configuration

    nonisolated public struct Configuration: Hashable, Sendable {

        /// Minutes from local midnight. Default 16:00.
        public var startMinutes: Int

        /// Minutes from local midnight. Default 02:00 — i.e. the window crosses
        /// midnight, which is the normal case for this feature.
        public var endMinutes: Int

        /// SPEC §2: "max 3 discovery prompts per week".
        public var weeklyPromptCap: Int

        /// Rolling rather than calendar: a cap that resets on Monday would allow
        /// six prompts across a weekend.
        public var rollingWindow: TimeInterval

        /// SPEC §2: a candidate must be "within the visit's accuracy radius".
        /// A visit can report an accuracy of a few metres, which no POI centroid
        /// would ever fall inside, so the radius is floored at SPEC §1's default
        /// venue geofence.
        public var minimumRadiusMeters: CLLocationDistance

        /// SPEC §2: "Two plain dismissals at the same spot auto-suppress it."
        public var dismissalsBeforeSuppression: Int

        /// How close two visits have to be to count as "the same spot".
        public var sameSpotRadiusMeters: CLLocationDistance

        /// Defaults mirror `TallyDefaults.Fallback` (16:00–02:00). They are
        /// written out rather than referenced because that enum is main-actor
        /// isolated and this type has to stay usable from anywhere.
        public init(
            startMinutes: Int = 16 * 60,
            endMinutes: Int = 2 * 60,
            weeklyPromptCap: Int = 3,
            rollingWindow: TimeInterval = 7 * 24 * 60 * 60,
            minimumRadiusMeters: CLLocationDistance = 75,
            dismissalsBeforeSuppression: Int = 2,
            sameSpotRadiusMeters: CLLocationDistance = 75
        ) {
            self.startMinutes = Self.normalized(startMinutes)
            self.endMinutes = Self.normalized(endMinutes)
            self.weeklyPromptCap = max(0, weeklyPromptCap)
            self.rollingWindow = max(0, rollingWindow)
            self.minimumRadiusMeters = max(0, minimumRadiusMeters)
            self.dismissalsBeforeSuppression = max(1, dismissalsBeforeSuppression)
            self.sameSpotRadiusMeters = max(0, sameSpotRadiusMeters)
        }

        public static let `default` = Configuration()

        private static func normalized(_ minutes: Int) -> Int {
            let day = 24 * 60
            return ((minutes % day) + day) % day
        }

        /// Live values from Settings (SPEC §9: "discovery hours (default 4 pm–2 am)").
        @MainActor
        public static func fromSettings(_ settings: TallySettings) -> Configuration {
            Configuration(
                startMinutes: settings.discoveryStartMinutes,
                endMinutes: settings.discoveryEndMinutes
            )
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - Result

    /// Why a visit was thrown away. SPEC §2: "No candidate, or an ambiguous
    /// cluster → the event is discarded on the spot" — silently, in every case.
    nonisolated public enum Rejection: String, Hashable, Sendable, Codable {
        case radarDisabled
        case discoveryDisabled
        case alreadyDeparted
        case outsideHours
        case weeklyCapReached
        case insideHome
        case suppressedPlace

        /// Already covered by a Tier 1 geofence. SPEC §2: "geofence immediacy
        /// stays exclusive to Tier 1" — and a second prompt twenty minutes after
        /// the arrival one is exactly the nagging SPEC §9 forbids.
        case coveredByGeofence

        case noCandidate
        case ambiguous
    }

    nonisolated public enum Decision: Hashable, Sendable {
        case prompt(VenueCandidate)
        case discard(Rejection)

        public var isPrompt: Bool {
            if case .prompt = self { return true }
            return false
        }

        public var rejection: Rejection? {
            if case .discard(let reason) = self { return reason }
            return nil
        }
    }

    /// Everything the gate needs that is not the POI search result.
    ///
    /// Grouped into one value so the cheap checks can run *before* MapKit is
    /// asked anything — a visit outside discovery hours should cost nothing.
    nonisolated public struct Context: Hashable, Sendable {

        public var isRadarEnabled: Bool
        public var isDiscoveryEnabled: Bool

        /// SPEC §2: "never inside the Home geofence". Home is the only venue
        /// that blocks discovery; a saved-but-not-yet-frequented bar must keep
        /// prompting, because that is how it graduates (SPEC §2).
        public var home: VenueSnapshot?

        public var suppressedPlaces: [SuppressedPlaceSnapshot]

        /// The venues Tier 1 is already watching. A visit inside one of these is
        /// Tier 1's business and was prompted for on arrival.
        public var monitoredTargets: [RadarTarget]

        /// When the last discovery prompts fired, for the rolling cap.
        public var recentPromptDates: [Date]

        public init(
            isRadarEnabled: Bool,
            isDiscoveryEnabled: Bool,
            home: VenueSnapshot? = nil,
            suppressedPlaces: [SuppressedPlaceSnapshot] = [],
            monitoredTargets: [RadarTarget] = [],
            recentPromptDates: [Date] = []
        ) {
            self.isRadarEnabled = isRadarEnabled
            self.isDiscoveryEnabled = isDiscoveryEnabled
            self.home = home
            self.suppressedPlaces = suppressedPlaces
            self.monitoredTargets = monitoredTargets
            self.recentPromptDates = recentPromptDates
        }
    }

    // MARK: - Hours

    /// SPEC §2: "plausible hours only (default 4 pm–2 am, configurable)".
    ///
    /// The window crosses midnight by default, so this is a two-case test rather
    /// than a range check. A window whose ends are equal is treated as always
    /// open — the honest reading of "from 4 pm until 4 pm".
    public func isWithinPlausibleHours(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        if configuration.startMinutes == configuration.endMinutes { return true }
        if configuration.startMinutes < configuration.endMinutes {
            return minute >= configuration.startMinutes && minute < configuration.endMinutes
        }
        return minute >= configuration.startMinutes || minute < configuration.endMinutes
    }

    // MARK: - Preflight

    /// Everything decidable without a POI lookup.
    ///
    /// - Returns: the reason to stop, or `nil` to go ahead and search.
    public func preflight(
        visit: RadarVisitObservation,
        context: Context,
        asOf now: Date = Date(),
        calendar: Calendar = .current
    ) -> Rejection? {

        guard context.isRadarEnabled else { return .radarDisabled }
        guard context.isDiscoveryEnabled else { return .discoveryDisabled }

        // SPEC §2: visit events sometimes land on departure. Nobody wants to be
        // asked to start a Session at a bar they have left.
        guard !visit.hasDeparted else { return .alreadyDeparted }

        guard isWithinPlausibleHours(now, calendar: calendar) else { return .outsideHours }

        let recent = context.recentPromptDates.filter {
            now.timeIntervalSince($0) < configuration.rollingWindow && $0 <= now
        }
        guard recent.count < configuration.weeklyPromptCap else { return .weeklyCapReached }

        if let home = context.home {
            let distance = visit.distance(toLatitude: home.latitude, longitude: home.longitude)
            if distance <= home.radiusMeters { return .insideHome }
        }

        if isSuppressed(visit: visit, places: context.suppressedPlaces) { return .suppressedPlace }

        let covered = context.monitoredTargets.contains { target in
            visit.distance(toLatitude: target.latitude, longitude: target.longitude) <= target.radiusMeters
        }
        if covered { return .coveredByGeofence }

        return nil
    }

    /// SPEC §2: "never at suppressed places". Matched by proximity, and by
    /// MapKit identity once a candidate is known.
    public func isSuppressed(
        visit: RadarVisitObservation,
        places: [SuppressedPlaceSnapshot],
        candidate: VenueCandidate? = nil
    ) -> Bool {
        places.contains { place in
            if let mapItemID = candidate?.mapItemID, place.mapItemID == mapItemID { return true }
            let distance = visit.distance(toLatitude: place.latitude, longitude: place.longitude)
            return distance <= max(place.radiusMeters, configuration.sameSpotRadiusMeters)
        }
    }

    // MARK: - Candidate resolution

    /// The radius a candidate has to fall inside (SPEC §2).
    public func searchRadius(for visit: RadarVisitObservation) -> CLLocationDistance {
        max(visit.horizontalAccuracy, configuration.minimumRadiusMeters)
    }

    /// SPEC §2: "a **single confident nightlife candidate** within the visit's
    /// accuracy radius fires the same prompt. No candidate, or an ambiguous
    /// cluster → the event is discarded on the spot."
    ///
    /// "Nightlife" is `VenueCategory.bar`, which is where `POISearchService` maps
    /// MapKit's nightlife, brewery, distillery, and winery categories. A
    /// restaurant is not a discovery target: lunch is not a Session.
    public func resolve(
        candidates: [VenueCandidate],
        visit: RadarVisitObservation,
        context: Context
    ) -> Decision {

        let radius = searchRadius(for: visit)
        let nightlife = candidates
            .filter { $0.category == .bar && $0.distanceMeters <= radius }
            .sorted(by: VenueCandidate.isOrderedBefore)

        guard let primary = nightlife.first else { return .discard(.noCandidate) }

        // A cluster of bars inside one visit radius is the case where guessing
        // is worse than silence.
        guard nightlife.count == 1 else { return .discard(.ambiguous) }

        // The POI may itself be suppressed by MapKit identity even when the
        // visit centre is not close enough to the stored coordinate.
        if isSuppressed(visit: visit, places: context.suppressedPlaces, candidate: primary) {
            return .discard(.suppressedPlace)
        }

        return .prompt(primary)
    }

    /// Both halves, for callers (and tests) that already have the candidates.
    public func decide(
        visit: RadarVisitObservation,
        candidates: [VenueCandidate],
        context: Context,
        asOf now: Date = Date(),
        calendar: Calendar = .current
    ) -> Decision {
        if let rejection = preflight(visit: visit, context: context, asOf: now, calendar: calendar) {
            return .discard(rejection)
        }
        return resolve(candidates: candidates, visit: visit, context: context)
    }
}
