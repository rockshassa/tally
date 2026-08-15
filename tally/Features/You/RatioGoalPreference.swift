import Foundation
import TallyKit

/// Where the user's NA-to-alcohol ratio goal lives (SPEC §3 "default 1:1,
/// configurable"; SPEC §9 Settings).
///
/// **Cross-agent contract.** The You tab reads this value; the Settings screen
/// writes it. Both go through this one type so the key and the default can never
/// drift apart:
///
/// * key — `"tally.settings.ratioGoal"` in `UserDefaults.standard`
/// * value — a `Double`: NA drinks required per alcoholic drink
/// * default — `1.0` (the SPEC §3 1:1 goal), used whenever the key is absent,
///   non-numeric, or out of range
///
/// `@AppStorage("tally.settings.ratioGoal")` on a `Double` interoperates with
/// this exactly, which is what makes a Settings change repaint the You tab with
/// no notification plumbing in between.
///
/// The value is a preference, not derived state, so it is one of the few things
/// in the app that *is* persisted — but it is persisted outside the event log,
/// so SPEC §1's "derive, don't store" rule is untouched.
enum RatioGoalPreference {

    /// The `UserDefaults.standard` key. Public API across agents — renaming it
    /// silently resets everyone's goal to 1:1.
    static let storageKey = "tally.settings.ratioGoal"

    /// SPEC §3: 1:1.
    static let defaultValue: Double = 1.0

    /// Goals outside this range are treated as corrupt and fall back to the
    /// default: a zero or negative goal would make the streak meaningless, and
    /// nothing in the product asks for more than four NA drinks per drink.
    static let allowedRange: ClosedRange<Double> = 0.25...4.0

    /// The goal to score against right now.
    static func current(in defaults: UserDefaults = .standard) -> Double {
        // `object(forKey:)` rather than `double(forKey:)`: the latter cannot
        // tell "absent" from "explicitly 0", and 0 is not a legal goal.
        guard let stored = defaults.object(forKey: storageKey) as? Double else { return defaultValue }
        return allowedRange.contains(stored) ? stored : defaultValue
    }

    /// Convenience for Settings. Values outside `allowedRange` are clamped.
    static func set(_ goal: Double, in defaults: UserDefaults = .standard) {
        let clamped = min(max(goal, allowedRange.lowerBound), allowedRange.upperBound)
        defaults.set(clamped, forKey: storageKey)
    }

    /// The scoring configuration the You tab uses — the stock engine with the
    /// user's goal substituted in, so every number on screen is exactly what
    /// `ScoringEngine` would produce headlessly (PLAN Gate 2).
    static func configuration(in defaults: UserDefaults = .standard) -> ScoringEngine.Configuration {
        var configuration = ScoringEngine.Configuration.default
        configuration.ratioGoal = current(in: defaults)
        return configuration
    }

    /// "1 : 1", "2 : 1", "1.5 : 1" — the ratio as the goal row prints it.
    static func displayString(_ goal: Double) -> String {
        let na = goal.rounded() == goal
            ? String(Int(goal))
            : String(format: "%.1f", goal)
        return "\(na) : 1"
    }
}
