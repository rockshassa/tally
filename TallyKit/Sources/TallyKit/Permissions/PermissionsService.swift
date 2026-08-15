import Foundation

// MARK: - Status types

/// Generic permission state, used for notifications and HealthKit writes.
public enum PermissionStatus: String, CaseIterable, Codable, Hashable, Sendable {
    case notDetermined
    case denied
    case authorized

    /// Notifications delivered quietly without a prompt (SPEC §9: the weekly
    /// digest may use provisional delivery).
    case provisional

    /// The user granted less than was asked for.
    case limited

    /// Blocked by device policy — re-prompting is impossible and pointless.
    case restricted

    public var isUsable: Bool {
        self == .authorized || self == .provisional || self == .limited
    }

    /// SPEC §9: anything denied at the system level deep-links to Settings,
    /// because iOS shows each system dialog exactly once.
    public var needsSystemSettings: Bool {
        self == .denied || self == .restricted
    }

    public var canPrompt: Bool { self == .notDetermined }
}

/// Location state. Kept separate from `PermissionStatus` because the
/// When-In-Use → Always upgrade is a distinct step (SPEC §2, §9).
public enum LocationAuthorization: String, CaseIterable, Codable, Hashable, Sendable {
    case notDetermined
    case denied
    case restricted
    case whenInUse
    case always

    /// Enough for the one-shot fix on every log event (SPEC §2).
    public var allowsOneShotFix: Bool { self == .whenInUse || self == .always }

    /// Enough for Bar Radar's geofences and visit monitoring (SPEC §2).
    public var allowsBarRadar: Bool { self == .always }

    public var canPrompt: Bool { self == .notDetermined }

    public var needsSystemSettings: Bool { self == .denied || self == .restricted }

    public var asPermissionStatus: PermissionStatus {
        switch self {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .whenInUse: .limited
        case .always: .authorized
        }
    }
}

/// HealthKit state (SPEC §4, §10).
///
/// HealthKit deliberately never reveals *read* authorization — that would leak
/// whether the user has the data at all — so `readRequested` records only that we
/// asked. Absence of insights is the honest signal (SPEC §4: "Absence is fine").
public struct HealthAuthorization: Hashable, Sendable {

    public let isAvailable: Bool
    public let readRequested: Bool
    public let alcoholWrite: PermissionStatus

    public init(isAvailable: Bool, readRequested: Bool, alcoholWrite: PermissionStatus) {
        self.isAvailable = isAvailable
        self.readRequested = readRequested
        self.alcoholWrite = alcoholWrite
    }

    public static let unavailable = HealthAuthorization(
        isAvailable: false,
        readRequested: false,
        alcoholWrite: .denied
    )
}

/// Everything the Settings permission rows need in one read (SPEC §9).
public struct PermissionSnapshot: Hashable, Sendable {

    public let location: LocationAuthorization
    public let notifications: PermissionStatus
    public let health: HealthAuthorization

    public init(
        location: LocationAuthorization,
        notifications: PermissionStatus,
        health: HealthAuthorization
    ) {
        self.location = location
        self.notifications = notifications
        self.health = health
    }
}

// MARK: - Protocol

/// The shared contract behind every permission primer and Settings status row
/// (SPEC §9).
///
/// Main-actor bound because every caller is UI, and because `CLLocationManager`
/// wants a run loop. Ships with a mock (`MockPermissionsService`) so UI agents can
/// drive every permission state without a single system dialog.
@MainActor
public protocol PermissionsService: AnyObject {

    // Location — SPEC §2, §9
    func locationAuthorization() -> LocationAuthorization

    /// First-run primer → system When-In-Use prompt (SPEC §9 screen 2).
    @discardableResult
    func requestLocationWhenInUse() async -> LocationAuthorization

    /// The Bar Radar upgrade (SPEC §2). Only meaningful from `.whenInUse`.
    @discardableResult
    func requestLocationAlways() async -> LocationAuthorization

    // Notifications — SPEC §5, §9
    func notificationAuthorization() async -> PermissionStatus

    /// `provisional: true` delivers quietly without a prompt — used for the
    /// weekly digest before the user has been asked (SPEC §9 etiquette).
    @discardableResult
    func requestNotifications(provisional: Bool) async -> PermissionStatus

    // HealthKit — SPEC §4, §10
    var isHealthDataAvailable: Bool { get }
    func healthAuthorization() -> HealthAuthorization

    /// Activity types only: exercise minutes, active energy, steps, workouts.
    /// Returns whether the sheet completed without error — never whether the user
    /// granted, which HealthKit does not disclose.
    @discardableResult
    func requestHealthActivityRead() async -> Bool

    /// `numberOfAlcoholicBeverages`, off by default (SPEC §10).
    @discardableResult
    func requestHealthAlcoholWrite() async -> Bool

    // Settings deep link — SPEC §9
    func openSystemSettings()
}

public extension PermissionsService {

    /// One read for the whole Settings screen.
    func snapshot() async -> PermissionSnapshot {
        PermissionSnapshot(
            location: locationAuthorization(),
            notifications: await notificationAuthorization(),
            health: healthAuthorization()
        )
    }

    @discardableResult
    func requestNotifications() async -> PermissionStatus {
        await requestNotifications(provisional: false)
    }
}
