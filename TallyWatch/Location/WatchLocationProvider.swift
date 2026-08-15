//
//  WatchLocationProvider.swift
//  Best-effort one-shot fix on the wrist (SPEC §7).
//
//  Two rules govern everything here:
//
//    1. **The count never waits on GPS.** The event is written first; a fix that
//       arrives in time is attached afterwards by re-upserting the same UUID.
//    2. **Venue inference stays on the phone.** The watch only ever produces
//       coordinates. Events land untagged and go through the phone's
//       reconciliation flow on next app open (SPEC §6, §7).
//

import CoreLocation
import Foundation
import TallyKit

@MainActor
public final class WatchLocationProvider: NSObject {

    public static let shared = WatchLocationProvider()

    /// SPEC §6/§7: give up at ~5 s. A watch indoors at a bar often never gets a
    /// fix, and that must cost the user nothing.
    public static let fixTimeout: TimeInterval = 5

    /// A fix this recent is reused instead of asking the hardware again — the
    /// second drink of a round should not re-run GPS.
    public static let cacheLifetime: TimeInterval = 60

    /// Anything sloppier than this is treated as no fix at all.
    public static let maximumAcceptableAccuracy: CLLocationAccuracy = 200

    private let manager = CLLocationManager()
    private var pending: [CheckedContinuation<CLLocation?, Never>] = []
    private var cachedFix: CLLocation?

    override public init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    // MARK: - Authorization

    public var authorization: LocationAuthorization {
        LocationAuthorization(manager.authorizationStatus)
    }

    /// Asks for When-In-Use if it has never been asked. Fire-and-forget: the
    /// prompt is raised alongside the log, never in front of it.
    public func requestAuthorizationIfNeeded() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    // MARK: - Fixes

    /// A cached fix, if one is fresh enough to stamp on a new event.
    public var freshCachedFix: CLLocation? {
        guard let cachedFix,
              Date().timeIntervalSince(cachedFix.timestamp) <= Self.cacheLifetime
        else { return nil }
        return cachedFix
    }

    /// Requests a single fix, resolving to `nil` on timeout, denial, or error.
    /// Never throws and never blocks the caller's write path.
    public func oneShotFix(timeout: TimeInterval = WatchLocationProvider.fixTimeout) async -> CLLocation? {
        guard authorization.allowsOneShotFix else { return nil }
        if let freshCachedFix { return freshCachedFix }

        return await withCheckedContinuation { continuation in
            pending.append(continuation)
            if pending.count == 1 {
                manager.requestLocation()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    self?.finish(with: nil)
                }
            }
        }
    }

    /// Resolves every waiter exactly once. Whichever arrives first — the fix or
    /// the timeout — wins, and the loser finds an empty queue.
    private func finish(with location: CLLocation?) {
        guard !pending.isEmpty else { return }
        if let location { cachedFix = location }
        let waiting = pending
        pending.removeAll()
        for continuation in waiting {
            continuation.resume(returning: location)
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension WatchLocationProvider: CLLocationManagerDelegate {

    // CoreLocation delivers on the queue the manager was created on — the main
    // queue here — so `assumeIsolated` is accurate rather than optimistic.

    nonisolated public func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        MainActor.assumeIsolated {
            let usable = locations.last.flatMap { location -> CLLocation? in
                guard location.horizontalAccuracy >= 0,
                      location.horizontalAccuracy <= Self.maximumAcceptableAccuracy
                else { return nil }
                return location
            }
            self.finish(with: usable)
        }
    }

    nonisolated public func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: any Error
    ) {
        MainActor.assumeIsolated {
            self.finish(with: nil)
        }
    }
}
