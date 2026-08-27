import Foundation
import SwiftData
import TallyKit
import UserNotifications

// MARK: - Scheduling seam

/// The slice of `UNUserNotificationCenter` this engine uses.
///
/// Narrow on purpose: it keeps the scheduling logic callable without a live
/// notification centre, which is what makes the SPEC §5 trigger fixtures
/// (PLAN Gate 2) something you can assert on.
@MainActor
protocol UserNotificationScheduling: AnyObject {
    func currentAuthorization() async -> PermissionStatus
    func schedule(_ request: UNNotificationRequest) async
    func cancel(identifiers: [String])
    func cancelAllPending()
    func pendingIdentifiers() async -> [String]
    func replaceCategories(_ categories: Set<UNNotificationCategory>)
    func assignDelegate(_ delegate: any UNUserNotificationCenterDelegate)
}

extension UNUserNotificationCenter: UserNotificationScheduling {

    func currentAuthorization() async -> PermissionStatus {
        PermissionStatus(await notificationSettings().authorizationStatus)
    }

    func schedule(_ request: UNNotificationRequest) async {
        // A rejected request is not worth failing a foreground refresh over —
        // the count and the Settings screen do not depend on it.
        try? await add(request)
    }

    func cancel(identifiers: [String]) {
        removePendingNotificationRequests(withIdentifiers: identifiers)
        removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func cancelAllPending() {
        removeAllPendingNotificationRequests()
    }

    func pendingIdentifiers() async -> [String] {
        await pendingNotificationRequests().map(\.identifier)
    }

    func replaceCategories(_ categories: Set<UNNotificationCategory>) {
        setNotificationCategories(categories)
    }

    func assignDelegate(_ delegate: any UNUserNotificationCenterDelegate) {
        self.delegate = delegate
    }
}

// MARK: - Action forwarding

/// What the user did to a notification, reduced to `Sendable` parts.
///
/// Wave 3's actionable Bar Radar buttons (SPEC §2: "+1 drink", "Not drinking
/// tonight") arrive here — `radar` sets `NotificationService.actionHandler`
/// rather than fighting this class for the delegate.
public struct NotificationAction: Hashable, Sendable {
    public let categoryIdentifier: String
    public let actionIdentifier: String
    public let requestIdentifier: String
    public let userInfo: [String: String]

    public var category: TallyNotificationCategory? {
        TallyNotificationCategory.allCases.first { $0.identifier == categoryIdentifier }
    }
}

// MARK: - Service

/// The SPEC §5 notification engine: four categories, per-category opt-in, quiet
/// hours, and no server anywhere.
///
/// **What runs when.** Everything except the pacing nudge is (re)evaluated on
/// app foreground — local notifications are the only channel (SPEC §5, "All
/// local (no server)"), so the app has to do its thinking while it is awake:
///
/// | Category | Evaluated | Scheduled for |
/// |---|---|---|
/// | Weekly digest | every foreground | the coming Sunday, 19:00 |
/// | Trend alert | every foreground | ~a minute later, ≤ 1 per week |
/// | Pacing nudge | `sessionDidLogDrink` | ~a minute later, ≤ 1 per Session |
/// | Streak protection | every foreground | tonight, 20:30, ≤ 1 per day |
///
/// **Watch mirroring** (SPEC §5) needs no code: iOS forwards local notifications
/// to a paired watch when the phone is locked, which is exactly the case the
/// pacing nudge is designed for.
@MainActor
public final class NotificationService: NSObject {

    // MARK: Shared instance

    /// One engine per process — two would schedule everything twice.
    public static let shared = NotificationService()

    // MARK: Dependencies

    private let center: any UserNotificationScheduling
    private let settings: TallySettings
    private let calendar: Calendar

    /// Defaults are resolved in the body rather than in the parameter list: a
    /// default argument is evaluated in the *caller's* isolation, and both
    /// singletons are main-actor bound.
    init(
        center: (any UserNotificationScheduling)? = nil,
        settings: TallySettings? = nil,
        calendar: Calendar = .current
    ) {
        self.center = center ?? UNUserNotificationCenter.current()
        self.settings = settings ?? .shared
        self.calendar = calendar
        super.init()
    }

