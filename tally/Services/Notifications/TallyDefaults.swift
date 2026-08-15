import Foundation
import TallyKit

/// The one place every configurable default named in SPEC §9 is stored.
///
/// > **Settings** — "Every configurable default named elsewhere in this spec has
/// > exactly one home here."
///
/// That sentence is about the UI, but it only stays true if the *storage* is also
/// singular, so this enum owns the keys and nobody else invents one.
///
/// **Which suite.** Writes go to the App Group suite first — the widget extension
/// and (via WatchConnectivity) the watch read the same numbers, and the App Group
/// is the only container all three processes share (SPEC §1). Every write is
/// mirrored into `UserDefaults.standard` and reads fall back to it, because
/// `@AppStorage` in another feature's view defaults to `.standard`: mirroring
/// means a cross-feature key (the NA-ratio goal, read by the You tab) agrees no
/// matter which suite the reader picked.
public enum TallyDefaults {

    // MARK: - Keys

    /// Key strings are API the moment a second feature reads one — rename with
    /// the same care as a public symbol.
    public enum Keys {

        // Goal — SPEC §3, §9.

        /// NA drinks required per alcoholic drink. Default 1.0 (1:1).
        /// **Shared with the You tab** (`play`): both sides read this exact string.
        public static let ratioGoal = "tally.settings.ratioGoal"

        // Notifications — SPEC §5, §9.

        /// Per-category opt-in. Suffixed with the category's raw value.
        public static let notificationCategoryPrefix = "tally.notifications.category."

        public static let quietHoursEnabled = "tally.notifications.quietHours.enabled"

        /// Minutes from local midnight.
        public static let quietHoursStartMinutes = "tally.notifications.quietHours.startMinutes"
        public static let quietHoursEndMinutes = "tally.notifications.quietHours.endMinutes"

        /// Set once the post-first-Session primer has been answered either way.
        public static let notificationsPrimerShown = "tally.notifications.primerShown"

        /// Set once provisional (quiet) authorization has been asked for, so the
        /// digest's silent opt-in happens exactly once (SPEC §9 etiquette).
        public static let provisionalRequested = "tally.notifications.provisionalRequested"

        /// Bookkeeping for the ≤ 1/week rate limits.
        public static let lastTrendAlertAt = "tally.notifications.lastTrendAlertAt"
        public static let lastTrendAlertSignature = "tally.notifications.lastTrendAlertSignature"
        public static let lastStreakNudgeDay = "tally.notifications.lastStreakNudgeDay"
        public static let lastPacingNudgeSessionID = "tally.notifications.lastPacingNudgeSession"
        public static let lastPacingNudgeAt = "tally.notifications.lastPacingNudgeAt"

        // Bar Radar — SPEC §2, §9. Stored here in Wave 2; consumed by Wave 3.

        public static let barRadarEnabled = "tally.barRadar.enabled"
        public static let barRadarDiscoveryEnabled = "tally.barRadar.discoveryEnabled"
        public static let barRadarDwellMinutes = "tally.barRadar.dwellMinutes"
        public static let barRadarDiscoveryStartMinutes = "tally.barRadar.discoveryStartMinutes"
        public static let barRadarDiscoveryEndMinutes = "tally.barRadar.discoveryEndMinutes"

        // Health — SPEC §4, §9, §10. Stored here in Wave 2; consumed by Wave 3.

        public static let healthWriteAlcoholEnabled = "tally.health.writeAlcohol"
        public static let morningAfterThreshold = "tally.health.morningAfterThreshold"

        // iCloud sync — SPEC §8. Owned by the `sync` workstream; named here only
        // so the key cannot be invented twice.
        public static let iCloudSyncEnabled = "tally.sync.iCloudEnabled"
    }

    // MARK: - Defaults

    /// Every default value SPEC §9 names, and the ones it leaves to us.
    public enum Fallback {

        /// SPEC §3: "default 1:1, configurable".
        public static let ratioGoal: Double = 1.0

