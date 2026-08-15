import CoreLocation
import Foundation
import TallyKit

// The value types Bar Radar (SPEC §2) is made of.
//
// Everything here is a pure, `Sendable`, mostly-`Codable` value: the decision
// logic in `FrequentedVenues`, `RadarVisitMachine`, and `DiscoveryGate` is
// written against these types alone, so every rule in SPEC §2 can be exercised
// from a fixture without CoreLocation, MapKit, or a notification centre.

// MARK: - Identifiers

/// Every string Bar Radar puts into a system API, in one place.
///
/// They are round-trippable on purpose: a `CLMonitor` event arrives carrying
/// only the identifier the condition was registered under, and a notification
/// action arrives carrying only what we put in its `userInfo`.
nonisolated public enum RadarIdentifiers {

    /// The `CLMonitor` instance name. CoreLocation persists conditions under
    /// this name across launches, which is what lets a geofence survive the app
    /// being killed.
    public static let monitorName = "TallyBarRadar"

    static let conditionPrefix = "tally.radar.venue."

    public static func condition(for venueID: UUID) -> String {
        conditionPrefix + venueID.uuidString
    }

    public static func venueID(fromCondition identifier: String) -> UUID? {
        guard identifier.hasPrefix(conditionPrefix) else { return nil }
        return UUID(uuidString: String(identifier.dropFirst(conditionPrefix.count)))
    }

    // Notification actions (SPEC §2).

    /// "+1 drink" — logs without launching the app.
    public static let logDrinkAction = "tally.radar.action.logDrink"

    /// "Not drinking tonight" — silences the rest of this visit.
    public static let notDrinkingAction = "tally.radar.action.notDrinking"

    /// "Not a bar / don't ask here" — writes a `SuppressedPlace`.
    public static let notABarAction = "tally.radar.action.notABar"

    /// "Mute this venue" — SPEC §2: per-venue mute is "also offered on the
    /// arrival notification after repeated dismissals".
    public static let muteVenueAction = "tally.radar.action.muteVenue"

    /// The arrival category, plus the mute button. A second registered category
    /// rather than a third button on the first one, because SPEC §2 offers mute
    /// only "after repeated dismissals" and a `UNNotificationCategory`'s actions
    /// are fixed at registration.
    public static func mutableVariant(of categoryIdentifier: String) -> String {
        categoryIdentifier + ".withMute"
    }

    // `userInfo` keys. Values are always strings: `NotificationAction` flattens
    // `userInfo` with `String(describing:)` before it reaches us.

    static let kindKey = "radarKind"
    static let visitKey = "radarVisit"
    static let venueKey = "radarVenue"
    static let placeNameKey = "radarPlaceName"
    static let latitudeKey = "radarLatitude"
    static let longitudeKey = "radarLongitude"
    static let mapItemKey = "radarMapItem"
    static let categoryKey = "radarPlaceCategory"
}

// MARK: - Tier 1 target

