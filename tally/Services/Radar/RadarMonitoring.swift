import CoreLocation
import Foundation
import TallyKit

// MARK: - Seams

/// Tier 1's plumbing: circular conditions evaluated by the OS (SPEC §2).
///
/// > The app registers OS geofences (`CLMonitor` circular conditions) for the top
/// > frequented venues by recency … Geofence evaluation is done by the OS
/// > on-device — the app receives entry/exit events only, never a location stream.
///
/// Behind a protocol so every rule that *reacts* to an entry can be exercised
/// from a fixture: `RadarVisitMachine` never learns whether CoreLocation is
/// involved.
@MainActor
public protocol RadarRegionMonitoring: AnyObject {

    /// Begins delivering entry/exit events. Idempotent.
    func start(handler: @escaping @MainActor (RadarRegionEvent) -> Void) async

    /// Makes the monitored set exactly `targets` — adds what is new, removes
    /// what is gone, leaves the rest alone. Removing and re-adding an unchanged
    /// condition would lose its state and re-fire on the next evaluation.
    func sync(targets: [RadarTarget]) async

    /// Stops monitoring and drops every condition. SPEC §2: "disabling Bar Radar
    /// drops back to When-In-Use."
    func stop() async

    func monitoredIdentifiers() async -> [String]
}

/// Tier 2's plumbing: OS visit monitoring (SPEC §2).
@MainActor
public protocol RadarVisitMonitoring: AnyObject {
    func start(handler: @escaping @MainActor (RadarVisitObservation) -> Void)
    func stop()
}

// MARK: - Live region monitor

/// `CLMonitor`, which persists its conditions across launches — that persistence
/// is what lets a geofence entry wake an app that has not been opened in days.
@MainActor
public final class CLMonitorRegionMonitor: RadarRegionMonitoring {

    private var monitor: CLMonitor?
    private var eventsTask: Task<Void, Never>?
    private var handler: (@MainActor (RadarRegionEvent) -> Void)?

    public init() {}

    public func start(handler: @escaping @MainActor (RadarRegionEvent) -> Void) async {
        self.handler = handler
        guard monitor == nil else { return }

        let monitor = await CLMonitor(RadarIdentifiers.monitorName)
        self.monitor = monitor

        eventsTask = Task { [weak self] in
            do {
                let events = await monitor.events
                for try await event in events {
                    self?.deliver(event)
                }
            } catch {
                // The stream ends when monitoring stops or authorization is
                // pulled. Neither is an error the user should ever see.
            }
        }
    }

    private func deliver(_ event: CLMonitor.Event) {
        guard
            let handler,
            let venueID = RadarIdentifiers.venueID(fromCondition: event.identifier)
        else { return }

        switch event.state {
        case .satisfied:
            handler(.entered(venueID: venueID, at: event.date))
        case .unsatisfied:
            handler(.exited(venueID: venueID, at: event.date))
        default:
            // `.unknown` is the state a freshly added condition starts in, and
            // `.unmonitored` means CoreLocation dropped it. Neither is an
            // arrival or a departure.
            break
        }
    }

    public func sync(targets: [RadarTarget]) async {
        guard let monitor else { return }

        let existing = Set(await monitor.identifiers)
        let wanted = Dictionary(uniqueKeysWithValues: targets.map { ($0.monitoringIdentifier, $0) })

        for identifier in existing where wanted[identifier] == nil {
            await monitor.remove(identifier)
        }

        for (identifier, target) in wanted where !existing.contains(identifier) {
            await monitor.add(
                CLMonitor.CircularGeographicCondition(
                    center: target.coordinate,
                    radius: target.radiusMeters
                ),
                identifier: identifier
            )
        }
    }

    public func stop() async {
        eventsTask?.cancel()
        eventsTask = nil
        handler = nil

        if let monitor {
            for identifier in await monitor.identifiers {
                await monitor.remove(identifier)
            }
        }
        monitor = nil
    }

    public func monitoredIdentifiers() async -> [String] {
        guard let monitor else { return [] }
        return await monitor.identifiers
    }
}

// MARK: - Live visit monitor

/// `CLLocationManager.startMonitoringVisits()` — "the low-power service that
/// fires when the system decides you've arrived somewhere and lingered"
/// (SPEC §2).
///
/// Its own manager, deliberately: `LocationService`'s manager exists to take one
/// fix and stop, and giving it a second, long-lived job would make "no
/// continuous tracking" (SPEC §10) something you have to read code to verify.
@MainActor
public final class CLVisitMonitor: NSObject, RadarVisitMonitoring {

    private let manager: CLLocationManager
    private var handler: (@MainActor (RadarVisitObservation) -> Void)?
    private var isMonitoring = false

    public init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        super.init()
        self.manager.delegate = self
    }

    public func start(handler: @escaping @MainActor (RadarVisitObservation) -> Void) {
        self.handler = handler
        guard !isMonitoring else { return }
        isMonitoring = true
        manager.startMonitoringVisits()
    }

    public func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        manager.stopMonitoringVisits()
        handler = nil
    }
}

extension CLVisitMonitor: CLLocationManagerDelegate {

    nonisolated public func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        // The manager was created on the main actor, so CoreLocation delivers
        // here — same contract `LocationService` relies on.
        MainActor.assumeIsolated {
            let observation = RadarVisitObservation(
                latitude: visit.coordinate.latitude,
                longitude: visit.coordinate.longitude,
                horizontalAccuracy: visit.horizontalAccuracy,
                arrivalDate: visit.arrivalDate,
                departureDate: visit.departureDate
            )
            self.handler?(observation)
        }
    }
}

// MARK: - Fixtures

/// Drives Tier 1 without CoreLocation: `send(.entered(…))` is a geofence entry.
@MainActor
public final class MockRadarRegionMonitor: RadarRegionMonitoring {

    public private(set) var targets: [RadarTarget] = []
    public private(set) var isStarted = false
    private var handler: (@MainActor (RadarRegionEvent) -> Void)?

    public init() {}

    public func start(handler: @escaping @MainActor (RadarRegionEvent) -> Void) async {
        self.handler = handler
        isStarted = true
    }

    public func sync(targets: [RadarTarget]) async {
        self.targets = targets
    }

    public func stop() async {
        isStarted = false
        targets = []
        handler = nil
    }

    public func monitoredIdentifiers() async -> [String] {
        targets.map(\.monitoringIdentifier)
    }

    /// Injects an event as though the OS had delivered it.
    public func send(_ event: RadarRegionEvent) {
        handler?(event)
    }
}

/// Drives Tier 2 without CoreLocation.
@MainActor
public final class MockRadarVisitMonitor: RadarVisitMonitoring {

    public private(set) var isStarted = false
    private var handler: (@MainActor (RadarVisitObservation) -> Void)?

    public init() {}

    public func start(handler: @escaping @MainActor (RadarVisitObservation) -> Void) {
        self.handler = handler
        isStarted = true
    }

    public func stop() {
        isStarted = false
        handler = nil
    }

    public func send(_ observation: RadarVisitObservation) {
        handler?(observation)
    }
}
