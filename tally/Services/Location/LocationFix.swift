import CoreLocation
import Foundation

/// One position sample, taken at the moment a drink is logged (SPEC §2).
///
/// A value type on purpose: it crosses actor boundaries, gets stored on a
/// `DrinkEvent`, and feeds the pure parts of the inference pipeline, none of
/// which should hold on to a `CLLocation`.
nonisolated public struct LocationFix: Hashable, Sendable {

    public let latitude: Double
    public let longitude: Double

    /// Radius of uncertainty in meters. Feeds the "distance < accuracy + 50 m"
    /// confidence rule (SPEC §2).
    public let horizontalAccuracy: Double

    public let timestamp: Date

    public init(latitude: Double, longitude: Double, horizontalAccuracy: Double, timestamp: Date = Date()) {
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }

    public init(_ location: CLLocation) {
        self.init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            // CoreLocation reports a negative accuracy when the fix is invalid.
            horizontalAccuracy: max(0, location.horizontalAccuracy),
            timestamp: location.timestamp
        )
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public var clLocation: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }

    public func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        clLocation.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    public func distance(toLatitude latitude: Double, longitude: Double) -> CLLocationDistance {
        clLocation.distance(from: CLLocation(latitude: latitude, longitude: longitude))
    }
}

// MARK: - Formatting

public extension CLLocationDistance {

    /// "40 m away" / "1.2 km away", matching the check-in sheet chip in the
    /// mockups.
    nonisolated var tallyShortDistanceDescription: String {
        if self < 1000 {
            return "\(Int(self.rounded())) m"
        }
        return String(format: "%.1f km", self / 1000)
    }
}
