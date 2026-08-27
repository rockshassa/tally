import Foundation
import Testing
@testable import tally

/// SPEC §5's notification history, as pure logic.
///
/// > Every notification the app schedules or delivers is recorded on-device …
/// > the log is derived from a rolling 30-day store, never synced, and cleared
/// > by erase-all.
///
/// Everything asserted here runs without a notification centre, a store, or a
/// clock it did not bring: `NotificationHistory` takes its storage as two
/// closures and its `now` as a parameter, precisely so this file can exist.
///
/// **Target setup (integrator):** written but not yet wired, exactly like
/// `tallyTests/Radar/`. `tallyTests` needs a unit-test bundle target in
/// `tally.xcodeproj` with `TEST_HOST` set to the app; agents are not allowed to
/// touch `project.pbxproj`. Nothing in this file changes when it lands.

// MARK: - Fixtures

private enum HistoryFixture {

    /// Fixed and UTC: a day boundary is what half of this file asserts on, and
    /// it must not depend on where the machine running it is standing.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    /// 2026-03-14 21:00 UTC.
    static var reference: Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: 14, hour: 21))!
    }

    static func date(_ offsetHours: Double, from base: Date = reference) -> Date {
        base.addingTimeInterval(offsetHours * 3600)
    }

    static func record(
        category: TallyNotificationCategory = .weeklyDigest,
        identifier: String? = "tally.category.weeklyDigest.next",
        title: String = "Your week",
        body: String = "12 drinks this week, down 3 from last.",
        venueName: String? = nil,
        scheduledAt: Date? = nil,
        deliveredAt: Date? = nil,
        outcome: NotificationOutcome = .scheduled,
        recordedAt: Date = reference
    ) -> NotificationRecord {
        NotificationRecord(
            category: NotificationRecordCategory(category),
            requestIdentifier: identifier,
            title: title,
            body: body,
            venueName: venueName,
            scheduledAt: scheduledAt,
            deliveredAt: deliveredAt,
            outcome: outcome,
            recordedAt: recordedAt
        )
    }
}

// MARK: - Append & query

@Suite("Notification history — append and query")
struct NotificationHistoryAppendTests {

    @Test("An appended record comes back")
    func appendRoundTrips() {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference

        history.record(HistoryFixture.record(recordedAt: now), now: now)

        let records = history.records(asOf: now)
        #expect(records.count == 1)
        #expect(records.first?.title == "Your week")
        #expect(records.first?.outcome == .scheduled)
    }

    @Test("Records come back newest first")
    func reverseChronological() {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference

        for (index, hours) in [-5.0, -1.0, -3.0].enumerated() {
            history.record(
                HistoryFixture.record(
                    identifier: "request.\(index)",
                    title: "Notification \(index)",
                    deliveredAt: HistoryFixture.date(hours),
                    outcome: .delivered,
                    recordedAt: HistoryFixture.date(hours)
                ),
                now: now
            )
        }

        let titles = history.records(asOf: now).map(\.title)
        #expect(titles == ["Notification 1", "Notification 2", "Notification 0"])
    }

    @Test("Records with different identifiers never collapse")
    func distinctIdentifiersAppend() {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference

        history.record(HistoryFixture.record(identifier: "a", recordedAt: now), now: now)
        history.record(HistoryFixture.record(identifier: "b", recordedAt: now), now: now)

        #expect(history.records(asOf: now).count == 2)
    }

    @Test("A record with no identifier always appends")
    func anonymousRecordsAppend() {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference

        history.record(HistoryFixture.record(identifier: nil, recordedAt: now), now: now)
        history.record(HistoryFixture.record(identifier: nil, recordedAt: now), now: now)

        #expect(history.records(asOf: now).count == 2)
    }

    @Test("Clearing empties the log")
    func clearEmpties() {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference

        history.record(HistoryFixture.record(recordedAt: now), now: now)
        history.clear()

        #expect(history.records(asOf: now).isEmpty)
        #expect(history.isEmpty(asOf: now))
    }

