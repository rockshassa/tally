import Observation
import SwiftData
import SwiftUI
import TallyKit

// MARK: - Explainer

/// The two-tier explainer request (SPEC §2, §9).
public struct RadarExplainerRequest: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public init() {}
}

/// SPEC §9: "Location Always — asked when: flipping on Bar Radar. Primer: the
/// two-tier explainer (§2) before the system upgrade prompt. If declined: Bar
/// Radar stays off; nothing else changes."
///
/// Built on `PermissionPrimer` for the same reason every other ask is: iOS shows
/// each system dialog exactly once, and that component is where the guarantee
/// lives that "Not now" is always present and never harder to hit than the grant.
struct BarRadarExplainerView: View {

    let onGrant: () async -> Void
    let onDecline: () -> Void

    var body: some View {
        ZStack {
            TallyColor.pageGradient.ignoresSafeArea()
            PermissionPrimer(
                identifierPrefix: RadarCopy.Explainer.identifierPrefix,
                symbolName: RadarCopy.Explainer.symbolName,
                title: RadarCopy.Explainer.title,
                message: RadarCopy.Explainer.message,
                bullets: RadarCopy.Explainer.bullets,
                grantTitle: RadarCopy.Explainer.grantTitle,
                notNowTitle: RadarCopy.Explainer.notNowTitle,
                footnote: RadarCopy.Explainer.footnote,
                grant: { await onGrant() },
                notNow: { onDecline() }
            )
        }
        .presentationBackground(TallyColor.background)
    }
}

// MARK: - Coordinator

/// Watches the Bar Radar toggle and keeps the world consistent with it.
///
/// Three jobs, and nothing else:
/// 1. **On** with Always → start both tiers.
/// 2. **On** without Always → run the SPEC §9 upgrade flow (explainer, then the
///    system prompt), and leave Bar Radar off if it is declined.
/// 3. **Off** → tear every geofence down. SPEC §2: "disabling Bar Radar drops
///    back to When-In-Use."
///
/// The explainer is only presented on the *transition* into "on". A sheet thrown
/// at someone the moment they open the app would be exactly the "interrupting
/// popup" SPEC §9 rules out — if the permission was revoked in Settings, the Bar
/// Radar section's own status row is where that gets said.
@MainActor
@Observable
public final class RadarCoordinator {

    public static let shared = RadarCoordinator()

    // MARK: State

    /// Non-nil while the two-tier explainer should be on screen.
    public private(set) var explainer: RadarExplainerRequest?

    public private(set) var locationAuthorization: LocationAuthorization = .notDetermined

    public private(set) var isStarted = false

    // MARK: Dependencies

    private let settings: TallySettings
    private let service: RadarService
    private var permissions: (any PermissionsService)?
    private var container: ModelContainer?

    /// Tracks the toggle so a change can be told from a re-read.
    private var lastKnownEnabled: Bool

    public init(settings: TallySettings? = nil, service: RadarService? = nil) {
        let resolvedSettings = settings ?? .shared
        self.settings = resolvedSettings
        self.service = service ?? .shared
        self.lastKnownEnabled = resolvedSettings.barRadarEnabled
    }

    // MARK: Lifecycle

    /// Called once, from the root view modifier.
    ///
    /// - Parameters:
    ///   - permissions: the app's live service. Passing the one `TallyApp`
    ///     already owns matters — a second `LivePermissionsService` means a
    ///     second `CLLocationManager` and a second authorization delegate.
    ///   - container: the app's store.
    public func start(
        permissions: (any PermissionsService)? = nil,
        container: ModelContainer? = nil
    ) async {
        if let permissions { self.permissions = permissions }
        if let container { self.container = container }
        if self.permissions == nil { self.permissions = LivePermissionsService() }

        guard !isStarted else {
            await evaluate(allowExplainer: false)
            return
        }
        isStarted = true

        lastKnownEnabled = settings.barRadarEnabled
        observeSettings()
        await evaluate(allowExplainer: false)
    }

    /// Foreground refresh: authorization can change in Settings while the app is
    /// backgrounded, and the frequented set moves as Sessions accumulate.
    public func applicationDidBecomeActive() async {
        await evaluate(allowExplainer: false)
    }

    // MARK: Evaluation

