import Foundation
import TallyKit

/// Injectable stand-in for `LocationService` — previews, and the Gate 1 item
/// "with a mocked fix and POI result, the check-in sheet fires on a single
/// confident candidate".
@MainActor
public final class MockLocationService: LocationFixProviding {

    public var authorization: LocationAuthorization
    public var stagedFix: LocationFix?

    /// Simulates the ~5 s timeout path (SPEC §6) without waiting for it.
    public var timesOut: Bool

    public private(set) var fixRequestCount = 0

    public init(
        authorization: LocationAuthorization = .whenInUse,
        stagedFix: LocationFix? = nil,
        timesOut: Bool = false
    ) {
        self.authorization = authorization
        self.stagedFix = stagedFix
        self.timesOut = timesOut
    }

    public func oneShotFix(timeout: TimeInterval) async -> LocationFix? {
        fixRequestCount += 1
        guard authorization.allowsOneShotFix, !timesOut else { return nil }
        return stagedFix
    }
}
