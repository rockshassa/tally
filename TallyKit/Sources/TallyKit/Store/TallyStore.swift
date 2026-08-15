import Foundation
import SwiftData

// MARK: - CloudKit mode

/// Whether the store syncs, and to which container.
///
/// SPEC §8: shipping sync is a switch-flip because §1's rules were followed from
/// the start. Wave 2 changed exactly one value — `TallyStore.cloudKitMode` —
/// from a hardcoded `.disabled` into a resolved one, and nothing else about the
/// schema, the models, or the container factory.
public enum CloudKitMode: Hashable, Sendable {

    /// Local-only store. `cloudKitDatabase: .none`.
    case disabled

    /// The user's private CloudKit database. Never shared, never public (SPEC §8, §10).
    case privateDatabase(containerIdentifier: String)

    var modelConfigurationValue: ModelConfiguration.CloudKitDatabase {
        switch self {
        case .disabled:
            return .none
        case .privateDatabase(let identifier):
            return .private(identifier)
        }
    }

    public var isEnabled: Bool { self != .disabled }
}

// MARK: - Store configuration

public struct StoreConfiguration: Hashable, Sendable {

    /// Name of the store file inside its container.
    public var name: String

    /// App Group the store lives in, shared by app + widget (SPEC §1).
    /// `nil` uses the process's own container — used by the watch app's
    /// standalone store and by previews.
    public var appGroupIdentifier: String?

    public var cloudKit: CloudKitMode

    public var isStoredInMemoryOnly: Bool

    public var allowsSave: Bool

    public init(
        name: String = "Tally",
        appGroupIdentifier: String? = TallyStore.appGroupIdentifier,
        cloudKit: CloudKitMode = TallyStore.cloudKitMode,
        isStoredInMemoryOnly: Bool = false,
        allowsSave: Bool = true
    ) {
        self.name = name
        self.appGroupIdentifier = appGroupIdentifier
        self.cloudKit = cloudKit
        self.isStoredInMemoryOnly = isStoredInMemoryOnly
        self.allowsSave = allowsSave
    }

    /// The shared App Group store used by the iOS app and its widget extension.
    public static let `default` = StoreConfiguration()

    /// A process-local store (no App Group). The watch app uses this: SPEC §7
    /// gives it its own store with the identical schema.
    public static let local = StoreConfiguration(appGroupIdentifier: nil)

    /// Throwaway store for tests and SwiftUI previews.
    public static let inMemory = StoreConfiguration(
        appGroupIdentifier: nil,
        cloudKit: .disabled,
        isStoredInMemoryOnly: true
    )
}

// MARK: - Store factory

/// Builds the shared `ModelContainer` (SPEC §1: SwiftData in an App Group container).
public enum TallyStore {

    // MARK: Identifiers

    /// App Group shared by the app, the widget extension, and the watch app.
    /// Derived from the app bundle identifier `devplaceholder.B13UVL67.tally`.
    /// Mirrored literally in `Entitlements/*.entitlements` — change both together.
    public static let appGroupIdentifier = "group.devplaceholder.B13UVL67.tally"

    /// The CloudKit container the store's private database lives in (SPEC §8).
    /// Mirrored literally in `Entitlements/tally.entitlements` and
    /// `Entitlements/TallyWatch.entitlements` — change all three together.
    public static let cloudKitContainerIdentifier = "iCloud.devplaceholder.B13UVL67.tally"

    // MARK: - The sync switch (SPEC §8 / PLAN Wave 2)

    /// Where the user's iCloud-sync choice lives, in the App Group suite so the
    /// app and its extensions read one answer (SPEC §8 / §9 Settings).
    ///
    /// **Absent means "never chosen"**, which resolves to *on* — SPEC §8: "on by
    /// default when an iCloud account is present". Only an explicit `false`
    /// turns sync off.
    public static let syncPreferenceKey = "tally.sync.iCloudEnabled"

    /// True when this device is signed in to iCloud right now.
    ///
    /// The store never asks CloudKit for an account: a signed-out device gets a
    /// local store and a fully functional app (SPEC §8), not an error.
    public static var hasICloudAccount: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// Only the containing apps mirror to CloudKit; app extensions read the
    /// shared App Group store instead.
    ///
    /// The widget deliberately carries no CloudKit entitlement (it logs into the
    /// same App Group file and the app exports its history on next launch), so
    /// asking for a CloudKit-backed container in that process would fail for a
    /// missing entitlement rather than sync anything.
    public static var processMirrorsToCloudKit: Bool {
        Bundle.main.bundleURL.pathExtension != "appex"
    }

    /// Forces a mode for this process, ignoring the persisted preference.
    /// `nil` — the default — resolves normally. For tests and previews.
    public static var cloudKitModeOverride: CloudKitMode? {
        get { syncSwitch.withLock { $0 } }
        set { syncSwitch.withLock { $0 = newValue } }
    }

