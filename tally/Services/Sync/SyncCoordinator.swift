import CoreData
import Foundation
import Observation
import SwiftData
import SwiftUI
import TallyKit

/// Runs the SPEC §1/§8 merge passes at the two moments they matter: once at
/// launch, and after CloudKit imports someone else's writes.
///
/// **Why debounced.** A single sync of a night out arrives as a burst — one
/// `NSPersistentStoreRemoteChange` per imported batch, several a second. The
/// merge is idempotent so running it per notification would be *correct*, just
/// wasteful, and it would fight the import for the main context. One pass a
/// couple of seconds after the burst goes quiet is enough, and a late duplicate
/// simply triggers another pass.
///
/// **Why the phone only.** `SyncMergeService` deletes rows; those deletions sync
/// like everything else, so one device doing the work fixes every device. The
/// watch app never starts a coordinator.
@MainActor
@Observable
public final class SyncCoordinator {

    /// One per process — two coordinators would mean two observers racing to
    /// collapse the same duplicate pair.
    public static let shared = SyncCoordinator()

    /// Long enough to let an import burst finish, short enough that a duplicate
    /// venue never survives long enough to be seen in History.
    public static let debounceInterval: Duration = .seconds(2)

    // MARK: State

    /// Result of the most recent pass that actually changed something. Purely
    /// diagnostic — nothing in the UI depends on it.
    public private(set) var lastReport: SyncMergeService.Report?

    public private(set) var lastRunDate: Date?

    public private(set) var isStarted = false

    // MARK: Dependencies

    private let settings: SyncSettings
    private var container: ModelContainer?
    private let remoteChangeObserver = NotificationObserverToken()
    private var debounceTask: Task<Void, Never>?

    public init(settings: SyncSettings = .shared) {
        self.settings = settings
    }

    // MARK: Lifecycle

    /// Idempotent. Safe to call from several places — the Settings section calls
    /// it too, so the merge passes run even if the app entry point never does.
    ///
    /// - Parameter container: defaults to the process's shared container. Pass
    ///   one explicitly in previews and tests.
    public func start(container providedContainer: ModelContainer? = nil) {
        guard !isStarted else { return }

        guard let resolved = providedContainer ?? (try? TallyRuntime.container()) else { return }
        container = resolved
        isStarted = true

        remoteChangeObserver.value = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.remoteChangeArrived() }
        }

        // The launch pass. Catches everything that synced while the app was
        // closed, which is most of it.
        mergeNow()
    }

    /// Tears the observer down. Erase-all (SPEC §9) uses this before it drops
    /// the container, so a merge cannot fire against a store being wiped.
    public func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        remoteChangeObserver.clear()
        container = nil
        isStarted = false
    }

    // MARK: Merge

    private func remoteChangeArrived() {
        // The status line's "last change" is the notification itself, not the
        // merge — it is answering "when did another device last touch this?".
        settings.recordRemoteChange()

        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: SyncCoordinator.debounceInterval)
            guard !Task.isCancelled else { return }
            self?.mergeNow()
        }
    }

    /// Runs both merge passes right now. Public so erase-all, tests, and a
    /// pull-to-refresh can force one.
    public func mergeNow() {
        guard let container else { return }
        lastRunDate = Date()

        do {
            let report = try SyncMergeService.run(in: container.mainContext)
            if !report.isEmpty { lastReport = report }
        } catch {
            // A failed merge is not a failed app: the duplicates stay visible
            // and the next remote change tries again.
            lastReport = nil
        }
    }
}

// MARK: - Host hook

/// The one line the integrator adds to `TallyApp`'s scene:
/// `.tallySyncCoordination()`.
///
/// Kept as a modifier rather than a call in `TallyApp.init` because the merge
/// wants a live container and the main actor, both of which the scene has.
/// `SyncSettingsSection` starts the coordinator too, so sync still self-heals if
/// this line is never added — it just waits until the user opens Settings.
public struct SyncCoordinationModifier: ViewModifier {

    private let coordinator: SyncCoordinator

    public init(coordinator: SyncCoordinator = .shared) {
        self.coordinator = coordinator
    }

    public func body(content: Content) -> some View {
        content.task { coordinator.start() }
    }
}

public extension View {
    /// Starts the SPEC §1/§8 post-sync merge passes for this process.
    func tallySyncCoordination(coordinator: SyncCoordinator = .shared) -> some View {
        modifier(SyncCoordinationModifier(coordinator: coordinator))
    }
}
