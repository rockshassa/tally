import Foundation
import SwiftData
import TallyKit
import UserNotifications

/// SPEC §2's mid-session reminder: an hour (configurable) after the last drink
/// of a running session, one quiet *"anything to add?"* with a **+1 drink**
/// action.
///
/// **Why this is not Bar Radar's job any more.** The reminder used to hang off
/// a Tier 1 visit — it only armed while the user was inside the geofence of a
/// venue they had been to three times in 90 days. Every other session (a
/// discovered bar, a venue picked from the "start a session?" picker, an
/// untagged night, or anyone without Always location) never got one, which in
/// practice was most of them. The trigger is now the session itself: if one is
/// running, the clock runs from its last drink.
///
/// **One per silent stretch.** Every change to the log re-plans from scratch:
/// cancel whatever is pending, schedule one reminder at `last drink + delay`.
/// A drink resets the clock; silence after the reminder earns nothing more,
/// and the session closes itself three hours after its last drink anyway.
///
/// **Every log path.** The store's `didSave` is observed, so drinks from the
/// app, the widget, the watch, and the notification "+1 drink" action all
/// reset the clock without knowing this exists — and undoing the last drink
/// moves it back.
@MainActor
public final class SessionReminderScheduler {

    public static let shared = SessionReminderScheduler()

    private let center: any UserNotificationScheduling
    private let settings: TallySettings
    private let history: NotificationHistory
    private let deriver = SessionDeriver()

    private var modelContext: ModelContext?
    private var saveObserver: (any NSObjectProtocol)?

    /// Where the exits that close a session early come from. Injected so the
    /// scheduler stays testable without a running Bar Radar.
    var venueExits: () -> [SessionDeriver.VenueExit] = { RadarService.shared.venueExits() }

    init(
        center: (any UserNotificationScheduling)? = nil,
        settings: TallySettings? = nil,
        history: NotificationHistory? = nil
    ) {
        self.center = center ?? UNUserNotificationCenter.current()
        self.settings = settings ?? .shared
        self.history = history ?? .shared
    }

    // MARK: - Integrator surface

    /// Called once at launch with the app's main context.
    public func start(modelContext: ModelContext) {
        self.modelContext = modelContext
        if saveObserver == nil {
            saveObserver = NotificationCenter.default.addObserver(
                forName: ModelContext.didSave,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in await self?.reschedule() }
            }
        }
        Task { await reschedule() }
    }

    /// "Not drinking tonight" on the reminder: stay quiet for the rest of this
    /// session. The next session starts fresh.
    public func declineActiveSession(now: Date = Date()) {
        if let session = activeSession(asOf: now) {
            TallyDefaults.set(session.id.uuidString, forKey: TallyDefaults.Keys.declinedSessionReminderSessionID)
        }
        Task { await reschedule(now: now) }
    }

    /// Re-plans the one pending reminder. Cheap, idempotent, and safe to call
    /// from anywhere — the settings screen calls it when the interval or the
    /// toggle changes.
    public func reschedule(now: Date = Date()) async {
        let pending = await center.pendingIdentifiers()
            .filter { $0.hasPrefix(TallyNotificationCategory.sessionReminder.identifier) }
        if !pending.isEmpty { center.cancel(identifiers: pending) }

        guard settings.isEnabled(.sessionReminder) else { return }

        guard let plan = Self.plan(
            session: activeSession(asOf: now),
            delay: Self.delay(minutes: settings.sessionReminderMinutes),
            declinedSessionID: TallyDefaults.string(forKey: TallyDefaults.Keys.declinedSessionReminderSessionID)
                .flatMap(UUID.init(uuidString:)),
            now: now
        ) else { return }

        // A loud category: it never rides on provisional authorization.
        guard await center.currentAuthorization() == .authorized else { return }

        let venueName = plan.venueID.flatMap(venueName(for:))
        let request = Self.request(for: plan, venueName: venueName, now: now)
        await center.schedule(request)

        history.recordScheduled(
            category: NotificationRecordCategory(.sessionReminder),
            requestIdentifier: request.identifier,
            title: request.content.title,
            body: request.content.body,
            venueName: venueName,
            scheduledAt: plan.fireAt,
            now: now
        )
    }

    // MARK: - Planning

    public struct Plan: Hashable, Sendable {
        public let sessionID: UUID
        public let venueID: UUID?
        public let fireAt: Date
    }

    static func delay(minutes: Int) -> TimeInterval {
        TimeInterval(max(1, minutes) * 60)
    }

    /// Whether a reminder is due for this session, and when.
    ///
    /// Nothing when there is no running session, when the user declined it,
    /// when the moment has already passed (the reminder for that stretch was
    /// had, or the app was not around to schedule it — either way, firing late
    /// the instant the app wakes is worse than silence), or when the session
    /// will have closed by then.
    static func plan(
        session: DerivedSession?,
        delay: TimeInterval,
        declinedSessionID: UUID?,
        now: Date
    ) -> Plan? {
        guard let session, session.id != declinedSessionID else { return nil }

        let fireAt = session.endedAt.addingTimeInterval(delay)
        guard fireAt > now, fireAt < session.closesAt else { return nil }

        return Plan(sessionID: session.id, venueID: session.venueID, fireAt: fireAt)
    }

    /// Delivered under the `sessionReminder` category with a Bar Radar payload,
    /// so its **+1 drink** and **Not drinking tonight** buttons go down the
    /// same action path they always have.
    static func request(for plan: Plan, venueName: String?, now: Date) -> UNNotificationRequest {
        let name = venueName ?? ""
        let text = RadarCopy.SessionReminder.text(name)

        let content = UNMutableNotificationContent()
        content.apply(text)
        content.sound = .default
        content.categoryIdentifier = TallyNotificationCategory.sessionReminder.identifier
        content.threadIdentifier = TallyNotificationCategory.sessionReminder.identifier
        content.userInfo = RadarActionPayload(
            kind: .sessionReminder,
            venueID: plan.venueID,
            placeName: name
        ).userInfo

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, plan.fireAt.timeIntervalSince(now)),
            repeats: false
        )
        return UNNotificationRequest(
            identifier: "\(TallyNotificationCategory.sessionReminder.identifier).\(plan.sessionID.uuidString)",
            content: content,
            trigger: trigger
        )
    }

    // MARK: - Store

    private func activeSession(asOf now: Date) -> DerivedSession? {
        guard
            let modelContext,
            let events = try? EventStore.snapshots(in: modelContext),
            let materialized = try? EventStore.materializedSessions(in: modelContext)
        else { return nil }

        return deriver.activeSession(
            events: events,
            materialized: materialized,
            venueExits: venueExits(),
            asOf: now
        )
    }

    private func venueName(for id: UUID) -> String? {
        guard let modelContext, let venue = try? EventStore.venue(id: id, in: modelContext) else { return nil }
        let name = venue.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
