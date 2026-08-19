import Foundation

/// The notification categories of SPEC §5, as one extensible enum.
///
/// | Category | Trigger | Owner |
/// |---|---|---|
/// | Weekly digest | Sunday evening | Wave 2 |
/// | Trend alerts | Sustained change in the 7-day average | Wave 2 |
/// | Pacing nudge | 3+ alcoholic drinks within 90 min, in-Session | Wave 2 |
/// | Streak protection | Evening of a day that would break a streak | Wave 2 |
/// | Bar Radar arrival / dwell / discovery | Geofence + visit monitoring (§2) | Wave 3 `radar` |
/// | Session reminder | 60 min since the last log, Session active, still at the venue (§2) | Wave 3 `radar` |
/// | Session true-up | A Session with ≥ 1 drink closes (§2) | Wave 3 `radar` |
/// | Activity insight | New qualifying correlation (§4) | Wave 3 `insights` |
///
/// **Wave 3's checklist** — the cases already exist here so the toggles, the
/// storage keys, and the quiet-hours exemption are all in place before the
/// schedulers arrive. Two things to flip when `radar` and `insights` land:
/// 1. `isImplemented` — one line, and the category appears in Settings;
/// 2. `NotificationService.registerSystemCategories(additional:)` — pass the
///    `UNNotificationCategory` carrying the actionable buttons (SPEC §2's
///    "+1 drink" / "Not drinking tonight").
public enum TallyNotificationCategory: String, CaseIterable, Identifiable, Codable, Sendable {

    // MARK: Wave 2 (this stream)

    case weeklyDigest
    case trendAlert
    case pacingNudge
    case streakProtection

    // MARK: Wave 3 (declared, not yet scheduled)

    case barRadarArrival
    case barRadarDwell
    case barRadarDiscovery
    case sessionReminder
    case sessionTrueUp
    case activityInsight

    public var id: String { rawValue }

    // MARK: - Identity

    /// Identifier used for the `UNNotificationCategory` and as the prefix of
    /// every request identifier this category schedules.
    public var identifier: String { "tally.category.\(rawValue)" }

    public var storageKey: String { TallyDefaults.Keys.notificationCategoryPrefix + rawValue }

    // MARK: - Presentation (SPEC §9 Settings)

    public var title: String {
        switch self {
        case .weeklyDigest: "Weekly digest"
        case .trendAlert: "Trend alerts"
        case .pacingNudge: "Pacing nudge"
        case .streakProtection: "Streak protection"
        case .barRadarArrival: "Bar Radar arrival"
        case .barRadarDwell: "Bar Radar dwell"
        case .barRadarDiscovery: "Bar Radar discovery"
        case .sessionReminder: "Session reminder"
        case .sessionTrueUp: "Session true-up"
        case .activityInsight: "Activity insight"
        }
    }

    /// One factual line each — the same tone the notifications themselves use.
    public var blurb: String {
        switch self {
        case .weeklyDigest: "Sunday evening: the week's counts and your 7-day average."
        case .trendAlert: "When your 7-day average has moved in one direction for a few weeks. At most one a week."
        case .pacingNudge: "Mid-Session, after three drinks inside 90 minutes."
        case .streakProtection: "Evening of a day that would end your ratio streak."
        case .barRadarArrival: "Arriving at a bar you go to often."
        case .barRadarDwell: "Still at the bar 45 minutes later, nothing logged."
        case .barRadarDiscovery: "A bar you've never logged, at most three prompts a week."
        case .sessionReminder: "Mid-Session, an hour after your last drink and still at the bar. At most twice a visit."
        case .sessionTrueUp: "When a Session ends: what it counted, and a way to correct it. Once per Session."
        case .activityInsight: "A new correlation between drinking and your activity. At most one a week."
        }
    }