        /// SPEC §9 lists no quiet-hours default, so this one is ours to justify.
        ///
        /// Midnight to 08:00. The obvious 22:00 start is wrong for this app: the
        /// pacing nudge exists to land mid-Session (SPEC §5, "the pacing nudge
        /// landing on the wrist mid-session is the point") and a 22:00 window
        /// would silence it on exactly the nights it matters, along with the
        /// Sunday-evening digest and the evening streak nudge. Starting at
        /// midnight keeps the evening usable and still stops the phone buzzing
        /// while you sleep or hungover the next morning. Bar Radar ignores the
        /// window entirely, per SPEC §5.
        public static let quietHoursStartMinutes = 0 * 60
        public static let quietHoursEndMinutes = 8 * 60
        public static let quietHoursEnabled = true

        /// SPEC §2: "a second notification for +45 min (configurable)".
        public static let barRadarDwellMinutes = 45

        /// SPEC §2: "plausible hours only (default 4 pm–2 am, configurable)".
        public static let barRadarDiscoveryStartMinutes = 16 * 60
        public static let barRadarDiscoveryEndMinutes = 2 * 60

        /// SPEC §2: discovery is "on by default when Bar Radar is enabled".
        public static let barRadarDiscoveryEnabled = true

        /// SPEC §4: "activity on days following a Session of ≥ 2 alcoholic drinks
        /// (threshold configurable)".
        public static let morningAfterThreshold = 2
    }

    // MARK: - Suites

    /// App Group first (shared with the widget and watch), `.standard` when the
    /// entitlement is missing — a UI-test host or a misconfigured build must not
    /// lose its settings, it just stops sharing them.
    public static let primary: UserDefaults =
        UserDefaults(suiteName: TallyStore.appGroupIdentifier) ?? .standard

    /// The mirror, so a reader using plain `@AppStorage` sees the same value.
    public static var mirror: UserDefaults? {
        primary === UserDefaults.standard ? nil : .standard
    }

    // MARK: - Reads

    public static func object(forKey key: String) -> Any? {
        primary.object(forKey: key) ?? mirror?.object(forKey: key)
    }

    public static func bool(forKey key: String, default fallback: Bool) -> Bool {
        object(forKey: key) as? Bool ?? fallback
    }

    public static func int(forKey key: String, default fallback: Int) -> Int {
        (object(forKey: key) as? NSNumber)?.intValue ?? fallback
    }

    public static func double(forKey key: String, default fallback: Double) -> Double {
        (object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
    }

    public static func string(forKey key: String) -> String? {
        object(forKey: key) as? String
    }

    public static func date(forKey key: String) -> Date? {
        object(forKey: key) as? Date
    }

    // MARK: - Writes

    public static func set(_ value: Any?, forKey key: String) {
        if let value {
            primary.set(value, forKey: key)
            mirror?.set(value, forKey: key)
        } else {
            remove(key)
        }
    }

    public static func remove(_ key: String) {
        primary.removeObject(forKey: key)
        mirror?.removeObject(forKey: key)
    }

    // MARK: - UI-test support

    /// Launch argument that wipes every key above before the first view reads one.
    ///
    /// `tally/Shared/LaunchArguments.swift` belongs to the shell, so this stream
    /// declares its own flag rather than editing that file; `SettingsUITests`
    /// passes both.
    static let resetSettingsLaunchArgument = "-tally-uitest-reset-settings"

    static var wantsSettingsReset: Bool {
        ProcessInfo.processInfo.arguments.contains(resetSettingsLaunchArgument)
    }

    /// Clears everything this enum owns. Only ever called for the launch argument
    /// above and by Settings → Erase all data.
    static func resetAll() {
        var keys: [String] = [
            Keys.ratioGoal,
            Keys.quietHoursEnabled,
            Keys.quietHoursStartMinutes,
            Keys.quietHoursEndMinutes,
            Keys.notificationsPrimerShown,
            Keys.provisionalRequested,
            Keys.lastTrendAlertAt,
            Keys.lastTrendAlertSignature,
            Keys.lastStreakNudgeDay,
            Keys.lastPacingNudgeSessionID,
            Keys.lastPacingNudgeAt,
            Keys.barRadarEnabled,
            Keys.barRadarDiscoveryEnabled,
            Keys.barRadarDwellMinutes,
            Keys.barRadarDiscoveryStartMinutes,
            Keys.barRadarDiscoveryEndMinutes,
            Keys.healthWriteAlcoholEnabled,
            Keys.morningAfterThreshold,
            Keys.iCloudSyncEnabled
        ]
        keys.append(contentsOf: TallyNotificationCategory.allCases.map(\.storageKey))
        for key in keys { remove(key) }
    }
}