    // MARK: Tunables

    /// SPEC §5: "Sunday evening".
    static let digestWeekday = 1
    static let digestHour = 19

    /// SPEC §5: "evening of a day that would break a streak".
    static let streakHour = 20
    static let streakMinute = 30

    /// Long enough that a notification never lands while the user's thumb is
    /// still on the button that caused it.
    static let immediateDelay: TimeInterval = 45

    /// SPEC §5: trend alerts are "sustained" signals, at most one a week.
    static let trendCooldown: TimeInterval = 7 * 24 * 60 * 60

    /// Two pacing nudges an hour would be nagging, which SPEC §9 forbids.
    static let pacingCooldown: TimeInterval = 2 * 60 * 60

    // MARK: Delegate hooks

    /// Set by Wave 3 to receive Bar Radar / insight actions.
    public var actionHandler: ((NotificationAction) -> Void)?

    /// Registers the delegate and the `UNNotificationCategory` set.
    ///
    /// - Parameter additionalCategories: Wave 3 passes its actionable categories
    ///   here; this stream's four carry no buttons, so tapping one just opens
    ///   the app.
    public func activate(additionalCategories: Set<UNNotificationCategory> = []) {
        center.assignDelegate(self)
        registerSystemCategories(additional: additionalCategories)
    }

    public func registerSystemCategories(additional: Set<UNNotificationCategory> = []) {
        var categories: Set<UNNotificationCategory> = Set(
            TallyNotificationCategory.allCases.map { category in
                UNNotificationCategory(
                    identifier: category.identifier,
                    actions: [],
                    intentIdentifiers: [],
                    options: []
                )
            }
        )
        // Wave 3's definitions win: an actionable category must replace the
        // buttonless placeholder registered above, not sit beside it.
        for category in additional {
            categories = categories.filter { $0.identifier != category.identifier }
            categories.insert(category)
        }
        center.replaceCategories(categories)
    }

    // MARK: - Authorization

    public func authorization() async -> PermissionStatus {
        await center.currentAuthorization()
    }

    /// SPEC §9 etiquette: "The weekly digest may use provisional (quiet)
    /// notification delivery so the first digest can arrive before any prompt."
    ///
    /// Provisional authorization shows no dialog and cannot burn the one system
    /// prompt, so asking for it before the primer is safe — and it is the only
    /// reason a brand-new install can receive its first Sunday digest at all.
    public func requestProvisionalDeliveryIfNeeded(using permissions: any PermissionsService) async {
        guard !TallyDefaults.bool(forKey: TallyDefaults.Keys.provisionalRequested, default: false) else { return }
        guard settings.isEnabled(.weeklyDigest) else { return }
        guard await authorization() == .notDetermined else { return }

        TallyDefaults.set(true, forKey: TallyDefaults.Keys.provisionalRequested)
        await permissions.requestNotifications(provisional: true)
    }

    // MARK: - Foreground refresh

    /// Recomputes and reschedules everything that is not event-driven.
    ///
    /// Idempotent: identifiers are stable per category (per day, per Session, per
    /// week), so calling this on every foreground replaces rather than stacks.
    public func refresh(context: ModelContext, now: Date = Date()) async {
        let status = await authorization()

        guard status.isUsable else {
            // Denied or never asked: nothing of ours should survive, so a
            // re-grant later starts from a clean, freshly computed schedule.
            // Scoped to this stream's categories — Wave 3 schedules its own.
            await cancelOwnedCategories()
            return
        }

        guard let events = try? EventStore.snapshots(in: context) else { return }
        let engine = ScoringEngine(configuration: settings.scoringConfiguration)

        await refreshWeeklyDigest(events: events, status: status, now: now)
        await refreshTrendAlert(events: events, status: status, now: now)
        await refreshStreakProtection(events: events, engine: engine, status: status, now: now)
    }

    // MARK: - Weekly digest

