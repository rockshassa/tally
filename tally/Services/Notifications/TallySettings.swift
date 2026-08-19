import Foundation
import Observation
import TallyKit

/// Every setting SPEC §9 lists, as one observable object.
///
/// Settings screens bind to it, the notification engine reads it, and Wave 3
/// reads the Bar Radar and Health values it has been storing all along. Backed by
/// `TallyDefaults`, so a change survives a kill-and-relaunch (PLAN Gate 2:
/// "every Settings value round-trips").
///
/// Stored properties rather than computed `UserDefaults` lookups because
/// `@Observable` tracks stored state — that is what makes a toggle in one section
/// update a status row in another without any manual refresh.
@MainActor
@Observable
public final class TallySettings {

    /// One instance, because two would disagree about what is on screen. The
    /// notification engine and every Settings section share it.
    public static let shared = TallySettings()

    // MARK: - Goal (SPEC §3, §9)

    /// NA drinks per alcoholic drink. 1.0 is the SPEC §3 default 1:1.
    ///
    /// The You tab reads the same value from `TallyDefaults.Keys.ratioGoal`.
    public var ratioGoal: Double {
        didSet { TallyDefaults.set(ratioGoal, forKey: TallyDefaults.Keys.ratioGoal) }
    }

    /// The scoring configuration implied by the goal — the one conversion point
    /// between Settings and `ScoringEngine`.
    public var scoringConfiguration: ScoringEngine.Configuration {
        var configuration = ScoringEngine.Configuration.default
        configuration.ratioGoal = ratioGoal
        return configuration
    }

    // MARK: - Notifications (SPEC §5, §9)

    private var enabledCategories: [String: Bool]

    public var quietHoursEnabled: Bool {
        didSet { TallyDefaults.set(quietHoursEnabled, forKey: TallyDefaults.Keys.quietHoursEnabled) }
    }

    public var quietHoursStartMinutes: Int {
        didSet { TallyDefaults.set(quietHoursStartMinutes, forKey: TallyDefaults.Keys.quietHoursStartMinutes) }
    }

    public var quietHoursEndMinutes: Int {
        didSet { TallyDefaults.set(quietHoursEndMinutes, forKey: TallyDefaults.Keys.quietHoursEndMinutes) }
    }

    public var quietHours: QuietHours {
        QuietHours(
            isEnabled: quietHoursEnabled,
            startMinutes: quietHoursStartMinutes,
            endMinutes: quietHoursEndMinutes
        )
    }

    public func isEnabled(_ category: TallyNotificationCategory) -> Bool {
        enabledCategories[category.rawValue] ?? category.defaultEnabled
    }

    public func setEnabled(_ isEnabled: Bool, for category: TallyNotificationCategory) {
        enabledCategories[category.rawValue] = isEnabled
        TallyDefaults.set(isEnabled, forKey: category.storageKey)
    }

    /// SPEC §9: declining the notifications primer means "all categories off;
    /// re-enable from Settings".
    public func disableAllNotificationCategories() {
        for category in TallyNotificationCategory.allCases {
            setEnabled(false, for: category)
        }
    }

    // MARK: - Bar Radar (SPEC §2, §9) — stored now, consumed by Wave 3

    public var barRadarEnabled: Bool {
        didSet { TallyDefaults.set(barRadarEnabled, forKey: TallyDefaults.Keys.barRadarEnabled) }
    }

    public var barRadarDiscoveryEnabled: Bool {
        didSet { TallyDefaults.set(barRadarDiscoveryEnabled, forKey: TallyDefaults.Keys.barRadarDiscoveryEnabled) }
    }

    /// SPEC §2: dwell follow-up at +45 min, configurable.
    public var barRadarDwellMinutes: Int {
        didSet { TallyDefaults.set(barRadarDwellMinutes, forKey: TallyDefaults.Keys.barRadarDwellMinutes) }
    }

    /// SPEC §2: the mid-Session reminder fires when "no drink has been logged for
    /// 60 min (configurable)". Measured from the last logged drink, not from
    /// arrival — that is what makes it a reminder rather than a second dwell.
    public var sessionReminderMinutes: Int {
        didSet {
            TallyDefaults.set(
                sessionReminderMinutes,
                forKey: TallyDefaults.Keys.barRadarSessionReminderMinutes
            )
        }
    }