    @Test("The filter splits delivered from suppressed")
    func filters() {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference

        history.record(
            HistoryFixture.record(identifier: "sent", outcome: .delivered, recordedAt: now),
            now: now
        )
        history.record(
            HistoryFixture.record(identifier: "held", outcome: .suppressed(.categoryOff), recordedAt: now),
            now: now
        )
        history.record(
            HistoryFixture.record(identifier: "tapped", outcome: .opened, recordedAt: now),
            now: now
        )

        #expect(history.records(matching: .all, asOf: now).count == 3)
        #expect(history.records(matching: .delivered, asOf: now).count == 2)
        #expect(history.records(matching: .suppressed, asOf: now).count == 1)
        #expect(history.records(matching: .suppressed, asOf: now).first?.requestIdentifier == "held")
    }
}

// MARK: - Pruning

@Suite("Notification history — 30-day retention and the hard cap")
struct NotificationHistoryPruneTests {

    @Test("A record exactly 30 days old is kept")
    func thirtyDayBoundaryKeeps() {
        let now = HistoryFixture.reference
        let edge = now.addingTimeInterval(-NotificationHistory.retention)

        let kept = NotificationHistory.pruned([HistoryFixture.record(recordedAt: edge)], asOf: now)
        #expect(kept.count == 1)
    }

    @Test("A record a second past 30 days is dropped")
    func thirtyDayBoundaryDrops() {
        let now = HistoryFixture.reference
        let stale = now.addingTimeInterval(-NotificationHistory.retention - 1)

        let kept = NotificationHistory.pruned([HistoryFixture.record(recordedAt: stale)], asOf: now)
        #expect(kept.isEmpty)
    }

    @Test("Retention is measured on when the record was written, not on when it fires")
    func retentionIgnoresFutureFireDates() {
        let now = HistoryFixture.reference
        let stale = now.addingTimeInterval(-NotificationHistory.retention - 60)

        // Scheduled for next Sunday, written five weeks ago: the fire date must
        // not make it immortal.
        let record = HistoryFixture.record(
            scheduledAt: now.addingTimeInterval(24 * 3600),
            recordedAt: stale
        )

        #expect(NotificationHistory.pruned([record], asOf: now).isEmpty)
    }

    @Test("Writing prunes what has expired")
    func writePrunes() {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference
        let old = now.addingTimeInterval(-NotificationHistory.retention - 3600)

        history.record(HistoryFixture.record(identifier: "old", recordedAt: old), now: old)
        #expect(history.records(asOf: old).count == 1)

        history.record(HistoryFixture.record(identifier: "new", recordedAt: now), now: now)

        let records = history.records(asOf: now)
        #expect(records.count == 1)
        #expect(records.first?.requestIdentifier == "new")
    }

    @Test("The log never grows past the cap, and it is the newest that survive")
    func hardCap() {
        let now = HistoryFixture.reference
        let overflow = NotificationHistory.maxRecords + 25

        let records = (0..<overflow).map { index in
            HistoryFixture.record(
                identifier: "request.\(index)",
                title: "Notification \(index)",
                recordedAt: now.addingTimeInterval(Double(index))
            )
        }

        let kept = NotificationHistory.pruned(records, asOf: now.addingTimeInterval(Double(overflow)))
        #expect(kept.count == NotificationHistory.maxRecords)
        #expect(kept.first?.title == "Notification 25")
        #expect(kept.last?.title == "Notification \(overflow - 1)")
    }

    @Test("The cap holds across writes")
    func capHoldsAcrossWrites() {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference

        for index in 0..<(NotificationHistory.maxRecords + 10) {
            history.record(
                HistoryFixture.record(identifier: "request.\(index)", recordedAt: now),
                now: now
            )
        }

        #expect(history.allRecords().count == NotificationHistory.maxRecords)
    }
}