    private func refreshWeeklyDigest(
        events: [DrinkEventSnapshot],
        status: PermissionStatus,
        now: Date
    ) async {

        let category = TallyNotificationCategory.weeklyDigest
        let identifier = requestIdentifier(category, suffix: "next")

        guard canSchedule(category, status: status) else {
            center.cancel(identifiers: [identifier])
            return
        }

        guard let fireDate = nextDigestDate(after: now) else { return }

        // The body is computed now for a week that has not finished yet, because
        // a local notification carries fixed text and there is no server to
        // refresh it. Every foreground rewrites this request, so the digest
        // reflects the last time the app was opened before Sunday evening —
        // and the window is always the right one, even when the numbers in it
        // are a day or two behind.
        let facts = NotificationTriggers.digestFacts(events: events, endingAt: fireDate, calendar: calendar)

        // A week with nothing in it has no news. Silence beats a digest of zeros.
        guard !facts.isEmpty else {
            center.cancel(identifiers: [identifier])
            return
        }

        guard let delivery = deliveryDate(for: fireDate, category: category) else {
            center.cancel(identifiers: [identifier])
            return
        }

        let content = makeContent(
            category: category,
            text: NotificationCopy.Digest.text(facts),
            // A weekly summary is not urgent enough to make a noise.
            sound: nil
        )

        await schedule(identifier: identifier, content: content, at: delivery)
    }

    /// The next Sunday at 19:00 local, strictly after `date`.
    func nextDigestDate(after date: Date, calendar: Calendar? = nil) -> Date? {
        let calendar = calendar ?? self.calendar
        var components = DateComponents()
        components.weekday = Self.digestWeekday
        components.hour = Self.digestHour
        components.minute = 0
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
    }

    // MARK: - Trend alert

    private func refreshTrendAlert(
        events: [DrinkEventSnapshot],
        status: PermissionStatus,
        now: Date
    ) async {

        let category = TallyNotificationCategory.trendAlert
        guard canSchedule(category, status: status) else { return }

        // ≤ 1 per week, and never the same finding twice.
        if let last = TallyDefaults.date(forKey: TallyDefaults.Keys.lastTrendAlertAt),
           now.timeIntervalSince(last) < Self.trendCooldown {
            return
        }

        guard let finding = NotificationTriggers.trendFinding(events: events, asOf: now, calendar: calendar) else {
            return
        }
        guard TallyDefaults.string(forKey: TallyDefaults.Keys.lastTrendAlertSignature) != finding.signature else {
            return
        }

        let proposed = now.addingTimeInterval(Self.immediateDelay)
        guard let delivery = deliveryDate(for: proposed, category: category) else { return }

        let content = makeContent(
            category: category,
            text: NotificationCopy.Trend.text(finding)
        )

        await schedule(
            identifier: requestIdentifier(category, suffix: finding.signature),
            content: content,
            at: delivery
        )

        TallyDefaults.set(now, forKey: TallyDefaults.Keys.lastTrendAlertAt)
        TallyDefaults.set(finding.signature, forKey: TallyDefaults.Keys.lastTrendAlertSignature)
    }

    // MARK: - Streak protection

    private func refreshStreakProtection(
        events: [DrinkEventSnapshot],
        engine: ScoringEngine,
        status: PermissionStatus,
        now: Date
    ) async {

        let category = TallyNotificationCategory.streakProtection
        let identifier = requestIdentifier(category, suffix: dayKey(now))

        guard canSchedule(category, status: status) else {
            center.cancel(identifiers: [identifier])
            return
        }

        let risk = NotificationTriggers.streakRisk(
            events: events,
            engine: engine,
            asOf: now,
            calendar: calendar
        )

        // The risk passed — they logged the water. Pull the nudge.
        guard let risk else {
            center.cancel(identifiers: [identifier])
            return
        }

        // SPEC §5 says "one nudge"; the day marker is what enforces that even
        // after the notification has fired and left the pending queue.
        guard TallyDefaults.string(forKey: TallyDefaults.Keys.lastStreakNudgeDay) != dayKey(now) else { return }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = Self.streakHour
        components.minute = Self.streakMinute
        let evening = calendar.date(from: components) ?? now

        // Opened the app after the evening slot: say it now rather than tomorrow.
        let proposed = evening > now ? evening : now.addingTimeInterval(Self.immediateDelay)
        guard let delivery = deliveryDate(for: proposed, category: category) else { return }

        let content = makeContent(
            category: category,
            text: NotificationCopy.Streak.text(risk)
        )

        await schedule(identifier: identifier, content: content, at: delivery)
        TallyDefaults.set(dayKey(now), forKey: TallyDefaults.Keys.lastStreakNudgeDay)
    }

