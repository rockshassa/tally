import SwiftData
import SwiftUI
import TallyKit

/// Gate 1 integration: fills the shell's `FeatureSlots` with the `place`
/// workstream's screens. The shell never imports Place types directly and
/// Place never touches the shell — this adapter is the only point of contact.
@MainActor
final class PlaceFeatureSlots: FeatureSlots {

    private let coordinator: PlaceCoordinator
    private let permissions: any PermissionsService

    init(container: ModelContainer, permissions: any PermissionsService) {
        let coordinator = PlaceCoordinator(modelContext: container.mainContext)

        // "Start a Session?" answered in the picker logs the first drink — through
        // the same path the +1 button takes, so the watch mirror, the pacing
        // nudge, and Bar Radar's dwell reminder all hear about it.
        coordinator.firstDrinkLogger = { venue, context in
            guard let snapshot = try? PhoneConnectivityService.shared.logDrink(
                type: .alcoholic,
                timestamp: Date(),
                source: TallyRuntime.eventSource,
                venue: venue,
                in: context
            ) else { return nil }
            NotificationService.shared.sessionDidLogDrink(type: .alcoholic, in: context, at: snapshot.timestamp)
            RadarService.shared.sessionDidLogDrink(at: snapshot.timestamp)
            return snapshot.id
        }
        self.coordinator = coordinator
        self.permissions = permissions

        // SPEC §2: a Bar Radar notification tap-through opens the check-in
        // picker, and the handler that receives it has no view — and therefore
        // no coordinator — to ask. Publishing this instance is what lets
        // `PlaceCoordinator.presentPickerForCurrentFix()` resolve against the
        // same pipeline state (and the same `CheckInMemory`) the sheet uses.
        PlaceCoordinator.registerShared(coordinator)
    }

    /// SPEC §2: runs the inference pipeline (saved venues → POI lookup) and
    /// returns a check-in sheet only for a single confident candidate that the
    /// Session hasn't already answered.
    func checkInSheet(for context: CheckInContext) async -> AnyView? {
        await coordinator.attachPlace(toEventWith: context.eventID)
        guard let pending = coordinator.pendingCheckIn else { return nil }
        return AnyView(SelfDismissingCheckIn(prompt: pending, coordinator: coordinator))
    }

    func historyDestination() -> AnyView {
        AnyView(HistoryView(permissions: permissions))
    }

    func onboardingHomeSetup(onDone: @escaping () -> Void) -> AnyView {
        AnyView(HomeSetupView(onSave: { _ in onDone() }, onSkip: { onDone() }))
    }

    /// SPEC §1: the live Session card's tap. The coordinator publishes the
    /// request; the `.checkInPicker()` host at the app's root presents it.
    func assignVenue(toSessionWith id: UUID) {
        coordinator.presentPicker(forSessionWith: id)
    }
}

/// The slot contract (`FeatureSlots.checkInSheet`) says the returned view
/// dismisses itself — the shell presents it from its own `@State` and never
/// peeks inside. `CheckInSheet` signals through `onFinish`; this wrapper turns
/// that into the environment's dismiss action.
private struct SelfDismissingCheckIn: View {

    let prompt: CheckInPrompt
    let coordinator: PlaceCoordinator

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CheckInSheet(context: prompt, coordinator: coordinator, onFinish: { dismiss() })
    }
}

// MARK: - Bar Radar tap-through (SPEC §2)

extension PlaceCoordinator {

    /// Bridges Radar's suggestion vocabulary to the picker's, so neither module
    /// has to know the other's types. Wired once in `TallyApp`.
    @MainActor
    static func present(suggestion: CheckInPickerSuggestion?) {
        switch suggestion {
        case .venue(let id):
            presentPickerForCurrentFix(suggestingVenueWith: id)
        case .place(let place):
            presentPickerForCurrentFix(suggesting: place.candidate)
        case nil:
            presentPickerForCurrentFix()
        }
    }
}
