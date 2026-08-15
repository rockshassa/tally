import Foundation
import SwiftData

// MARK: - CloudKit mode

/// Whether the store syncs, and to which container.
///
/// SPEC §8: shipping sync is a switch-flip because §1's rules were followed from
/// the start. Wave 2 changes exactly one value — `TallyStore.cloudKitMode` — and
/// nothing else in this file.
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

    /// The CloudKit container that Wave 2 (SPEC §8) will point the store at.
    public static let cloudKitContainerIdentifier = "iCloud.devplaceholder.B13UVL67.tally"

    /// ⬇︎ THE SYNC SWITCH (SPEC §8 / PLAN Wave 2). ⬇︎
    ///
    /// Flipping this single value to
    /// `.privateDatabase(containerIdentifier: cloudKitContainerIdentifier)`
    /// turns on iCloud sync for every target. Nothing else in TallyKit needs to
    /// change — the schema has been CloudKit-legal since day one.
    public static let cloudKitMode: CloudKitMode = .disabled

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
