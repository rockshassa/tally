import Foundation
import Observation
import SwiftData
import TallyKit

/// The user's iCloud-sync choice, and everything the Settings row needs to
/// describe it (SPEC §8, §9).
///
/// **Where the bit lives:** `TallyStore.syncPreferenceKey` in the App Group
/// `UserDefaults` suite, which is the same key `TallyStore.resolvedCloudKitMode()`
/// reads when it builds the container. There is deliberately one key and one
/// reader — the store decides, this class only writes the user's answer and
/// explains the outcome.
///
/// **When a change takes effect:** the next launch. SwiftData decides
/// `cloudKitDatabase` when the `ModelContainer` is created, which happens once
/// in `TallyApp.init`; rebuilding it live would mean swapping the container out
/// from under every live `@Query` in the app. The toggle's footer says so, and
/// `requiresRelaunch` drives an inline note once the user flips it.
///
/// **Signed out is not an error.** SPEC §8: "the app remains fully functional
/// signed-out." With no iCloud account the store is local, the toggle is
/// disabled, and nothing else changes.
@MainActor
@Observable
public final class SyncSettings {

    // MARK: Shared instance

    /// One instance per process: the Settings row and `SyncCoordinator` have to
    /// agree about the last remote change, and two would drift.
    public static let shared = SyncSettings()

    // MARK: Status

    public enum Status: Equatable, Sendable {

        /// Sync is on and running. `lastChange` is the last time CloudKit
        /// handed us someone else's write — `nil` until the first one lands.
        case on(lastChange: Date?)

        /// Turned off in Settings.
        case off

        /// No iCloud account on this device. The toggle is inert here.
        case noAccount

        /// Flipped, but the container this launch built is still the old one.
        case pendingRelaunch(willBeOn: Bool)
    }

    // MARK: Stored state

    /// The user's answer. Absent from defaults until they touch the toggle, in
    /// which case this reflects the SPEC §8 default: on when signed in.
    public var isOn: Bool {
        didSet {
            // Always write, even when the value matches: an explicit choice that
            // equals the current *default* must still be persisted, or the store
            // falls back to the account default and ignores the user (SPEC §8).
            defaults.set(isOn, forKey: TallyStore.syncPreferenceKey)
        }
    }

    /// Whether this device is signed in to iCloud.
    public private(set) var hasAccount: Bool

    /// Last `NSPersistentStoreRemoteChange` — i.e. the last time another device's
    /// write arrived. Persisted so the status line survives a relaunch.
    public private(set) var lastRemoteChange: Date?

    // MARK: Dependencies

    private let defaults: UserDefaults
    private let accountObserver = NotificationObserverToken()

    private static let lastRemoteChangeKey = "tally.sync.lastRemoteChange"

    public init(defaults: UserDefaults? = UserDefaults(suiteName: TallyStore.appGroupIdentifier)) {
        let store = defaults ?? .standard
        self.defaults = store
        self.hasAccount = TallyStore.hasICloudAccount
        self.isOn = store.object(forKey: TallyStore.syncPreferenceKey) as? Bool
            ?? TallyStore.hasICloudAccount
        self.lastRemoteChange = store.object(forKey: Self.lastRemoteChangeKey) as? Date

        // Signing in or out of iCloud mid-session changes the answer, and the
        // status line should not lie until the next launch.
        accountObserver.value = NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAccount() }
        }
    }

    // MARK: Derived

    /// What the container *this launch* was actually built with.
    public var activeMode: CloudKitMode {
        TallyRuntime.storeConfiguration.cloudKit
    }

    /// What the next launch will build, given the current preference.
    public var resolvedMode: CloudKitMode {
        TallyStore.cloudKitMode
    }

    /// The toggle has been moved but the store has not caught up.
    public var requiresRelaunch: Bool {
        resolvedMode.isEnabled != activeMode.isEnabled
    }

    public var status: Status {
        guard hasAccount else { return .noAccount }
        if requiresRelaunch { return .pendingRelaunch(willBeOn: resolvedMode.isEnabled) }
        guard activeMode.isEnabled else { return .off }
        return .on(lastChange: lastRemoteChange)
    }

    /// The one-line status SPEC §9 asks for under the toggle.
    public var statusLine: String {
        switch status {
        case .noAccount:
            return "No iCloud account"
        case .off:
            return "Off"
        case .pendingRelaunch(let willBeOn):
            return willBeOn
                ? "On the next time you open Tally"
                : "Off the next time you open Tally"
        case .on(let lastChange):
            guard let lastChange else { return "On · waiting for first sync" }
            return "On · last change \(Self.relativeFormatter.localizedString(for: lastChange, relativeTo: Date()))"
        }
    }

    /// Footer copy. Kept here rather than in the view so the "next launch" caveat
    /// has exactly one wording.
    public var footerText: String {
        hasAccount
            ? "Your drinks sync through your private iCloud database — never a shared or public one, and never to us. Changes take effect the next time you open Tally."
            : "Sign in to iCloud in the Settings app to sync your drinks between devices. Tally works exactly the same without it."
    }

    /// Whether the toggle should accept taps at all.
    public var isToggleEnabled: Bool { hasAccount }

    // MARK: Mutation

    public func refreshAccount() {
        hasAccount = TallyStore.hasICloudAccount
    }

    /// Called by `SyncCoordinator` every time CloudKit hands us a remote write.
    public func recordRemoteChange(at date: Date = Date()) {
        lastRemoteChange = date
        defaults.set(date, forKey: Self.lastRemoteChangeKey)
    }

    /// Erase-all (SPEC §9) clears the sync bookkeeping too, so a wiped app does
    /// not claim it synced something a moment ago.
    public func clearSyncHistory() {
        lastRemoteChange = nil
        defaults.removeObject(forKey: Self.lastRemoteChangeKey)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// Holds a `NotificationCenter` observer token outside its owner's actor.
///
/// A `@MainActor` class cannot touch its own isolated properties from `deinit`,
/// so the token lives here and this object's own deallocation unregisters it —
/// which happens exactly when the owner is deallocated.
final class NotificationObserverToken: @unchecked Sendable {

    var value: (any NSObjectProtocol)?

    func clear() {
        guard let value else { return }
        NotificationCenter.default.removeObserver(value)
        self.value = nil
    }

    deinit { clear() }
}
