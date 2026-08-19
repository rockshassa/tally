import AppIntents
import Foundation
import SwiftData

#if canImport(WidgetKit)
import WidgetKit
#endif

/// Undo from the widget (SPEC §1 semantics, SPEC §6 surface): removes the most
/// recent drink of the chosen type *today*, without opening the app. No-ops at
/// zero, exactly like the in-app undo.
///
/// The wrinkle is the watch. An in-app undo mirrors a tombstone over
/// WatchConnectivity immediately, but this intent can run in the widget
/// extension, which has no `WCSession`. So the tombstone is parked in
/// `PendingTombstoneQueue` (App Group), and the app drains it to the watch on
/// next activation — the same eventual-consistency window widget *logs* already
/// have.
public struct UndoDrinkIntent: AppIntent {

    public static let title: LocalizedStringResource = "Undo last drink"
    public static let description = IntentDescription(
        "Removes the most recent drink of this type logged today."
    )
    public static let openAppWhenRun = false

    @Parameter(title: "Drink", default: DrinkType.alcoholic)
    public var drink: DrinkType

    public init() {}

    public init(drink: DrinkType) {
        self.init()
        self.drink = drink
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let container: ModelContainer
        do {
            container = try TallyRuntime.container()
        } catch {
            throw TallyIntentError.storeUnavailable
        }

        let context = ModelContext(container)

        // Capture the victim's UUID before the delete — the tombstone needs it,
        // and `undoMostRecent` intentionally returns only whether it acted.
        let today = try EventStore.events(onDayContaining: Date(), in: context)
        guard let victim = today.last(where: { $0.type == drink }) else {
            return .result(dialog: "Nothing to undo today.")
        }
        let tombstone = DrinkEventTombstone(id: victim.id)

        guard try EventStore.undoMostRecent(type: drink, in: context) else {
            return .result(dialog: "Nothing to undo today.")
        }

        PendingTombstoneQueue.append(tombstone)

        let dialog: IntentDialog = drink == .alcoholic
            ? "Removed the last drink."
            : "Removed the last non-alcoholic drink."
        return .result(dialog: dialog)
    }
}

// MARK: - Cross-process tombstone hand-off

/// Tombstones written by a process that cannot reach the watch (the widget
/// extension), parked in App Group defaults for the app to mirror on next
/// activation. Append-only from writers; the app drains atomically.
public enum PendingTombstoneQueue {

    public static let storageKey = "tally.sync.pendingTombstones.v1"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: TallyStore.appGroupIdentifier)
    }

    public static func append(_ tombstone: DrinkEventTombstone) {
        guard let defaults else { return }
        var queue = load(from: defaults)
        queue.append(tombstone)
        if let data = try? JSONEncoder().encode(queue) {
            defaults.set(data, forKey: storageKey)
        }
    }

    /// Returns everything queued and clears the queue.
    public static func drain() -> [DrinkEventTombstone] {
        guard let defaults else { return [] }
        let queue = load(from: defaults)
        if !queue.isEmpty { defaults.removeObject(forKey: storageKey) }
        return queue
    }

    private static func load(from defaults: UserDefaults) -> [DrinkEventTombstone] {
        guard let data = defaults.data(forKey: storageKey),
              let queue = try? JSONDecoder().decode([DrinkEventTombstone].self, from: data)
        else { return [] }
        return queue
    }
}