// MARK: - Grouping

@Suite("Notification history — grouped by day")
struct NotificationHistoryGroupingTests {

    @Test("Each local day is one group, newest day first")
    func groupsByDay() {
        let calendar = HistoryFixture.calendar
        let now = HistoryFixture.reference

        let records = [
            HistoryFixture.record(identifier: "today.late", deliveredAt: HistoryFixture.date(-1), outcome: .delivered),
            HistoryFixture.record(identifier: "today.early", deliveredAt: HistoryFixture.date(-6), outcome: .delivered),
            HistoryFixture.record(identifier: "yesterday", deliveredAt: HistoryFixture.date(-26), outcome: .delivered),
            HistoryFixture.record(identifier: "before", deliveredAt: HistoryFixture.date(-50), outcome: .delivered)
        ]

        let days = NotificationHistory.grouped(records, calendar: calendar)

        #expect(days.count == 3)
        #expect(days.map(\.records.count) == [2, 1, 1])
        #expect(days[0].date > days[1].date)
        #expect(days[1].date > days[2].date)
        #expect(days[0].title(asOf: now, calendar: calendar) == "Today")
        #expect(days[1].title(asOf: now, calendar: calendar) == "Yesterday")
        #expect(days[2].title(asOf: now, calendar: calendar) != "Yesterday")
    }

    @Test("Inside a day, the newest record is first")
    func recordsWithinADayAreReversed() {
        let days = NotificationHistory.grouped(
            [
                HistoryFixture.record(identifier: "early", title: "Early", deliveredAt: HistoryFixture.date(-6), outcome: .delivered),
                HistoryFixture.record(identifier: "late", title: "Late", deliveredAt: HistoryFixture.date(-1), outcome: .delivered)
            ],
            calendar: HistoryFixture.calendar
        )

        #expect(days.first?.records.map(\.title) == ["Late", "Early"])
    }

    @Test("A record with no delivery falls back to when it was written")
    func occurredAtFallsBack() {
        let scheduled = HistoryFixture.record(scheduledAt: HistoryFixture.date(3), recordedAt: HistoryFixture.date(-2))
        #expect(scheduled.occurredAt == HistoryFixture.date(3))

        let suppressed = HistoryFixture.record(
            outcome: .suppressed(.categoryOff),
            recordedAt: HistoryFixture.date(-2)
        )
        #expect(suppressed.occurredAt == HistoryFixture.date(-2))
    }

    @Test("Grouping through the store applies the filter")
    func groupedRespectsFilter() {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference

        history.record(
            HistoryFixture.record(identifier: "sent", deliveredAt: now, outcome: .delivered, recordedAt: now),
            now: now
        )
        history.record(
            HistoryFixture.record(identifier: "held", outcome: .suppressed(.weeklyCap), recordedAt: now),
            now: now
        )

        let suppressed = history.groupedByDay(matching: .suppressed, asOf: now, calendar: HistoryFixture.calendar)
        #expect(suppressed.count == 1)
        #expect(suppressed.first?.records.count == 1)
        #expect(suppressed.first?.records.first?.requestIdentifier == "held")
    }
}

// MARK: - Outcome transitions

@Suite("Notification history — one notification, one row")
struct NotificationHistoryOutcomeTests {