    // MARK: - Pacing nudge (the log-path hook)

    /// **Call this from the log path**, right after a drink is written.
    ///
    /// SPEC §5: 3+ alcoholic drinks within 90 minutes, in-Session → "Time for a
    /// spacer? +25 pts." It has to be event-driven rather than scheduled,
    /// because the whole value is the timing.
    ///
    /// Cheap and non-throwing by design: the tally has already moved by the time
    /// this runs (SPEC §1, "the tap is never blocked"), and nothing here can put
    /// that at risk.
    ///
    /// - Parameters:
    ///   - type: what was just logged. An NA drink cancels a pending nudge —
    ///     the user did the thing the nudge was going to suggest.
    ///   - context: the app's model context.
    ///   - date: when it was logged. Retro-logs pass their own timestamp and are
    ///     ignored, since a drink recorded for last Tuesday needs no pacing.
    public func sessionDidLogDrink(
        type: DrinkType,
        in context: ModelContext,
        at date: Date = Date()
    ) {
        Task { await evaluatePacingNudge(type: type, in: context, at: date) }
    }

    func evaluatePacingNudge(
        type: DrinkType,
        in context: ModelContext,
        at date: Date = Date(),
        now: Date = Date()
    ) async {

        let category = TallyNotificationCategory.pacingNudge

        // Retro-logged and back-dated events are not "in-Session" (SPEC §5).
        guard abs(now.timeIntervalSince(date)) < 5 * 60 else { return }

        let status = await authorization()
        guard canSchedule(category, status: status) else { return }

        guard
            let events = try? EventStore.snapshots(in: context),
            let materialized = try? EventStore.materializedSessions(in: context)
        else { return }

        let deriver = SessionDeriver()
        guard let session = deriver.activeSession(
            events: events,
            materialized: materialized,
            asOf: now
        ) else { return }

        let identifier = requestIdentifier(category, suffix: session.id.uuidString)

        // An NA drink means they are pacing: retract anything pending.
        guard type == .alcoholic else {
            center.cancel(identifiers: [identifier])
            return
        }

        guard let finding = NotificationTriggers.pacingFinding(sessionEvents: session.events, asOf: now) else {
            center.cancel(identifiers: [identifier])
            return
        }

        // One per Session (SPEC §9: no nagging), plus a cooldown so a long night
        // that opens a second Session cannot chain nudges either.
        if TallyDefaults.string(forKey: TallyDefaults.Keys.lastPacingNudgeSessionID) == session.id.uuidString {
            return
        }
        if let last = TallyDefaults.date(forKey: TallyDefaults.Keys.lastPacingNudgeAt),
           now.timeIntervalSince(last) < Self.pacingCooldown {
            return
        }

        let proposed = now.addingTimeInterval(Self.immediateDelay)
        guard let delivery = deliveryDate(for: proposed, category: category) else { return }

        let content = makeContent(
            category: category,
            text: NotificationCopy.Pacing.text(finding)
        )

        await schedule(identifier: identifier, content: content, at: delivery)

        TallyDefaults.set(session.id.uuidString, forKey: TallyDefaults.Keys.lastPacingNudgeSessionID)
        TallyDefaults.set(now, forKey: TallyDefaults.Keys.lastPacingNudgeAt)
    }

    // MARK: - Cancellation

    /// Drops everything pending, whoever scheduled it. Settings → Erase all data
    /// uses this; nothing else should.
    public func cancelAll() {
        center.cancelAllPending()
    }

    /// Drops only the categories this stream schedules.
    public func cancelOwnedCategories() async {
        for category in TallyNotificationCategory.allCases where category.isImplemented {
            await cancel(category)
        }
    }

