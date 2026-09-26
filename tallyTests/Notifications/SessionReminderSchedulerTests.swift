import Foundation
import SwiftData
import TallyKit
import Testing
import UserNotifications
@testable import tally

/// SPEC §2's mid-session reminder, for every session.
///
/// It used to arm only inside a Bar Radar Tier 1 geofence, so a session at a
/// discovered bar, a venue picked from "start a session?", or an untagged
/// night never got one. These pin the new rule: one reminder, one interval
/// after the last drink, for as long as the session is still open.
@Suite("Session reminder — an hour after the last drink", .serialized)
@MainActor
struct SessionReminderSchedulerTests {

    private let hour: TimeInterval = 60 * 60

    // MARK: - Planning

    private func session(lastDrinkAt last: Date, venueID: UUID? = nil) throws -> DerivedSession {
        let context = ModelContext(try TallyStore.makeInMemoryContainer())
        var venue: Venue?
        if let venueID {
            let v = Venue(id: venueID, name: "The Anchor", category: .bar)
            context.insert(v)
            venue = v
        }
        try EventStore.logDrink(type: .alcoholic, timestamp: last.addingTimeInterval(-1_800), venue: venue, in: context)
        try EventStore.logDrink(type: .alcoholic, timestamp: last, venue: venue, in: context)
        return try #require(try SessionDeriver().derive(in: context).last)
    }