    @Test("Scheduled, then delivered, then tapped is a single record")
    func outcomeAdvancesInPlace() throws {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference
        let identifier = "tally.category.barRadarArrival.visit"

        history.recordScheduled(
            category: NotificationRecordCategory(.barRadarArrival),
            requestIdentifier: identifier,
            title: "Looks like you're at The Anchor",
            body: "Start a Session?",
            venueName: "The Anchor",
            scheduledAt: HistoryFixture.date(-2),
            now: HistoryFixture.date(-2)
        )
        history.recordOutcome(
            .delivered,
            requestIdentifier: identifier,
            category: NotificationRecordCategory(.barRadarArrival),
            title: "Looks like you're at The Anchor",
            body: "Start a Session?",
            at: HistoryFixture.date(-1),
            now: HistoryFixture.date(-1)
        )
        history.recordOutcome(
            .actionTaken(identifier: "tally.radar.action.logDrink"),
            requestIdentifier: identifier,
            category: NotificationRecordCategory(.barRadarArrival),
            title: "Looks like you're at The Anchor",
            body: "Start a Session?",
            at: now,
            now: now
        )

        let records = history.records(asOf: now)
        #expect(records.count == 1)

        let record = try #require(records.first)
        #expect(record.outcome == .actionTaken(identifier: "tally.radar.action.logDrink"))
        #expect(record.scheduledAt == HistoryFixture.date(-2))
        #expect(record.deliveredAt == now)
        // The venue survives an outcome update that did not carry one.
        #expect(record.venueName == "The Anchor")
    }

    @Test("A repeated standing decision is one row, not fifty")
    func standingDecisionsCollapse() {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference

        for hour in stride(from: -10.0, through: 0.0, by: 1.0) {
            history.recordSuppressed(
                .categoryOff,
                category: NotificationRecordCategory(.weeklyDigest),
                requestIdentifier: "tally.category.weeklyDigest.next",
                title: "Your week",
                body: "12 drinks this week.",
                now: HistoryFixture.date(hour)
            )
        }

        let records = history.records(asOf: now)
        #expect(records.count == 1)
        #expect(records.first?.outcome == .suppressed(.categoryOff))
        #expect(records.first?.updatedAt == now)
    }

    @Test("Rescheduling the same request does not stack rows")
    func reschedulingCollapses() {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference

        history.recordScheduled(
            category: NotificationRecordCategory(.sessionTrueUp),
            requestIdentifier: "tally.category.sessionTrueUp.session",
            title: "Session at The Anchor ended",
            scheduledAt: HistoryFixture.date(1),
            now: HistoryFixture.date(-2)
        )
        history.recordScheduled(
            category: NotificationRecordCategory(.sessionTrueUp),
            requestIdentifier: "tally.category.sessionTrueUp.session",
            title: "Session at The Anchor ended",
            scheduledAt: HistoryFixture.date(3),
            now: now
        )

        let records = history.records(asOf: now)
        #expect(records.count == 1)
        #expect(records.first?.scheduledAt == HistoryFixture.date(3))
    }

    @Test("A rate limit never overwrites the notification it limited")
    func rateLimitDoesNotOverwriteDelivery() {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference
        let identifier = "tally.category.pacingNudge.session"

        history.recordScheduled(
            category: NotificationRecordCategory(.pacingNudge),
            requestIdentifier: identifier,
            title: "Time for a spacer?",
            scheduledAt: HistoryFixture.date(-2),
            now: HistoryFixture.date(-2)
        )
        history.recordSuppressed(
            .onePerVisit,
            category: NotificationRecordCategory(.pacingNudge),
            requestIdentifier: identifier,
            title: "Time for a spacer?",
            now: now
        )

        let records = history.records(asOf: now)
        #expect(records.count == 1)
        #expect(records.first?.outcome == .scheduled)
    }

    @Test("A category turned off does supersede a pending schedule")
    func stateReasonSupersedesSchedule() {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference
        let identifier = "tally.category.weeklyDigest.next"

        history.recordScheduled(
            category: NotificationRecordCategory(.weeklyDigest),
            requestIdentifier: identifier,
            title: "Your week",
            scheduledAt: HistoryFixture.date(4),
            now: HistoryFixture.date(-2)
        )
        history.recordSuppressed(
            .categoryOff,
            category: NotificationRecordCategory(.weeklyDigest),
            requestIdentifier: identifier,
            title: "Your week",
            now: now
        )

        let records = history.records(asOf: now)
        #expect(records.count == 1)
        #expect(records.first?.outcome == .suppressed(.categoryOff))
    }