/// A frequented venue that has earned a geofence (SPEC §2 Tier 1).
///
/// Derived, never stored: `FrequentedVenues` recomputes the whole set from the
/// event log, which keeps SPEC §1's "derive, don't store" rule intact even for
/// the thing CoreLocation is asked to remember.
nonisolated public struct RadarTarget: Identifiable, Hashable, Sendable, Codable {

    public let venueID: UUID
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let radiusMeters: Double

    /// Sessions inside the trailing window. ≥ 3 is what made this a target.
    public let sessionCount: Int

    /// Most recent Session at this venue — the recency key the region budget
    /// sorts by.
    public let lastSessionAt: Date

    public var id: UUID { venueID }

    public init(
        venueID: UUID,
        name: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: Double,
        sessionCount: Int,
        lastSessionAt: Date
    ) {
        self.venueID = venueID
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.sessionCount = sessionCount
        self.lastSessionAt = lastSessionAt
    }

    public init(venue: VenueSnapshot, sessionCount: Int, lastSessionAt: Date) {
        self.init(
            venueID: venue.id,
            name: venue.name,
            latitude: venue.latitude,
            longitude: venue.longitude,
            radiusMeters: venue.radiusMeters,
            sessionCount: sessionCount,
            lastSessionAt: lastSessionAt
        )
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// The identifier this target's condition is registered under.
    public var monitoringIdentifier: String { RadarIdentifiers.condition(for: venueID) }

    /// Most recent first; count, then UUID, as deterministic tiebreakers.
    public static func isOrderedBefore(_ lhs: RadarTarget, _ rhs: RadarTarget) -> Bool {
        if lhs.lastSessionAt != rhs.lastSessionAt { return lhs.lastSessionAt > rhs.lastSessionAt }
        if lhs.sessionCount != rhs.sessionCount { return lhs.sessionCount > rhs.sessionCount }
        return lhs.venueID.uuidString < rhs.venueID.uuidString
    }
}

// MARK: - Tier 1 events

/// What the OS tells the app about a geofence (SPEC §2: "the app receives
/// entry/exit events only, never a location stream").
nonisolated public enum RadarRegionEvent: Hashable, Sendable {
    case entered(venueID: UUID, at: Date)
    case exited(venueID: UUID, at: Date)

    public var venueID: UUID {
        switch self {
        case .entered(let id, _), .exited(let id, _): id
        }
    }

    public var date: Date {
        switch self {
        case .entered(_, let date), .exited(_, let date): date
        }
    }
}

// MARK: - Tier 2 observation

/// A `CLVisit`, reduced to the parts Bar Radar reasons about (SPEC §2 Tier 2).
///
/// A value type rather than the `CLVisit` itself: the discovery gate is a pure
/// function, and a fixture visit has to be as easy to build as a real one.
nonisolated public struct RadarVisitObservation: Hashable, Sendable, Codable {

    public let latitude: Double
    public let longitude: Double

    /// "An estimate of the radius (in meters) of the region which the device is
    /// visiting" — SPEC §2's "within the visit's accuracy radius".
    public let horizontalAccuracy: Double

    public let arrivalDate: Date

    /// `.distantFuture` while the device is still there.
    public let departureDate: Date

    public init(
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        arrivalDate: Date = Date(),
        departureDate: Date = .distantFuture
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = max(0, horizontalAccuracy)
        self.arrivalDate = arrivalDate
        self.departureDate = departureDate
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// SPEC §2: visit events "occasionally [land] on departure". Prompting
    /// someone to start a Session somewhere they have already left is worse than
    /// silence, so a closed visit is discarded.
    public var hasDeparted: Bool { departureDate < .distantFuture }

    /// The same shape the check-in pipeline's POI lookup takes, so Tier 2 reuses
    /// `POISearchService` verbatim (SPEC §2: "the same MapKit POI lookup").
    public var fix: LocationFix {
        LocationFix(
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: horizontalAccuracy,
            timestamp: arrivalDate == .distantPast ? Date() : arrivalDate
        )
    }

    public func distance(toLatitude latitude: Double, longitude: Double) -> CLLocationDistance {
        CLLocation(latitude: self.latitude, longitude: self.longitude)
            .distance(from: CLLocation(latitude: latitude, longitude: longitude))
    }
}

// MARK: - Places

/// A discovered POI, carried through a notification and back.
///
/// Small and `Codable` because it makes the round trip into a notification's
/// `userInfo` and out again — by the time "+1 drink" is tapped the search that
/// produced it is long gone, and the app may not even have been running.
nonisolated public struct RadarPlace: Hashable, Sendable, Codable {

    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let mapItemID: String?
    public let category: VenueCategory

    public init(
        name: String,
        latitude: Double,
        longitude: Double,
        mapItemID: String? = nil,
        category: VenueCategory = .bar
    ) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.mapItemID = mapItemID
        self.category = category
    }

    public init(candidate: VenueCandidate) {
        self.init(
            name: candidate.name,
            latitude: candidate.latitude,
            longitude: candidate.longitude,
            mapItemID: candidate.mapItemID,
            category: candidate.category
        )
    }

    /// Back into the shape `VenueWriter.resolveVenue(for:in:)` speaks, so
    /// graduation (SPEC §2) reuses the check-in dedupe rules rather than
    /// inventing a second one.
    public var candidate: VenueCandidate {
        VenueCandidate(
            id: mapItemID ?? "\(name)@\(latitude),\(longitude)",
            name: name,
            category: category,
            latitude: latitude,
            longitude: longitude,
            distanceMeters: 0,
            mapItemID: mapItemID
        )
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Prompts

/// One "start a Session?" notification, before it becomes a `UNNotificationRequest`.
nonisolated public struct RadarPrompt: Hashable, Sendable {

    public enum Kind: String, Hashable, Sendable, Codable {

        /// Geofence entry at a frequented bar (SPEC §2 Tier 1).
        case arrival

        /// The +45 min follow-up, one per visit (SPEC §2 Tier 1).
        case dwell

        /// A visit at a bar never logged before (SPEC §2 Tier 2).
        case discovery

        public var category: TallyNotificationCategory {
            switch self {
            case .arrival: .barRadarArrival
            case .dwell: .barRadarDwell
            case .discovery: .barRadarDiscovery
            }
        }
    }

    public let kind: Kind

    /// The visit this prompt belongs to. Every suppression rule in SPEC §2 is
    /// scoped to a visit, so this is what the actions come back with.
    public let visitID: UUID

    public let placeName: String

    /// Tier 1: the venue whose geofence fired.
    public let venueID: UUID?

    /// Tier 2: the POI, which may not be a `Venue` yet.
    public let place: RadarPlace?

    /// SPEC §2: per-venue mute is "also offered on the arrival notification
    /// after repeated dismissals". Set by the service, which is what counts them.
    public var offersMute: Bool

    public init(
        kind: Kind,
        visitID: UUID,
        placeName: String,
        venueID: UUID? = nil,
        place: RadarPlace? = nil,
        offersMute: Bool = false
    ) {
        self.kind = kind
        self.visitID = visitID
        self.placeName = placeName
        self.venueID = venueID
        self.place = place
        self.offersMute = offersMute
    }

    public var category: TallyNotificationCategory { kind.category }

    /// The `UNNotificationCategory` this prompt should be delivered under, which
    /// is the mute-bearing variant once the user has waved this venue off twice.
    @MainActor
    public var notificationCategoryIdentifier: String {
        offersMute && kind == .arrival
            ? RadarIdentifiers.mutableVariant(of: category.identifier)
            : category.identifier
    }

    /// Stable per visit and per kind: re-delivering a prompt replaces it rather
    /// than stacking a second banner.
    ///
    /// Main-actor bound because `TallyNotificationCategory.identifier` is, and
    /// there is exactly one identifier scheme in the app — reproducing the string
    /// here to dodge the isolation would be how the two drift apart.
    @MainActor
    public var requestIdentifier: String {
        "\(category.identifier).\(visitID.uuidString)"
    }
}

// MARK: - Action payload

/// A Bar Radar notification action, decoded back into the thing it acts on.
///
/// `NotificationAction.userInfo` is `[String: String]` by the time it reaches
/// us, so everything the handler needs has to survive as text.
nonisolated public struct RadarActionPayload: Hashable, Sendable {

    public let kind: RadarPrompt.Kind
    public let visitID: UUID
    public let venueID: UUID?
    public let place: RadarPlace?
    public let placeName: String

    public init(
        kind: RadarPrompt.Kind,
        visitID: UUID,
        venueID: UUID? = nil,
        place: RadarPlace? = nil,
        placeName: String = ""
    ) {
        self.kind = kind
        self.visitID = visitID
        self.venueID = venueID
        self.place = place
        self.placeName = placeName
    }

    public init(prompt: RadarPrompt) {
        self.init(
            kind: prompt.kind,
            visitID: prompt.visitID,
            venueID: prompt.venueID,
            place: prompt.place,
            placeName: prompt.placeName
        )
    }

    /// Everything above, as notification `userInfo`.
    public var userInfo: [String: String] {
        var info: [String: String] = [
            "tallyCategory": kind.category.rawValue,
            RadarIdentifiers.kindKey: kind.rawValue,
            RadarIdentifiers.visitKey: visitID.uuidString,
            RadarIdentifiers.placeNameKey: placeName
        ]
        if let venueID { info[RadarIdentifiers.venueKey] = venueID.uuidString }
        if let place {
            info[RadarIdentifiers.latitudeKey] = String(place.latitude)
            info[RadarIdentifiers.longitudeKey] = String(place.longitude)
            info[RadarIdentifiers.categoryKey] = place.category.rawValue
            if let mapItemID = place.mapItemID {
                info[RadarIdentifiers.mapItemKey] = mapItemID
            }
        }
        return info
    }

    /// `nil` for anything that is not one of ours — the handler is wired into a
    /// centre that carries four other categories.
    public init?(userInfo: [String: String]) {
        guard
            let rawKind = userInfo[RadarIdentifiers.kindKey],
            let kind = RadarPrompt.Kind(rawValue: rawKind),
            let rawVisit = userInfo[RadarIdentifiers.visitKey],
            let visitID = UUID(uuidString: rawVisit)
        else { return nil }

        let name = userInfo[RadarIdentifiers.placeNameKey] ?? ""
        let venueID = userInfo[RadarIdentifiers.venueKey].flatMap(UUID.init(uuidString:))

        var place: RadarPlace?
        if
            let latitude = userInfo[RadarIdentifiers.latitudeKey].flatMap(Double.init),
            let longitude = userInfo[RadarIdentifiers.longitudeKey].flatMap(Double.init)
        {
            place = RadarPlace(
                name: name,
                latitude: latitude,
                longitude: longitude,
                mapItemID: userInfo[RadarIdentifiers.mapItemKey],
                category: userInfo[RadarIdentifiers.categoryKey]
                    .flatMap(VenueCategory.init(rawValue:)) ?? .bar
            )
        }

        self.init(kind: kind, visitID: visitID, venueID: venueID, place: place, placeName: name)
    }
}

// MARK: - Effects

/// What a decision asks the world to do.
///
/// The state machine returns these instead of performing them, which is the
/// seam that keeps SPEC §2's visit rules testable without a notification centre
/// or a `ModelContext`.
nonisolated public enum RadarEffect: Hashable, Sendable {

    /// SPEC §2: "auto check-in to the venue (it's known — no confirmation sheet
    /// needed)".
    case autoCheckIn(venueID: UUID, visitID: UUID)

    /// Deliver now.
    case deliver(RadarPrompt)

    /// SPEC §2's "+45 min (configurable)" follow-up.
    case scheduleDwell(RadarPrompt, at: Date)

    /// Any logged drink, or the exit event, retracts it.
    case cancelDwell(visitID: UUID)

    /// SPEC §2: a Session "closes … immediately when a Bar Radar exit event
    /// fires". Persisted so `SessionDeriver` can consume it.
    case recordExit(venueID: UUID, at: Date)
}