    @Test("Due one interval after the last drink")
    func dueAfterLastDrink() throws {
        let now = Date()
        let last = now.addingTimeInterval(-10 * 60)
        let session = try session(lastDrinkAt: last)

        let plan = try #require(
            SessionReminderScheduler.plan(session: session, delay: hour, declinedSessionID: nil, now: now)
        )
        #expect(plan.sessionID == session.id)
        #expect(plan.fireAt == last.addingTimeInterval(hour))
    }

    @Test("Works for an untagged session — no Bar Radar visit required")
    func untaggedSession() throws {
        let now = Date()
        let session = try session(lastDrinkAt: now)
        #expect(session.venueID == nil)
        #expect(SessionReminderScheduler.plan(session: session, delay: hour, declinedSessionID: nil, now: now) != nil)
    }

    @Test("Carries the session's venue")
    func carriesVenue() throws {
        let now = Date()
        let venueID = UUID()
        let session = try session(lastDrinkAt: now, venueID: venueID)

        let plan = SessionReminderScheduler.plan(session: session, delay: hour, declinedSessionID: nil, now: now)
        #expect(plan?.venueID == venueID)
    }

    @Test("Nothing when there is no session")
    func noSession() {
        #expect(SessionReminderScheduler.plan(session: nil, delay: hour, declinedSessionID: nil, now: Date()) == nil)
    }

    @Test("Nothing once the moment has passed — no late reminder on wake")
    func passedMoment() throws {
        let now = Date()
        let session = try session(lastDrinkAt: now.addingTimeInterval(-90 * 60))
        #expect(SessionReminderScheduler.plan(session: session, delay: hour, declinedSessionID: nil, now: now) == nil)
    }

    @Test("Nothing that would land after the session closes")
    func afterClose() throws {
        let now = Date()
        let session = try session(lastDrinkAt: now)
        // The session closes three hours after its last drink.
        #expect(SessionReminderScheduler.plan(session: session, delay: 3 * hour, declinedSessionID: nil, now: now) == nil)
    }

    @Test("Nothing for a session the user declined")
    func declined() throws {
        let now = Date()
        let session = try session(lastDrinkAt: now)
        #expect(SessionReminderScheduler.plan(session: session, delay: hour, declinedSessionID: session.id, now: now) == nil)
    }

    // MARK: - The request

    @Test("Names the venue when there is one, and still reads right without")
    func copy() {
        let plan = SessionReminderScheduler.Plan(sessionID: UUID(), venueID: nil, fireAt: Date().addingTimeInterval(hour))

        let tagged = SessionReminderScheduler.request(for: plan, venueName: "The Anchor", now: Date())
        #expect(tagged.content.title == "Still at The Anchor")
        #expect(tagged.content.body == "Anything to add?")

        let untagged = SessionReminderScheduler.request(for: plan, venueName: nil, now: Date())
        #expect(untagged.content.title == "Session in progress")
        #expect(untagged.content.body == "Anything to add?")
    }

    @Test("Delivered with the +1 drink actions and a payload Radar's handler reads")
    func actionable() throws {
        let venueID = UUID()
        let plan = SessionReminderScheduler.Plan(sessionID: UUID(), venueID: venueID, fireAt: Date().addingTimeInterval(hour))
        let request = SessionReminderScheduler.request(for: plan, venueName: "The Anchor", now: Date())

        #expect(request.content.categoryIdentifier == TallyNotificationCategory.sessionReminder.identifier)
        #expect(request.identifier == "\(TallyNotificationCategory.sessionReminder.identifier).\(plan.sessionID.uuidString)")

        let userInfo = request.content.userInfo.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String { result[key] = String(describing: pair.value) }
        }
        let payload = try #require(RadarActionPayload(userInfo: userInfo))
        #expect(payload.kind == .sessionReminder)
        #expect(payload.venueID == venueID)

        let trigger = try #require(request.trigger as? UNTimeIntervalNotificationTrigger)
        #expect(abs(trigger.timeInterval - hour) < 5)
    }

    // MARK: - Scheduling

    @Test("A logged drink schedules exactly one reminder, replacing any pending")
    func schedulesOne() async throws {
        let center = FakeNotificationCenter()
        center.pending = ["tally.category.sessionReminder.stale", "tally.category.pacingNudge.other"]

        let settings = TallySettings.shared
        let wasEnabled = settings.isEnabled(.sessionReminder)
        settings.setEnabled(true, for: .sessionReminder)
        defer { settings.setEnabled(wasEnabled, for: .sessionReminder) }

        let history = NotificationHistory.ephemeral()
        let scheduler = SessionReminderScheduler(center: center, settings: settings, history: history)
        scheduler.venueExits = { [] }

        let context = ModelContext(try TallyStore.makeInMemoryContainer())
        try EventStore.logDrink(type: .alcoholic, timestamp: Date(), in: context)
        scheduler.start(modelContext: context)
        await scheduler.reschedule()

        #expect(center.cancelled.contains("tally.category.sessionReminder.stale"))
        #expect(!center.cancelled.contains("tally.category.pacingNudge.other"))
        #expect(center.scheduled.last?.content.categoryIdentifier == TallyNotificationCategory.sessionReminder.identifier)
    }

    @Test("Toggled off: nothing is scheduled")
    func toggledOff() async throws {
        let center = FakeNotificationCenter()

        let settings = TallySettings.shared
        let wasEnabled = settings.isEnabled(.sessionReminder)
        settings.setEnabled(false, for: .sessionReminder)
        defer { settings.setEnabled(wasEnabled, for: .sessionReminder) }

        let history = NotificationHistory.ephemeral()
        let scheduler = SessionReminderScheduler(center: center, settings: settings, history: history)
        scheduler.venueExits = { [] }

        let context = ModelContext(try TallyStore.makeInMemoryContainer())
        try EventStore.logDrink(type: .alcoholic, timestamp: Date(), in: context)
        scheduler.start(modelContext: context)
        await scheduler.reschedule()

        #expect(center.scheduled.isEmpty)
    }
}

/// Records what the scheduler asks of the notification centre.
@MainActor
private final class FakeNotificationCenter: UserNotificationScheduling {
    var authorization: PermissionStatus = .authorized
    var pending: [String] = []
    var scheduled: [UNNotificationRequest] = []
    var cancelled: [String] = []

    func currentAuthorization() async -> PermissionStatus { authorization }
    func schedule(_ request: UNNotificationRequest) async {
        scheduled.append(request)
        pending.append(request.identifier)
    }
    func cancel(identifiers: [String]) {
        cancelled += identifiers
        pending.removeAll { identifiers.contains($0) }
    }
    func cancelAllPending() { pending.removeAll() }
    func pendingIdentifiers() async -> [String] { pending }
    func replaceCategories(_ categories: Set<UNNotificationCategory>) {}
    func assignDelegate(_ delegate: any UNUserNotificationCenterDelegate) {}
}
