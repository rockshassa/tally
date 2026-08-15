import CoreLocation
import Foundation
import TallyKit

/// One-shot location, nothing more (SPEC §2, §10).
///
/// Deliberately minimal: no continuous tracking, no background modes, no
/// significant-change or visit monitoring. Bar Radar (SPEC §2, Wave 3) is the
/// only thing that ever needs more, and it brings its own service.
@MainActor
public protocol LocationFixProviding: AnyObject {

    /// Current authorization, passed straight through from CoreLocation.
    var authorization: LocationAuthorization { get }

    /// A single fix, or `nil` if permission is missing, the fix fails, or the
    /// timeout expires. Never throws and never blocks the tap that triggered it
    /// (SPEC §1: "The count must never wait on GPS").
    func oneShotFix(timeout: TimeInterval) async -> LocationFix?
}

public extension LocationFixProviding {

    func oneShotFix() async -> LocationFix? {
        await oneShotFix(timeout: LocationDefaults.fixTimeout)
    }
}

/// SPEC §6 uses ~5 s as the give-up point; every logging surface uses the same
/// budget so behavior is identical wherever a drink comes from.
nonisolated public enum LocationDefaults {
    public static let fixTimeout: TimeInterval = 5
}

// MARK: - Live implementation

/// `CLLocationManager` wrapper around `requestLocation()`.
@MainActor
public final class LocationService: NSObject, LocationFixProviding {

    private let manager: CLLocationManager
    private var continuation: CheckedContinuation<LocationFix?, Never>?
    private var timeoutTask: Task<Void, Never>?

    public init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        super.init()
        self.manager.delegate = self
        // Venue geofences are 75–100 m, so ten-meter accuracy is plenty and it
        // settles far faster (and cheaper) than best-for-navigation.
        self.manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    public var authorization: LocationAuthorization {
        LocationAuthorization(manager.authorizationStatus)
    }

    public func oneShotFix(timeout: TimeInterval = LocationDefaults.fixTimeout) async -> LocationFix? {
        // Nothing to ask for, and asking here would be a permission prompt with
        // no primer in front of it (SPEC §9).
        guard authorization.allowsOneShotFix else { return nil }

        // A previous request that never got a callback must not strand its
        // caller — resume it before taking the slot.
        finish(with: nil)

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.finish(with: nil)
            }
            self.manager.requestLocation()
        }
    }

    private func finish(with fix: LocationFix?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        guard let pending = continuation else { return }
        continuation = nil
        pending.resume(returning: fix)
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // The manager was created on the main actor, so CoreLocation delivers here.
        let fix = locations.last.map(LocationFix.init)
        MainActor.assumeIsolated { self.finish(with: fix) }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // A failed fix is not an error the user should ever see: the drink is
        // already logged, it just stays coordinate-free (SPEC §2).
        MainActor.assumeIsolated { self.finish(with: nil) }
    }
}