    @Test("Two deliveries of the same request are two rows")
    func secondDeliveryAppends() {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference
        let identifier = "tally.category.sessionReminder.visit"

        history.recordDelivered(
            category: NotificationRecordCategory(.sessionReminder),
            requestIdentifier: identifier,
            title: "Still at The Anchor",
            deliveredAt: HistoryFixture.date(-2),
            now: HistoryFixture.date(-2)
        )
        history.recordDelivered(
            category: NotificationRecordCategory(.sessionReminder),
            requestIdentifier: identifier,
            title: "Still at The Anchor",
            deliveredAt: now,
            now: now
        )

        // SPEC §2 allows two mid-Session reminders per visit under one
        // identifier; collapsing them would hide the second.
        #expect(history.records(asOf: now).count == 2)
    }

    @Test("One delivery seen by two observers is one row")
    func foregroundEchoCollapses() {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference
        let identifier = "tally.category.barRadarArrival.visit"

        // What `RadarService.deliver(_:fireDate:)` writes as it hands the prompt
        // over…
        history.recordDelivered(
            category: NotificationRecordCategory(.barRadarArrival),
            requestIdentifier: identifier,
            title: "Looks like you're at The Anchor",
            deliveredAt: now,
            now: now
        )
        // …and what the delegate writes a moment later, because the app happened
        // to be open when the banner landed.
        history.recordOutcome(
            .delivered,
            requestIdentifier: identifier,
            category: NotificationRecordCategory(.barRadarArrival),
            title: "Looks like you're at The Anchor",
            at: now.addingTimeInterval(2),
            now: now.addingTimeInterval(2)
        )

        #expect(history.records(asOf: now.addingTimeInterval(2)).count == 1)
    }

    @Test("Quiet hours turn a scheduled notification into a held one")
    func quietHoursRecordsAsHeld() throws {
        let history = NotificationHistory.ephemeral()
        let now = HistoryFixture.reference
        let release = HistoryFixture.date(11)

        history.recordScheduled(
            category: NotificationRecordCategory(.weeklyDigest),
            requestIdentifier: "tally.category.weeklyDigest.next",
            title: "Your week",
            scheduledAt: release,
            heldByQuietHoursUntil: release,
            now: now
        )

        let record = try #require(history.records(asOf: now).first)
        #expect(record.outcome == .suppressed(.quietHours(until: release)))
        #expect(record.isSuppressed)
        #expect(record.outcome.displayText.hasPrefix("Quiet hours — held until"))
    }

    @Test("The merge rule, case by case")
    func mergeDecisions() {
        typealias History = NotificationHistory

        #expect(History.decision(existing: .scheduled, new: .delivered) == .merge)
        #expect(History.decision(existing: .delivered, new: .opened) == .merge)
        #expect(History.decision(existing: .delivered, new: .delivered) == .append)
        #expect(History.decision(existing: .delivered, new: .delivered, separatedBy: 2) == .merge)
        #expect(
            History.decision(
                existing: .delivered,
                new: .delivered,
                separatedBy: NotificationHistory.deliveryEchoWindow + 1
            ) == .append
        )
        #expect(History.decision(existing: .opened, new: .delivered) == .append)
        #expect(History.decision(existing: .scheduled, new: .scheduled) == .merge)
        #expect(History.decision(existing: .delivered, new: .suppressed(.cooldown)) == .skip)
        #expect(History.decision(existing: .scheduled, new: .suppressed(.weeklyCap)) == .skip)
        #expect(History.decision(existing: .scheduled, new: .suppressed(.notAuthorized)) == .merge)
        #expect(
            History.decision(
                existing: .suppressed(.categoryOff),
                new: .suppressed(.quietHours(until: nil))
            ) == .merge
        )
    }
}

// MARK: - Coding

@Suite("Notification history — JSON round trips")
struct NotificationHistoryCodingTests {

