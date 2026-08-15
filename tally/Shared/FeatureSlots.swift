import SwiftUI
import TallyKit

// MARK: - Slot context

/// Everything a check-in slot needs about the drink that was just logged
/// (SPEC §2 step 3).
///
/// Coordinates are optional on purpose: the one-shot fix is best-effort and the
/// count is never allowed to wait on it (SPEC §1, §2). A context with no
/// coordinates means "we could not place this event" — the slot should return
/// `nil` rather than prompt.
struct CheckInContext: Hashable, Sendable {

    /// The `DrinkEvent.id` that was just written. Re-fetch it with
    /// `EventStore.event(id:in:)` — the user may have undone it already.
    let eventID: UUID

    let drinkType: DrinkType
    let timestamp: Date

    let latitude: Double?
    let longitude: Double?
    let horizontalAccuracy: Double?

    /// The Session this event landed in, if one is active. Lets the slot honour
    /// SPEC §2's "asked once per outing, not per drink".
    let sessionID: UUID?

    init(
        eventID: UUID,
        drinkType: DrinkType,
        timestamp: Date,
        latitude: Double? = nil,
        longitude: Double? = nil,
        horizontalAccuracy: Double? = nil,
        sessionID: UUID? = nil
    ) {
        self.eventID = eventID
        self.drinkType = drinkType
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.sessionID = sessionID
    }

    var hasCoordinates: Bool { latitude != nil && longitude != nil }
}

// MARK: - The seam

/// The three places where the Wave 1 `core-ui` shell hands the screen over to
/// the `place` workstream (PLAN Wave 1 cross-wave seam).
///
/// `core-ui` owns *where* these appear and *when* they are asked for; `place`
/// owns what they contain. Nobody has to edit the other's files — the
/// integrator wires the implementation in at the app entry point:
///
/// ```swift
/// ContentView(permissions: permissions)
///     .featureSlots(PlaceFeatureSlots())
/// ```
///
/// Every requirement has a default, so an unwired app is fully functional:
/// no check-in prompt, placeholder History, skippable Home setup.
@MainActor
protocol FeatureSlots {

    /// Asked once per logged drink, after the one-shot location fix has either
    /// arrived or timed out. Return `nil` — the default — to present nothing.
    ///
    /// `async` so the implementation can run its MapKit POI lookup *before*
    /// anything appears on screen: SPEC §2 wants a non-blocking sheet on a
    /// single confident candidate, not a spinner on every tap. The returned view
    /// is presented as a sheet and should dismiss itself with
    /// `@Environment(\.dismiss)`.
    func checkInSheet(for context: CheckInContext) async -> AnyView?

    /// Pushed onto the Tally tab's navigation stack when the today-count header
    /// is tapped (SPEC §9: History lives behind the today count).
    func historyDestination() -> AnyView

    /// Hosted by onboarding screen 3 (SPEC §9: "Set Home", skippable).
    /// Call `onDone` when the pin is saved *or* skipped — the flow finishes
    /// either way.
    func onboardingHomeSetup(onDone: @escaping () -> Void) -> AnyView
}

extension FeatureSlots {

    func checkInSheet(for context: CheckInContext) async -> AnyView? { nil }

    func historyDestination() -> AnyView {
        AnyView(HistoryPlaceholderView())
    }

    func onboardingHomeSetup(onDone: @escaping () -> Void) -> AnyView {
        AnyView(HomeSetupPlaceholderView(onDone: onDone))
    }
}

/// The unwired shell: every slot takes its default. What the app runs on until
/// the integrator lands `place`.
struct DefaultFeatureSlots: FeatureSlots {
    init() {}
}

// MARK: - Environment plumbing

private struct FeatureSlotsKey: @preconcurrency EnvironmentKey {
    @MainActor static let defaultValue: any FeatureSlots = DefaultFeatureSlots()
}

extension EnvironmentValues {
    var featureSlots: any FeatureSlots {
        get { self[FeatureSlotsKey.self] }
        set { self[FeatureSlotsKey.self] = newValue }
    }
}

extension View {
    /// Registers the real slot implementations. Called once, at the app entry
    /// point, by the integrator.
    func featureSlots(_ slots: any FeatureSlots) -> some View {
        environment(\.featureSlots, slots)
    }
}

// MARK: - Presentation helper

/// Wraps a slot's view so it can drive `.sheet(item:)`.
struct PresentedSlot: Identifiable {
    let id = UUID()
    let content: AnyView
}