    private func evaluate(allowExplainer: Bool) async {
        guard let permissions else { return }

        let status = permissions.locationAuthorization()
        locationAuthorization = status

        guard settings.barRadarEnabled else {
            explainer = nil
            await service.stop()
            return
        }

        if status.allowsBarRadar {
            explainer = nil
            await service.start(context: container?.mainContext)
            return
        }

        // On, but the permission is not there.
        guard allowExplainer else { return }

        if status.canPrompt || status == .whenInUse {
            explainer = RadarExplainerRequest()
        } else {
            // Denied or restricted: iOS will not ask again, so a primer would be
            // a button that does nothing. SPEC §9 sends this case to the system
            // Settings deep link on the Bar Radar status row instead.
            settings.barRadarEnabled = false
        }
    }

    // MARK: The upgrade (SPEC §2, §9)

    /// The explainer's grant button. Runs the system prompt and honours whatever
    /// comes back — SPEC §9: "If declined: Bar Radar stays off."
    public func requestAlwaysUpgrade() async {
        guard let permissions else { return }

        let result = await permissions.requestLocationAlways()
        locationAuthorization = result
        explainer = nil

        settings.barRadarEnabled = result.allowsBarRadar
        lastKnownEnabled = result.allowsBarRadar

        await evaluate(allowExplainer: false)
    }

    /// "Not now", or the sheet being swiped away. Same meaning either way.
    ///
    /// Guarded because SwiftUI can call a sheet's setter after the item has
    /// already been cleared — without this, a *successful* grant could be
    /// followed by a spurious decline that turns Bar Radar straight back off.
    public func declineUpgrade() {
        guard explainer != nil else { return }
        explainer = nil
        settings.barRadarEnabled = false
        lastKnownEnabled = false
        Task { await service.stop() }
    }

    // MARK: Settings observation

    /// Re-arms after every change, because `withObservationTracking` fires once.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.barRadarEnabled
            _ = settings.barRadarDiscoveryEnabled
            _ = settings.barRadarDwellMinutes
            _ = settings.sessionReminderMinutes
        } onChange: { [weak self] in
            // `onChange` runs *before* the value lands, so the read has to happen
            // on the next turn of the main actor.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeSettings()
                await self.settingsChanged()
            }
        }
    }

    private func settingsChanged() async {
        let isEnabled = settings.barRadarEnabled
        let turnedOn = isEnabled && !lastKnownEnabled
        lastKnownEnabled = isEnabled

        await evaluate(allowExplainer: turnedOn)

        // Dwell delay and the discovery sub-toggle are read on every use, but the
        // visit monitor's on/off state is not — a refresh applies it.
        if isEnabled, locationAuthorization.allowsBarRadar {
            await service.refresh()
        }
    }
}

// MARK: - Host hook

/// The one line the integrator adds to `TallyApp`'s scene:
/// `.barRadarCoordination(permissions: permissions)`.
///
/// A modifier rather than a call in `TallyApp.init` because the coordinator
/// needs a live container, the main actor, and somewhere to present a sheet —
/// all of which the scene has and the initializer does not.
public struct BarRadarCoordinationModifier: ViewModifier {

    private let coordinator: RadarCoordinator
    private let permissions: (any PermissionsService)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    /// Both defaults are resolved in the body rather than the parameter list: a
    /// default argument is evaluated in the *caller's* isolation, and the shared
    /// coordinator is main-actor bound.
    public init(
        coordinator: RadarCoordinator? = nil,
        permissions: (any PermissionsService)? = nil
    ) {
        self.coordinator = coordinator ?? .shared
        self.permissions = permissions
    }

    public func body(content: Content) -> some View {
        content
            .task {
                await coordinator.start(
                    permissions: permissions,
                    container: modelContext.container
                )
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await coordinator.applicationDidBecomeActive() }
            }
            .sheet(
                item: Binding(
                    get: { coordinator.explainer },
                    set: { if $0 == nil { coordinator.declineUpgrade() } }
                )
            ) { _ in
                BarRadarExplainerView(
                    onGrant: { await coordinator.requestAlwaysUpgrade() },
                    onDecline: { coordinator.declineUpgrade() }
                )
            }
    }
}

public extension View {

    /// Starts Bar Radar (SPEC §2) for this process and hosts its Always-location
    /// explainer (SPEC §9).
    ///
    /// - Parameter permissions: pass the app's own `PermissionsService` so this
    ///   does not create a second `CLLocationManager`.
    func barRadarCoordination(
        permissions: (any PermissionsService)? = nil,
        coordinator: RadarCoordinator? = nil
    ) -> some View {
        modifier(BarRadarCoordinationModifier(coordinator: coordinator, permissions: permissions))
    }
}