    private func roundTrip(_ record: NotificationRecord) throws -> NotificationRecord {
        let data = try JSONEncoder().encode(record)
        return try JSONDecoder().decode(NotificationRecord.self, from: data)
    }

    @Test("Every suppression reason survives the trip", arguments: [
        NotificationSuppressionReason.quietHours(until: HistoryFixture.reference),
        .quietHours(until: nil),
        .categoryOff,
        .weeklyCap,
        .onePerVisit,
        .cooldown,
        .notAuthorized,
        .other(note: "Suppressed place")
    ])
    func suppressionReasonsRoundTrip(reason: NotificationSuppressionReason) throws {
        let record = try roundTrip(
            HistoryFixture.record(outcome: .suppressed(reason))
        )
        #expect(record.outcome == .suppressed(reason))
        #expect(record.outcome.suppressionReason?.displayText == reason.displayText)
    }

    @Test("Every outcome survives the trip", arguments: [
        NotificationOutcome.scheduled,
        .delivered,
        .opened,
        .dismissed,
        .actionTaken(identifier: "tally.radar.action.logDrink"),
        .suppressed(.categoryOff)
    ])
    func outcomesRoundTrip(outcome: NotificationOutcome) throws {
        #expect(try roundTrip(HistoryFixture.record(outcome: outcome)).outcome == outcome)
    }

    @Test("The whole record survives the trip")
    func recordRoundTrips() throws {
        let original = HistoryFixture.record(
            category: .barRadarDiscovery,
            identifier: "tally.category.barRadarDiscovery.visit",
            title: "Looks like you're at The Salty Dog",
            body: "Start a Session?",
            venueName: "The Salty Dog",
            scheduledAt: HistoryFixture.date(-3),
            deliveredAt: HistoryFixture.date(-2),
            outcome: .suppressed(.quietHours(until: HistoryFixture.date(11)))
        )

        #expect(try roundTrip(original) == original)
    }

    @Test("A reason written by a newer build decodes as itself")
    func unknownReasonSurvives() throws {
        let json = Data(#"{"kind":"solarFlare"}"#.utf8)
        let reason = try JSONDecoder().decode(NotificationSuppressionReason.self, from: json)
        #expect(reason == .other(note: "solarFlare"))
    }

    @Test("A log the decoder cannot read is empty, not fatal")
    func corruptStorageReadsEmpty() {
        let box = LockedBox()
        let history = NotificationHistory(
            read: { _ in Data("not json".utf8) },
            write: { data, _ in box.data = data }
        )
        #expect(history.allRecords().isEmpty)
    }

    /// A trivial `Sendable` box, so the closures above can capture something.
    private final class LockedBox: @unchecked Sendable {
        var data: Data?
    }
}

// MARK: - Category labels

@Suite("Notification history — category labels")
struct NotificationHistoryCategoryTests {

    @Test("A known category reads as its Settings title")
    func knownCategory() {
        let category = NotificationRecordCategory(.barRadarArrival)
        #expect(category.known == .barRadarArrival)
        #expect(category.displayName == TallyNotificationCategory.barRadarArrival.title)
        #expect(category.isRadarFamily)
    }

    @Test("An unknown label still reads as a sentence")
    func unknownCategory() {
        let category = NotificationRecordCategory(rawValue: "barRadarQuizNight")
        #expect(category.known == nil)
        #expect(category.displayName == "Bar radar quiz night")
        #expect(category.systemImageName == "bell")
        #expect(!category.isRadarFamily)
    }

    @Test("A category label encodes as a plain string")
    func categoryEncodesFlat() throws {
        let data = try JSONEncoder().encode(NotificationRecordCategory(.pacingNudge))
        #expect(String(decoding: data, as: UTF8.self) == "\"pacingNudge\"")
    }

    @Test("An action identifier reads as what was tapped")
    func actionLabel() {
        #expect(NotificationOutcome.actionTaken(identifier: "tally.radar.action.logDrink").displayText == "Tapped log drink")
    }
}
