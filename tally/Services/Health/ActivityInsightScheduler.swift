import Foundation
import TallyKit
import UserNotifications

/// SPEC §5's **Activity insight** category: *"New qualifying correlation from the
/// health-insights engine (§4), at most one per week."*
///
/// Separate from `NotificationService` because that class belongs to Wave 2 and
/// its scheduling is driven by the event log on foreground; this one is driven by
/// the insights engine, which needs a HealthKit read to have finished first. The
/// contracts it shares with it are the ones that matter: the same per-category
/// toggle (`TallySettings.isEnabled`), the same `QuietHours` type, the same
/// `postpone` policy, and the same identifier prefix, so
/// `NotificationService.cancel(_:)` retracts these too.
///
/// **The cap is persisted, not inferred.** A pending request disappears the
/// moment it fires, so "have we sent one this week?" cannot be answered by
/// looking at the queue. The last-fired date is written to `TallyDefaults`.
@MainActor
public final class ActivityInsightScheduler {

    /// One per process, matching `NotificationService.shared`.
    public static let shared = ActivityInsightScheduler()

    // MARK: Storage keys

    /// Named here rather than in `TallyDefaults.Keys` because that file belongs to
    /// the Wave 2 `nudge` stream. Same prefix convention, so the integrator can
    /// lift both constants into `Keys` (and into `TallyDefaults.resetAll()`)
    /// without changing a stored value.
    public enum Keys {
        public static let lastActivityInsightAt = "tally.notifications.lastActivityInsightAt"
        public static let lastActivityInsightSignature = "tally.notifications.lastActivityInsightSignature"
    }

    // MARK: Tunables

    /// SPEC §5: "at most one per week".
    public static let cooldown: TimeInterval = 7 * 24 * 60 * 60

    /// Matches `NotificationService.immediateDelay` — long enough that the banner
    /// never lands while the user is still looking at the card it came from.
    static let deliveryDelay: TimeInterval = 45

    // MARK: Dependencies

    private let settings: TallySettings
    private let calendar: Calendar

    /// Injected so tests can drive it without a live notification centre. Both
    /// are main-actor closures because every call site here is, which is what
    /// lets a fixture record into main-actor state without ceremony. The defaults
    /// are resolved in the body rather than in the parameter list, because a
    /// default argument would be evaluated in the caller's isolation.
    private let schedule: @MainActor (UNNotificationRequest) async -> Void
    private let authorization: @MainActor () async -> PermissionStatus

    public init(
        settings: TallySettings? = nil,
        calendar: Calendar = .current,
        authorization: (@MainActor () async -> PermissionStatus)? = nil,
        schedule: (@MainActor (UNNotificationRequest) async -> Void)? = nil
    ) {
        self.settings = settings ?? .shared
        self.calendar = calendar
        self.authorization = authorization ?? {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return PermissionStatus(settings.authorizationStatus)
        }
        self.schedule = schedule ?? { request in
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    // MARK: - Entry point

    /// **The integrator's entry point**, and the one `HealthInsightsModel` calls
    /// at the end of every successful refresh.
    ///
    /// Every gate is checked here, in order, and any of them means silence:
    /// 1. the category is implemented in this build and its toggle is on;
    /// 2. notification authorization is granted (this category is loud — SPEC §9:
    ///    "loud categories always go through the primer", so provisional is not
    ///    enough);
    /// 3. there is a qualifying insight at all — under SPEC §4's guardrails there
    ///    usually is not;
    /// 4. it is not the same finding we already sent;
    /// 5. a week has passed since the last one.
    ///
    /// Quiet hours are then applied with `postpone` semantics: a correlation about
    /// the last 90 days is just as true at 08:00, so the notification is held
    /// until the window ends rather than dropped.
    ///
    /// - Returns: the date it was scheduled for, or `nil` if nothing was sent.
    @discardableResult
    public func submit(_ report: HealthInsightReport, now: Date = Date()) async -> Date? {
        guard let insight = report.headlineInsight else { return nil }
        return await submit(insight, now: now)
    }

    @discardableResult
    public func submit(_ insight: HealthInsight, now: Date = Date()) async -> Date? {

        let category = TallyNotificationCategory.activityInsight

        // Until the integrator flips `isImplemented`, this category has no
        // Settings row — firing it would be a notification the user cannot turn
        // off, which SPEC §5's opt-in rule forbids.
        guard category.isImplemented, settings.isEnabled(category) else { return nil }

        guard await authorization() == .authorized else { return nil }

        // Re-deriving the same finding on every foreground is normal; saying it
        // again is not news.
        if TallyDefaults.string(forKey: Keys.lastActivityInsightSignature) == insight.signature {
            return nil
        }

        // SPEC §5's hard cap, on a rolling week.
        if let last = TallyDefaults.date(forKey: Keys.lastActivityInsightAt),
           now.timeIntervalSince(last) < Self.cooldown {
            return nil
        }

        let proposed = now.addingTimeInterval(Self.deliveryDelay)
        let delivery = deliveryDate(for: proposed, category: category)

        let content = UNMutableNotificationContent()
        content.title = "Activity insight"
        content.body = insight.notificationBody
        content.sound = .default
        content.categoryIdentifier = category.identifier
        content.threadIdentifier = category.identifier
        content.userInfo = [
            "tallyCategory": category.rawValue,
            "tallyInsightKind": insight.kind.rawValue
        ]

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: delivery
        )
        let request = UNNotificationRequest(
            identifier: "\(category.identifier).\(insight.signature)",
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        )

        await schedule(request)

        TallyDefaults.set(now, forKey: Keys.lastActivityInsightAt)
        TallyDefaults.set(insight.signature, forKey: Keys.lastActivityInsightSignature)

        return delivery
    }

    // MARK: - Quiet hours

    /// SPEC §5 quiet hours, with this category's `postpone` policy (declared on
    /// `TallyNotificationCategory`). Kept as a `switch` over the policy rather
    /// than hardcoding `postpone`, so changing the declaration changes the
    /// behaviour in one place.
    func deliveryDate(for proposed: Date, category: TallyNotificationCategory) -> Date {
        switch category.quietHoursPolicy {
        case .ignore:
            return proposed
        case .postpone, .drop:
            // `.drop` never applies to this category; if it ever did, postponing
            // a 90-day correlation is still the honest degradation.
            return settings.quietHours.deliveryDate(for: proposed, calendar: calendar)
        }
    }

    // MARK: - Housekeeping

    /// Forgets the rate-limit bookkeeping. Settings → Erase all data should call
    /// this alongside `NotificationService.resetSchedulingHistory()`, for the same
    /// reason: the log those limits were computed against is gone.
    public func resetSchedulingHistory() {
        TallyDefaults.remove(Keys.lastActivityInsightAt)
        TallyDefaults.remove(Keys.lastActivityInsightSignature)
    }

    /// When the next Activity insight could fire at the earliest, or `nil` if one
    /// could fire now. Exposed for a Settings status row.
    public func nextEligibleDate(now: Date = Date()) -> Date? {
        guard let last = TallyDefaults.date(forKey: Keys.lastActivityInsightAt) else { return nil }
        let next = last.addingTimeInterval(Self.cooldown)
        return next > now ? next : nil
    }
}