    /// Forgets the rate-limit bookkeeping — which notification fired when, for
    /// which Session.
    ///
    /// Called by Settings → Erase all data: the log those limits were computed
    /// against no longer exists, so keeping them would suppress notifications
    /// about data that has nothing to do with them.
    public func resetSchedulingHistory() {
        for key in [
            TallyDefaults.Keys.lastTrendAlertAt,
            TallyDefaults.Keys.lastTrendAlertSignature,
            TallyDefaults.Keys.lastStreakNudgeDay,
            TallyDefaults.Keys.lastPacingNudgeSessionID,
            TallyDefaults.Keys.lastPacingNudgeAt
        ] {
            TallyDefaults.remove(key)
        }
    }

    /// Drops one category's pending requests — what a Settings toggle going off
    /// should do immediately, rather than at the next foreground.
    public func cancel(_ category: TallyNotificationCategory) async {
        let prefix = category.identifier
        let identifiers = await center.pendingIdentifiers().filter { $0.hasPrefix(prefix) }
        guard !identifiers.isEmpty else { return }
        center.cancel(identifiers: identifiers)
    }

    /// Applies a toggle change straight away: schedule what turned on, retract
    /// what turned off.
    public func categoryToggleChanged(_ category: TallyNotificationCategory, context: ModelContext) async {
        if settings.isEnabled(category) {
            await refresh(context: context)
        } else {
            await cancel(category)
        }
    }

    // MARK: - Gating

    /// SPEC §9: "loud categories always go through the primer" — so only the
    /// digest may ride on provisional authorization.
    private func canSchedule(_ category: TallyNotificationCategory, status: PermissionStatus) -> Bool {
        guard category.isImplemented, settings.isEnabled(category) else { return false }
        if status == .authorized { return true }
        if status == .provisional { return category.mayDeliverProvisionally }
        return false
    }

    /// Applies the category's quiet-hours policy (SPEC §5).
    ///
    /// - Returns: when to deliver, or `nil` when the notification should be
    ///   dropped rather than deferred.
    func deliveryDate(for proposed: Date, category: TallyNotificationCategory) -> Date? {
        let quietHours = settings.quietHours
        switch category.quietHoursPolicy {
        case .ignore:
            return proposed
        case .postpone:
            return quietHours.deliveryDate(for: proposed, calendar: calendar)
        case .drop:
            return quietHours.contains(proposed, calendar: calendar) ? nil : proposed
        }
    }

    // MARK: - Request plumbing

    private func requestIdentifier(_ category: TallyNotificationCategory, suffix: String) -> String {
        "\(category.identifier).\(suffix)"
    }

    /// - Parameter text: title, subtitle, and body as the category's copy split
    ///   them. Every category goes through `NotificationText` rather than two
    ///   loose strings, which is what keeps a second sentence out of the body —
    ///   SPEC §2's clamp rule, applied to SPEC §5's categories too.
    private func makeContent(
        category: TallyNotificationCategory,
        text: NotificationText,
        sound: UNNotificationSound? = .default
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.apply(text)
        content.sound = sound
        content.categoryIdentifier = category.identifier
        // Groups a category's notifications together in Notification Centre.
        content.threadIdentifier = category.identifier
        content.userInfo = ["tallyCategory": category.rawValue]
        return content
    }

    private func schedule(identifier: String, content: UNNotificationContent, at date: Date) async {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        await center.schedule(request)
    }

    private func dayKey(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {

    /// Foreground delivery. A pacing nudge while the app is open is still worth
    /// showing — the user may be looking at the counter, not at the banner.
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        var userInfo: [String: String] = [:]
        for (key, value) in request.content.userInfo {
            guard let key = key as? String else { continue }
            userInfo[key] = String(describing: value)
        }

        let action = NotificationAction(
            categoryIdentifier: request.content.categoryIdentifier,
            actionIdentifier: response.actionIdentifier,
            requestIdentifier: request.identifier,
            userInfo: userInfo
        )

        Task { @MainActor in
            self.actionHandler?(action)
            completionHandler()
        }
    }
}
