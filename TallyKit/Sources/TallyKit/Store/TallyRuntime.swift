import Foundation
import SwiftData

/// Process-wide access to the shared store.
///
/// Each executable configures this once at launch — the app with `.app`, the
/// widget extension with `.widget`, the watch app with `.watch` — and everything
/// else (notably `LogDrinkIntent`, which runs in all three) reads it. The
/// container is created lazily so a missing App Group entitlement surfaces at
/// first use rather than at launch.
public enum TallyRuntime {

    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var container: ModelContainer?
        var configuration: StoreConfiguration = .default
        var eventSource: EventSource = .app
    }

    private static let box = Box()

    /// Call once from each target's entry point.
    ///
    /// - Parameters:
    ///   - eventSource: stamped onto every event this process logs (SPEC §1).
    ///   - storeConfiguration: which store to open. The watch passes `.local`
    ///     (SPEC §7: its own store, identical schema).
    ///   - container: inject a pre-built container (tests, previews).
    public static func configure(
        eventSource: EventSource = .app,
        storeConfiguration: StoreConfiguration = .default,
        container: ModelContainer? = nil
    ) {
        box.lock.lock()
        defer { box.lock.unlock() }
        box.eventSource = eventSource
        box.configuration = storeConfiguration
        box.container = container
    }

    /// The source stamped on events logged by this process.
    public static var eventSource: EventSource {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.eventSource
    }

    public static var storeConfiguration: StoreConfiguration {
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.configuration
    }

    /// The shared container, created on first use and cached thereafter.
    public static func container() throws -> ModelContainer {
        box.lock.lock()
        defer { box.lock.unlock() }
        if let existing = box.container { return existing }
        let created = try TallyStore.makeContainer(box.configuration)
        box.container = created
        return created
    }

    /// Drops the cached container. Used by erase-all (SPEC §9) and by tests.
    public static func reset() {
        box.lock.lock()
        defer { box.lock.unlock() }
        box.container = nil
    }
}
