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
