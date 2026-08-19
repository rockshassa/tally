import Foundation

/// Accessibility identifiers for everything Wave 2's `nudge` stream draws.
///
/// Kept beside the screens rather than in `tally/Shared/AccessibilityIdentifiers.swift`,
/// which belongs to the shell — but the rule from that file still holds: these
/// strings are API the moment `SettingsUITests` reads one, so later waves add
/// cases instead of repurposing them.
enum SettingsA11y {

    static let screen = "settings.screen"
    static let closeButton = "settings.closeButton"

    /// **Integration contract.** Whatever presents `SettingsScreen` — the You
    /// tab's gear (SPEC §9: "Settings lives on the You tab") — should carry this
    /// identifier, so `SettingsUITests` can reach Settings without knowing which
    /// stream drew the button.
    static let gearButton = "settings.gearButton"

    // MARK: Goal (SPEC §3, §9)

    enum Goal {
        static let picker = "settings.goal.picker"
        static let summary = "settings.goal.summary"
    }

    // MARK: Venues (SPEC §2, §9)

    enum Venues {
        static let homeRow = "settings.venues.homeRow"
        static let venueListRow = "settings.venues.listRow"
        static let suppressedRow = "settings.venues.suppressedRow"

        static let list = "settings.venues.list"
        static let suppressedList = "settings.venues.suppressedList"

        static let nameField = "settings.venues.nameField"
        static let categoryPicker = "settings.venues.categoryPicker"
        static let muteToggle = "settings.venues.muteToggle"

        static func row(_ name: String) -> String { "settings.venues.row.\(name)" }
    }

    // MARK: Bar Radar (SPEC §2, §9)

    enum BarRadar {
        static let masterToggle = "settings.barRadar.masterToggle"
        static let discoveryToggle = "settings.barRadar.discoveryToggle"
        static let dwellStepper = "settings.barRadar.dwellStepper"
        static let sessionReminderStepper = "settings.barRadar.sessionReminderStepper"
        static let discoveryStartPicker = "settings.barRadar.discoveryStart"
        static let discoveryEndPicker = "settings.barRadar.discoveryEnd"
        static let statusRow = "settings.barRadar.statusRow"

        /// Prefix for the two-tier `PermissionPrimer` (SPEC §2).
        static let primer = "settings.barRadar.primer"
    }

    // MARK: Notifications (SPEC §5, §9)

    enum Notifications {
        static let quietHoursToggle = "settings.notifications.quietHoursToggle"
        static let quietHoursStartPicker = "settings.notifications.quietHoursStart"
        static let quietHoursEndPicker = "settings.notifications.quietHoursEnd"
        static let statusRow = "settings.notifications.statusRow"

        static func toggle(_ category: TallyNotificationCategory) -> String {
            "settings.notifications.toggle.\(category.rawValue)"
        }
    }

    // MARK: The post-first-Session primer (SPEC §9)

    enum NotificationsPrimer {
        /// `PermissionPrimer` appends `.grantButton` / `.notNowButton` / `.title`.
        static let prefix = "notificationsPrimer"
        static let sheet = "notificationsPrimer.sheet"
        static let doneButton = "notificationsPrimer.doneButton"
    }

    // MARK: Health (SPEC §4, §9)

    enum Health {
        static let readStatusRow = "settings.health.readStatusRow"
        static let connectButton = "settings.health.connectButton"
        static let writeToggle = "settings.health.writeToggle"
        static let thresholdStepper = "settings.health.thresholdStepper"
        static let primer = "settings.health.primer"
    }

    // MARK: iCloud sync (SPEC §8) — the `sync` stream's mount point

    enum Sync {
        static let section = "settings.sync.section"
        static let placeholderRow = "settings.sync.placeholderRow"
    }

    // MARK: Data (SPEC §9)

    enum Data {
        static let exportCSV = "settings.data.exportCSV"
        static let exportJSON = "settings.data.exportJSON"
        static let eraseButton = "settings.data.eraseButton"
        static let eraseConfirmButton = "settings.data.eraseConfirmButton"
        static let eraseFinalButton = "settings.data.eraseFinalButton"
    }

    // MARK: About (SPEC §9, §10)

    enum About {
        static let row = "settings.about.row"
        static let screen = "settings.about.screen"
        static let guidelinesLink = "settings.about.guidelinesLink"
    }
}
