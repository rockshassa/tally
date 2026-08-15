import Foundation

/// Injectable stand-in for `LivePermissionsService`.
///
/// Gate 0 requires that UI agents can test every permission state without ever
/// showing a system dialog (PLAN Wave 0). Set the `*Status` properties to stage a
/// state, set `grantOnRequest` to choose what the simulated user does, and read
/// `requests` to assert that a primer actually asked.
@MainActor
public final class MockPermissionsService: PermissionsService {

    // MARK: Staged state

    public var locationStatus: LocationAuthorization
    public var notificationStatus: PermissionStatus
    public var healthDataAvailable: Bool
    public var healthReadRequested: Bool
    public var healthWriteStatus: PermissionStatus

    /// What the simulated user taps. `false` denies every request.
    public var grantOnRequest: Bool

    /// What `requestLocationWhenInUse()` resolves to when `grantOnRequest` is true.
    public var grantedLocationLevel: LocationAuthorization

    // MARK: Recorded calls

    public enum Request: Hashable, Sendable {
        case locationWhenInUse
        case locationAlways
        case notifications(provisional: Bool)
        case healthActivityRead
        case healthAlcoholWrite
        case openSystemSettings
    }

    public private(set) var requests: [Request] = []

    public func reset() { requests = [] }

    public func received(_ request: Request) -> Bool { requests.contains(request) }

    // MARK: Init

    public init(
        locationStatus: LocationAuthorization = .notDetermined,
        notificationStatus: PermissionStatus = .notDetermined,
        healthDataAvailable: Bool = true,
        healthReadRequested: Bool = false,
        healthWriteStatus: PermissionStatus = .notDetermined,
        grantOnRequest: Bool = true,
        grantedLocationLevel: LocationAuthorization = .whenInUse
    ) {
        self.locationStatus = locationStatus
        self.notificationStatus = notificationStatus
        self.healthDataAvailable = healthDataAvailable
        self.healthReadRequested = healthReadRequested
        self.healthWriteStatus = healthWriteStatus
        self.grantOnRequest = grantOnRequest
        self.grantedLocationLevel = grantedLocationLevel
    }

    /// Everything denied — the "logging still works, events just have no
    /// coordinates" path from SPEC §2.
    public static func allDenied() -> MockPermissionsService {
        MockPermissionsService(
            locationStatus: .denied,
            notificationStatus: .denied,
            healthDataAvailable: true,
            healthWriteStatus: .denied,
            grantOnRequest: false
        )
    }

    /// Everything already granted, including the Bar Radar upgrade.
    public static func allGranted() -> MockPermissionsService {
        MockPermissionsService(
            locationStatus: .always,
            notificationStatus: .authorized,
            healthDataAvailable: true,
            healthReadRequested: true,
            healthWriteStatus: .authorized,
            grantedLocationLevel: .always
        )
    }

    // MARK: - PermissionsService

    public func locationAuthorization() -> LocationAuthorization { locationStatus }

    @discardableResult
    public func requestLocationWhenInUse() async -> LocationAuthorization {
        requests.append(.locationWhenInUse)
        guard locationStatus.canPrompt else { return locationStatus }
        locationStatus = grantOnRequest ? grantedLocationLevel : .denied
        return locationStatus
    }

    @discardableResult
    public func requestLocationAlways() async -> LocationAuthorization {
        requests.append(.locationAlways)
        guard locationStatus == .whenInUse || locationStatus == .notDetermined else { return locationStatus }
        locationStatus = grantOnRequest ? .always : .whenInUse
        return locationStatus
    }

    public func notificationAuthorization() async -> PermissionStatus { notificationStatus }

    @discardableResult
    public func requestNotifications(provisional: Bool) async -> PermissionStatus {
        requests.append(.notifications(provisional: provisional))
        guard notificationStatus.canPrompt else { return notificationStatus }
        if grantOnRequest {
            notificationStatus = provisional ? .provisional : .authorized
        } else {
            notificationStatus = .denied
        }
        return notificationStatus
    }

    public var isHealthDataAvailable: Bool { healthDataAvailable }

    public func healthAuthorization() -> HealthAuthorization {
        guard healthDataAvailable else { return .unavailable }
        return HealthAuthorization(
            isAvailable: true,
            readRequested: healthReadRequested,
            alcoholWrite: healthWriteStatus
        )
    }

    @discardableResult
    public func requestHealthActivityRead() async -> Bool {
        requests.append(.healthActivityRead)
        guard healthDataAvailable else { return false }
        healthReadRequested = true
        return grantOnRequest
    }

    @discardableResult
    public func requestHealthAlcoholWrite() async -> Bool {
        requests.append(.healthAlcoholWrite)
        guard healthDataAvailable else { return false }
        healthWriteStatus = grantOnRequest ? .authorized : .denied
        return grantOnRequest
    }

    public func openSystemSettings() {
        requests.append(.openSystemSettings)
    }
}
