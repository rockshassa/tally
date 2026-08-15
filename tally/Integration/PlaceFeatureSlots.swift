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
        self.coordinator = PlaceCoordinator(modelContext: container.mainContext)
        self.permissions = permissions
    }

    /// SPEC §2: runs the inference pipeline (saved venues → POI lookup) and
    /// returns a check-in sheet only for a single confident candidate that the
    /// Session hasn't already answered.
    func checkInSheet(for context: CheckInContext) async -> AnyView? {
        await coordinator.attachPlace(toEventWith: context.eventID)
        guard let pending = coordinator.pendingCheckIn else { return nil }
        return AnyView(CheckInSheet(context: pending, coordinator: coordinator))
    }

    func historyDestination() -> AnyView {
        AnyView(HistoryView(permissions: permissions))
    }

    func onboardingHomeSetup(onDone: @escaping () -> Void) -> AnyView {
        AnyView(HomeSetupView(onSave: { _ in onDone() }, onSkip: { onDone() }))
    }
}