    /// SPEC §2: discovery runs during plausible hours only, default 4 pm–2 am.
    public var discoveryStartMinutes: Int {
        didSet { TallyDefaults.set(discoveryStartMinutes, forKey: TallyDefaults.Keys.barRadarDiscoveryStartMinutes) }
    }

    public var discoveryEndMinutes: Int {
        didSet { TallyDefaults.set(discoveryEndMinutes, forKey: TallyDefaults.Keys.barRadarDiscoveryEndMinutes) }
    }

    // MARK: - Health (SPEC §4, §9, §10) — stored now, consumed by Wave 3

    /// SPEC §10: writing `numberOfAlcoholicBeverages` is off by default.
    public var writesAlcoholToHealth: Bool {
        didSet { TallyDefaults.set(writesAlcoholToHealth, forKey: TallyDefaults.Keys.healthWriteAlcoholEnabled) }
    }

    /// SPEC §4: morning-after comparisons use Sessions of ≥ this many alcoholic
    /// drinks. Default 2.
    public var morningAfterThreshold: Int {
        didSet { TallyDefaults.set(morningAfterThreshold, forKey: TallyDefaults.Keys.morningAfterThreshold) }
    }

    // MARK: - Init

    public init() {
        if TallyDefaults.wantsSettingsReset { TallyDefaults.resetAll() }

        ratioGoal = TallyDefaults.double(
            forKey: TallyDefaults.Keys.ratioGoal,
            default: TallyDefaults.Fallback.ratioGoal
        )

        var categories: [String: Bool] = [:]
        for category in TallyNotificationCategory.allCases {
            if let stored = TallyDefaults.object(forKey: category.storageKey) as? Bool {
                categories[category.rawValue] = stored
            }
        }
        enabledCategories = categories

        quietHoursEnabled = TallyDefaults.bool(
            forKey: TallyDefaults.Keys.quietHoursEnabled,
            default: TallyDefaults.Fallback.quietHoursEnabled
        )
        quietHoursStartMinutes = TallyDefaults.int(
            forKey: TallyDefaults.Keys.quietHoursStartMinutes,
            default: TallyDefaults.Fallback.quietHoursStartMinutes
        )
        quietHoursEndMinutes = TallyDefaults.int(
            forKey: TallyDefaults.Keys.quietHoursEndMinutes,
            default: TallyDefaults.Fallback.quietHoursEndMinutes
        )

        barRadarEnabled = TallyDefaults.bool(forKey: TallyDefaults.Keys.barRadarEnabled, default: false)
        barRadarDiscoveryEnabled = TallyDefaults.bool(
            forKey: TallyDefaults.Keys.barRadarDiscoveryEnabled,
            default: TallyDefaults.Fallback.barRadarDiscoveryEnabled
        )
        barRadarDwellMinutes = TallyDefaults.int(
            forKey: TallyDefaults.Keys.barRadarDwellMinutes,
            default: TallyDefaults.Fallback.barRadarDwellMinutes
        )
        sessionReminderMinutes = TallyDefaults.int(
            forKey: TallyDefaults.Keys.barRadarSessionReminderMinutes,
            default: TallyDefaults.Fallback.barRadarSessionReminderMinutes
        )
        discoveryStartMinutes = TallyDefaults.int(
            forKey: TallyDefaults.Keys.barRadarDiscoveryStartMinutes,
            default: TallyDefaults.Fallback.barRadarDiscoveryStartMinutes
        )
        discoveryEndMinutes = TallyDefaults.int(
            forKey: TallyDefaults.Keys.barRadarDiscoveryEndMinutes,
            default: TallyDefaults.Fallback.barRadarDiscoveryEndMinutes
        )

        writesAlcoholToHealth = TallyDefaults.bool(
            forKey: TallyDefaults.Keys.healthWriteAlcoholEnabled,
            default: false
        )
        morningAfterThreshold = TallyDefaults.int(
            forKey: TallyDefaults.Keys.morningAfterThreshold,
            default: TallyDefaults.Fallback.morningAfterThreshold
        )
    }

}
