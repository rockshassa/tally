import SwiftData
import SwiftUI
import TallyKit

/// The iOS app entry point.
///
/// Three things happen here and nowhere else:
/// * `TallyRuntime` is configured with `source = .app` and the shared App Group
///   store, so `LogDrinkIntent` — which runs in the app, the widget, and the
///   watch — stamps and writes the right thing in this process (SPEC §1, §6);
/// * that store's `ModelContainer` is injected into the scene, which is what
///   makes `@Query` live on every screen;
/// * the feature slots get wired (see below), which is the one line the
///   integrator adds when the `place` workstream lands.
@main
struct TallyApp: App {

    private let container: ModelContainer

    /// One live service for the whole app — it owns a `CLLocationManager`, so
    /// making a second one would mean a second authorization delegate.
    private let permissions: any PermissionsService = LivePermissionsService()

    private let slots: PlaceFeatureSlots

    init() {
        OnboardingState.applyLaunchArgumentOverrides()
        TallyRuntime.configure(
            eventSource: .app,
            storeConfiguration: LaunchArguments.storeConfiguration
        )
        container = Self.openStore()
        slots = PlaceFeatureSlots(container: container, permissions: permissions)
        PhoneConnectivityService.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(permissions: permissions)
                .modelContainer(container)
                .featureSlots(slots)
                .venueReconciliation()
                .preferredColorScheme(.dark)
                .tint(TallyColor.amberBright)
        }
    }

    /// Opens the shared store, degrading rather than crashing.
    ///
    /// A missing App Group entitlement is a build-configuration problem, not a
    /// reason the user cannot count drinks tonight — so we fall back to a
    /// process-local store and, failing that, to memory.
    private static func openStore() -> ModelContainer {
        do {
            return try TallyRuntime.container()
        } catch {
            TallyRuntime.reset()
            TallyRuntime.configure(eventSource: .app, storeConfiguration: .local)
            if let local = try? TallyRuntime.container() { return local }

            TallyRuntime.reset()
            TallyRuntime.configure(eventSource: .app, storeConfiguration: .inMemory)
            guard let memory = try? TallyRuntime.container() else {
                fatalError("Tally could not open any store: \(error)")
            }
            return memory
        }
    }
}
