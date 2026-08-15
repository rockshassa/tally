import Foundation
import CoreLocation
import UserNotifications

#if canImport(HealthKit)
import HealthKit
#endif

#if os(iOS)
import UIKit
#endif

/// The real thing. Wraps CoreLocation, UserNotifications, and HealthKit behind
/// `PermissionsService` (SPEC §9).
///
/// Nothing here requests anything on its own — every call is made by a primer
/// that has already explained itself, because iOS shows each system dialog exactly
/// once and a burned prompt cannot be re-asked.
@MainActor
public final class LivePermissionsService: NSObject, PermissionsService {

    // MARK: Location

    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<LocationAuthorization, Never>?

    // MARK: Health

    #if canImport(HealthKit)
    private let healthStore = HKHealthStore()

    /// SPEC §4: exercise minutes, active energy, step count, and workouts. Sleep
    /// and resting heart rate are deliberately out of scope for v1.
    public static var activityReadTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType()]
        for identifier in [
            HKQuantityTypeIdentifier.appleExerciseTime,
            .activeEnergyBurned,
            .stepCount
        ] {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                types.insert(type)
            }
        }
        return types
    }

    /// SPEC §10: the only thing Tally ever writes to Health.
    public static var alcoholWriteType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .numberOfAlcoholicBeverages)
    }
    #endif

    /// Records that the read sheet has been presented. HealthKit never discloses
    /// read authorization, so this is the only honest thing to track.
    private static let healthReadRequestedKey = "tally.permissions.healthReadRequested"

    public override init() {
        super.init()
        locationManager.delegate = self
    }

    // MARK: - Location

    public func locationAuthorization() -> LocationAuthorization {
        LocationAuthorization(locationManager.authorizationStatus)
    }

    @discardableResult
    public func requestLocationWhenInUse() async -> LocationAuthorization {
        let current = locationAuthorization()
        guard current.canPrompt else { return current }
        return await awaitAuthorizationChange {
            self.locationManager.requestWhenInUseAuthorization()
        }
    }

    @discardableResult
    public func requestLocationAlways() async -> LocationAuthorization {
        let current = locationAuthorization()
        // Already there, or the system will never show the sheet again.
        guard current == .whenInUse || current == .notDetermined else { return current }
        return await awaitAuthorizationChange {
            self.locationManager.requestAlwaysAuthorization()
        }
    }

    private func awaitAuthorizationChange(
        _ request: @escaping @MainActor () -> Void
    ) async -> LocationAuthorization {
        // A previous request that never got a callback must not strand a
        // continuation; resume it with the current value before starting a new one.
        if let pending = locationContinuation {
            locationContinuation = nil
            pending.resume(returning: locationAuthorization())
        }
        return await withCheckedContinuation { continuation in
            locationContinuation = continuation
            request()
        }
    }

    private func resumeLocationContinuation(with status: LocationAuthorization) {
        guard let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume(returning: status)
    }

    // MARK: - Notifications

    public func notificationAuthorization() async -> PermissionStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return PermissionStatus(settings.authorizationStatus)
    }

    @discardableResult
    public func requestNotifications(provisional: Bool) async -> PermissionStatus {
        var options: UNAuthorizationOptions = [.alert, .badge, .sound]
        if provisional { options.insert(.provisional) }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: options)
        return await notificationAuthorization()
    }

    // MARK: - HealthKit

    public var isHealthDataAvailable: Bool {
        #if canImport(HealthKit)
        return HKHealthStore.isHealthDataAvailable()
        #else
        return false
        #endif
    }

    public func healthAuthorization() -> HealthAuthorization {
        #if canImport(HealthKit)
        guard isHealthDataAvailable else { return .unavailable }
        let write: PermissionStatus
        if let type = Self.alcoholWriteType {
            write = PermissionStatus(healthStore.authorizationStatus(for: type))
        } else {
            write = .restricted
        }
        return HealthAuthorization(
            isAvailable: true,
            readRequested: UserDefaults.standard.bool(forKey: Self.healthReadRequestedKey),
            alcoholWrite: write
        )
        #else
        return .unavailable
        #endif
    }

    @discardableResult
    public func requestHealthActivityRead() async -> Bool {
        #if canImport(HealthKit)
        guard isHealthDataAvailable else { return false }
        do {
            try await healthStore.requestAuthorization(toShare: [], read: Self.activityReadTypes)
            UserDefaults.standard.set(true, forKey: Self.healthReadRequestedKey)
            return true
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    @discardableResult
    public func requestHealthAlcoholWrite() async -> Bool {
        #if canImport(HealthKit)
        guard isHealthDataAvailable, let type = Self.alcoholWriteType else { return false }
        do {
            try await healthStore.requestAuthorization(toShare: [type], read: [])
            return healthStore.authorizationStatus(for: type) == .sharingAuthorized
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    // MARK: - Settings deep link

    public func openSystemSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }
}

// MARK: - CLLocationManagerDelegate

extension LivePermissionsService: CLLocationManagerDelegate {

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // CoreLocation delivers on the queue the manager was created on, which is
        // the main queue here.
        MainActor.assumeIsolated {
            self.resumeLocationContinuation(with: LocationAuthorization(manager.authorizationStatus))
        }
    }
}

// MARK: - System status bridging

extension LocationAuthorization {

    public init(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .authorizedWhenInUse: self = .whenInUse
        case .authorizedAlways: self = .always
        @unknown default: self = .notDetermined
        }
    }
}

extension PermissionStatus {

    public init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .authorized: self = .authorized
        case .provisional: self = .provisional
        case .ephemeral: self = .limited
        @unknown default: self = .notDetermined
        }
    }

    #if canImport(HealthKit)
    public init(_ status: HKAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .sharingDenied: self = .denied
        case .sharingAuthorized: self = .authorized
        @unknown default: self = .notDetermined
        }
    }
    #endif
}
