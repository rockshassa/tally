import Foundation
import TallyKit

/// Accessibility identifiers for the You tab (SPEC §3).
///
/// These live here rather than in `Shared/AccessibilityIdentifiers.swift`
/// because that file belongs to the shell; `A11y` stays the shell's vocabulary
/// and this stays the You tab's. Same contract though — the XCUITest suite
/// drives these strings, so they are API: add cases, never repurpose one.
enum YouA11y {

    static let screen = "you.screen"
    static let hero = "you.hero"
    static let streakRing = "you.streakRing"
    static let allTimePoints = "you.points.allTime"
    static let weekPoints = "you.points.week"
    static let ratioGoalBar = "you.ratioGoalBar"
    static let badgeCase = "you.badgeCase"
    static let emptyState = "you.emptyState"
    static let settingsButton = "settings.gearButton"  // SettingsUITests navigates by this

    /// One per badge tile: `you.badge.pacer`, `you.badge.drySpell30`, …
    static func badge(_ badge: Badge) -> String {
        "you.badge.\(badge.rawValue)"
    }
}