    /// ⬇︎ THE SYNC SWITCH (SPEC §8 / PLAN Wave 2). ⬇︎
    ///
    /// Wave 2 turned this from a hardcoded `.disabled` into a resolved value —
    /// the *only* TallyKit change sync needed, because the schema has been
    /// CloudKit-legal since day one.
    ///
    /// Read once per process, when `StoreConfiguration.default` is first built:
    /// the container is created at launch, so **flipping the Settings toggle
    /// takes effect at the next launch**, and the UI says so.
    public static var cloudKitMode: CloudKitMode {
        cloudKitModeOverride ?? resolvedCloudKitMode()
    }

    /// `cloudKitMode` without the override, with every input injectable so the
    /// decision table can be tested without a signed-in device.
    public static func resolvedCloudKitMode(
        defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier),
        accountIsAvailable: Bool = hasICloudAccount,
        processMirrors: Bool = processMirrorsToCloudKit
    ) -> CloudKitMode {

        let enabled = CloudKitMode.privateDatabase(containerIdentifier: cloudKitContainerIdentifier)

        // An extension never owns the mirror.
        guard processMirrors else { return .disabled }

        // An explicit choice in Settings wins outright — including turning sync
        // *on* when `ubiquityIdentityToken` is unreadable but the account is
        // really there, which is the one case a pure account check gets wrong.
        let store = defaults ?? .standard
        if store.object(forKey: syncPreferenceKey) != nil {
            return store.bool(forKey: syncPreferenceKey) ? enabled : .disabled
        }

        // Never chosen: on by default when signed in, local when signed out —
        // and signed out is a fully functional app, not an error (SPEC §8).
        return accountIsAvailable ? enabled : .disabled
    }

    /// Box for `cloudKitModeOverride` — a plain `static var` would not be
    /// concurrency-safe under this package's Swift 6 language mode.
    private final class SyncSwitchBox: @unchecked Sendable {
        let lock = NSLock()
        var value: CloudKitMode?

        func withLock<T>(_ body: (inout CloudKitMode?) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    private static let syncSwitch = SyncSwitchBox()

    // MARK: Schema

    /// Every persisted type, in a fixed order so the schema hash is stable.
    public static let models: [any PersistentModel.Type] = [
        DrinkEvent.self,
        Venue.self,
        Session.self,
        SuppressedPlace.self
    ]

    public static func makeSchema() -> Schema {
        Schema(models)
    }

    // MARK: Containers

    public enum StoreError: Error, CustomStringConvertible {
        case appGroupUnavailable(String)

        public var description: String {
            switch self {
            case .appGroupUnavailable(let identifier):
                return "App Group container \"\(identifier)\" is unavailable. "
                    + "Check the App Groups entitlement on this target."
            }
        }
    }

    /// Creates a container for the given configuration.
    ///
    /// - Throws: `StoreError.appGroupUnavailable` if an App Group was requested
    ///   but the entitlement is missing, and whatever `ModelContainer` throws.
    public static func makeContainer(_ configuration: StoreConfiguration = .default) throws -> ModelContainer {
        let schema = makeSchema()
        let modelConfiguration: ModelConfiguration

        if configuration.isStoredInMemoryOnly {
            modelConfiguration = ModelConfiguration(
                configuration.name,
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: configuration.allowsSave,
                groupContainer: .none,
                cloudKitDatabase: .none
            )
        } else {
            let groupContainer: ModelConfiguration.GroupContainer
            if let identifier = configuration.appGroupIdentifier {
                try validateAppGroup(identifier)
                groupContainer = .identifier(identifier)
            } else {
                groupContainer = .none
            }

            modelConfiguration = ModelConfiguration(
                configuration.name,
                schema: schema,
                isStoredInMemoryOnly: false,
                allowsSave: configuration.allowsSave,
                groupContainer: groupContainer,
                cloudKitDatabase: configuration.cloudKit.modelConfigurationValue
            )
        }

        return try ModelContainer(for: schema, configurations: [modelConfiguration])
    }

    /// Throwaway in-memory container for tests and previews.
    public static func makeInMemoryContainer() throws -> ModelContainer {
        try makeContainer(.inMemory)
    }

    // MARK: Locations

    /// Root directory of the App Group container, if the entitlement is present.
    /// Used by export and erase-all (SPEC §9), not by the container factory.
    public static func appGroupContainerURL(_ identifier: String = appGroupIdentifier) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    private static func validateAppGroup(_ identifier: String) throws {
        guard appGroupContainerURL(identifier) != nil else {
            throw StoreError.appGroupUnavailable(identifier)
        }
    }
}
