import Foundation

// MARK: - Drink type

/// What was consumed. v1 has exactly two buckets (SPEC §1).
///
/// Persisted as a raw `String` on `DrinkEvent.typeRaw` — never as a SwiftData
/// enum column — so the schema stays CloudKit-safe (SPEC §1).
public enum DrinkType: String, CaseIterable, Codable, Hashable, Sendable {
    case alcoholic
    case nonAlcoholic

    public var isAlcoholic: Bool { self == .alcoholic }

    public var displayName: String {
        switch self {
        case .alcoholic: "Alcoholic"
        case .nonAlcoholic: "Non-alcoholic"
        }
    }

    /// Short label used on buttons and widgets.
    public var shortName: String {
        switch self {
        case .alcoholic: "Drink"
        case .nonAlcoholic: "NA"
        }
    }
}

// MARK: - Event source

/// Which surface created a `DrinkEvent` (SPEC §1, §6, §7).
public enum EventSource: String, CaseIterable, Codable, Hashable, Sendable {
    case app
    case widget
    case watch

    /// Events from these surfaces may land without coordinates and are offered
    /// venue reconciliation on next app open (SPEC §6).
    public var needsReconciliation: Bool { self != .app }

    public var displayName: String {
        switch self {
        case .app: "App"
        case .widget: "Widget"
        case .watch: "Watch"
        }
    }
}

// MARK: - Venue

/// Venue classification (SPEC §1).
public enum VenueCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case bar
    case restaurant
    case home
    case other

    /// Home is never a Bar Radar target and never earns bar-only badges (SPEC §2, §3).
    public var isHome: Bool { self == .home }

    /// Venues that count as "out" for `Badge.designatedLegend` (SPEC §3).
    public var isNightlife: Bool { self == .bar || self == .restaurant }

    public var displayName: String {
        switch self {
        case .bar: "Bar"
        case .restaurant: "Restaurant"
        case .home: "Home"
        case .other: "Other"
        }
    }

    /// Default geofence radius in meters (SPEC §1: default 75, home 100).
    public var defaultRadiusMeters: Double {
        self == .home ? 100 : 75
    }
}

/// How a venue entered the store (SPEC §1).
public enum VenueSource: String, CaseIterable, Codable, Hashable, Sendable {
    case userDefined
    case mapKitPOI
}