    public var systemImageName: String {
        switch self {
        case .weeklyDigest: "calendar"
        case .trendAlert: "chart.line.uptrend.xyaxis"
        case .pacingNudge: "metronome"
        case .streakProtection: "flame"
        case .barRadarArrival: "mappin.and.ellipse"
        case .barRadarDwell: "clock"
        case .barRadarDiscovery: "binoculars"
        case .sessionReminder: "clock.arrow.circlepath"
        case .sessionTrueUp: "checklist"
        case .activityInsight: "figure.run"
        }
    }

    // MARK: - Behaviour

    /// What quiet hours do to a category that wants to fire inside the window.
    ///
    /// SPEC §5 says quiet hours apply everywhere except Bar Radar, but "apply"
    /// splits in two once you write the scheduler: a summary is still true in
    /// the morning, while a suggestion about the drink in your hand is not.
    public enum QuietHoursPolicy: Hashable, Sendable {

        /// Fires regardless. SPEC §5: "bar hours *are* quiet hours, and those
        /// prompts are the feature."
        case ignore

        /// Held until the window ends, then delivered.
        case postpone

        /// Not delivered at all. For anything whose only value is being timely —
        /// a spacer suggestion at 08:00 the next morning is worse than silence.
        case drop
    }

    public var quietHoursPolicy: QuietHoursPolicy {
        switch self {
        // The Bar Radar family, which now includes the mid-Session reminder: it
        // fires at the bar, mid-outing, or not at all.
        case .barRadarArrival, .barRadarDwell, .barRadarDiscovery, .sessionReminder: .ignore
        // The Session true-up is the one Bar Radar prompt that wants *both*, and
        // a category has one policy, so it declares the one it can actually
        // enforce. SPEC §2: "a geofence exit delivers immediately (quiet-hours
        // exempt — the user is demonstrably out and awake); a timeout close
        // (home, or no geofence) delivers with quiet-hours *postpone* semantics,
        // so a Session that expires at 2 a.m. reconciles in the morning."
        //
        // Only the timeout half is *scheduled*, and scheduling is the only moment
        // a policy can be applied to a `UNNotificationRequest` — so `.postpone` is
        // the honest declaration. The exit half is delivered immediately by
        // `RadarService` down the `RadarNotifying` path, which consults nothing:
        // the exemption there is structural, exactly as it is for the rest of the
        // family, rather than something this switch could express.
        case .sessionTrueUp: .postpone
        case .weeklyDigest, .trendAlert, .activityInsight: .postpone
        case .pacingNudge, .streakProtection: .drop
        }
    }

    /// SPEC §5: "Quiet hours apply to every category except the Bar Radar ones."
    public var respectsQuietHours: Bool { quietHoursPolicy != .ignore }

    /// SPEC §9 etiquette: "The weekly digest may use provisional (quiet)
    /// notification delivery so the first digest can arrive before any prompt;
    /// loud categories always go through the primer."
    public var mayDeliverProvisionally: Bool { self == .weeklyDigest }

    /// What a category is set to before the user has opinions. Everything is on,
    /// because nothing schedules until authorization allows it anyway — and
    /// declining the primer explicitly writes `false` across the board (SPEC §9:
    /// "If declined: all categories off").
    public var defaultEnabled: Bool { true }

    /// Whether this build can actually schedule the category.
    ///
    /// Wave 3 flips its three cases to `true` — that is the whole integration on
    /// this side.
    public var isImplemented: Bool {
        switch self {
        case .weeklyDigest, .trendAlert, .pacingNudge, .streakProtection, .activityInsight,
             .barRadarArrival, .barRadarDwell, .barRadarDiscovery, .sessionReminder,
             .sessionTrueUp: true
        }
    }

    /// The rows Settings draws (SPEC §9: "the §5 per-category toggles"). A toggle
    /// for a category nothing can schedule yet would be a lie, so unimplemented
    /// categories stay hidden until their wave lands.
    public static var userConfigurable: [TallyNotificationCategory] {
        allCases.filter(\.isImplemented)
    }
}
