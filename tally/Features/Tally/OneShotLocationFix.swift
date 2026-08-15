import CoreLocation
import Foundation

/// A single location fix, taken at the moment a drink is logged (SPEC §1, §2).
///
/// Deliberately small and deliberately private to the Tally feature: the `place`
/// workstream owns the full `LocationService` (geofences, POI lookup, venue
/// inference). This type exists so the counter can attach coordinates on its own
/// without either agent editing the other's files.
///
/// Three rules it never breaks:
/// * **It never requests authorization.** SPEC §9 says the primer always comes
///   first; onboarding and Settings do the asking. With nothing granted, this
///   returns `nil` and logging carries on untagged.
/// * **It never blocks the count.** The caller logs the event first and awaits
///   this afterwards; a fix that misses the ~5 s window (SPEC §6) simply leaves
///   the coordinates nil.
/// * **One fix, no stream.** `requestLocation()` delivers once and stops — no
///   continuous tracking, per SPEC §10.
@MainActor
final class OneShotLocationFix: NSObject {

    /// SPEC §6: "if the fix can't be obtained within ~5 s … no coordinates."
    nonisolated static let defaultTimeout: TimeInterval = 5

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        // Venue-level precision is all venue inference needs, and the coarser
        // ask returns faster and costs less battery.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Whether a fix is even possible right now (SPEC §2: When-In-Use is enough).
    var isAuthorized: Bool {
        LocationAuthorizationLevel(manager.authorizationStatus).allowsOneShotFix
    }

    /// Requests one fix, resolving to `nil` on denial, failure, or timeout.
    func fix(timeout: TimeInterval = OneShotLocationFix.defaultTimeout) async -> CLLocation? {
        guard isAuthorized else { return nil }
        // A tap while a previous fix is still in flight must not strand a
        // continuation; the earlier request wins and this one comes back empty.
        guard continuation == nil else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
            self.continuation = continuation
            manager.requestLocation()

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finish(nil)
            }
        }
    }

    private func finish(_ location: CLLocation?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: location)
    }
}

// MARK: - CLLocationManagerDelegate

extension OneShotLocationFix: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // CoreLocation delivers on the queue the manager was created on — main.
        let latest = locations.last
        MainActor.assumeIsolated { self.finish(latest) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { self.finish(nil) }
    }
}

// MARK: - Authorization bridging

/// Local mirror of `CLAuthorizationStatus`, so this helper does not depend on
/// `PermissionsService` for a single yes/no question.
private enum LocationAuthorizationLevel {
    case notDetermined
    case denied
    case whenInUse
    case always

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse: self = .whenInUse
        case .authorizedAlways: self = .always
        case .denied, .restricted: self = .denied
        case .notDetermined: self = .notDetermined
        @unknown default: self = .notDetermined
        }
    }

    var allowsOneShotFix: Bool { self == .whenInUse || self == .always }
}
