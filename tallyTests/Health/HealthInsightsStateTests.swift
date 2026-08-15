import Foundation
import Testing
import TallyKit
import UserNotifications
@testable import tally

/// The other half of PLAN Gate 3's SPEC §4 line — *"revoking the read permission
/// removes every insight surface and nothing else"* — plus SPEC §5's *"at most
/// one per week"* cap on the Activity insight category.
///
/// The state mapping is a static pure function precisely so it can be asserted
/// here without a view, a scene phase, or a HealthKit dialog.
///
/// **Target setup (integrator):** as with `tallyTests/Sync/`, these files are
/// written but not yet wired — `tallyTests` needs a unit-test bundle target in
/// `tally.xcodeproj`, which Wave 3 agents are not allowed to add.
/// Collects what the scheduler tried to send. A reference type so the injected
/// closure can record into it without capturing a mutable local.
@MainActor
final class ScheduledRequests {
    var identifiers: [String] = []
}

@Suite("Health — insight surfaces")
@MainActor
struct HealthInsightsStateTests {

    // MARK: Fixtures

    private static let comparison = HealthInsightComparison(
        metric: .exerciseMinutes,
        afterDrinking: 12,
        afterDry: 34,
        drinkingDayCount: 10,
        dryDayCount: 18,
        threshold: 3
    )

    private static let insight = HealthInsight(
        kind: .morningAfter,
        metric: .exerciseMinutes,
        headline: "Next-day exercise 65% lower",
        detail: "After 3+ drink Sessions, your next-day exercise averages 12 min vs your usual 34.",
        relativeChange: -0.647,
        sampleCount: 28,
        comparison: comparison
    )

    private static func report(
        insights: [HealthInsight],
        hasReadableActivity: Bool,
        meetsSampleFloor: Bool = true
    ) -> HealthInsightReport {
        HealthInsightReport(
            insights: insights,
            evidence: .init(
                drinkingComparisons: meetsSampleFloor ? 10 : 3,
                dryComparisons: meetsSampleFloor ? 18 : 4,
                metric: hasReadableActivity ? .exerciseMinutes : nil,
                meetsSampleFloor: meetsSampleFloor,
                hasReadableActivity: hasReadableActivity
            )
        )
    }

    // MARK: - State mapping

    @Test("Qualifying insights render as cards")
    func insightsRenderAsCards() {
        let state = HealthInsightsModel.state(
            for: Self.report(insights: [Self.insight], hasReadableActivity: true),
            hasAsked: true
        )
        #expect(state == .insights([Self.insight]))
    }

    @Test("Connected but under the guardrails renders nothing")
    func silenceWhenNothingQualifies() {
        // SPEC §4: "Absence is fine." Not an empty state, not a placeholder —
        // the slot is simply empty.
        let state = HealthInsightsModel.state(
            for: Self.report(insights: [], hasReadableActivity: true, meetsSampleFloor: false),
            hasAsked: true
        )
        #expect(state == .silent)
    }

    @Test("Never asked shows the Connect Health card")
    func neverAskedOffersConnect() {
        let state = HealthInsightsModel.state(
            for: Self.report(insights: [], hasReadableActivity: false),
            hasAsked: false
        )
        #expect(state == .connect(hasAsked: false))
    }

    @Test("Revoking reads removes every insight surface")
    func revocationFallsBackToConnect() {
        // The revoked case: the read sheet was shown, and HealthKit is now
        // returning nothing. It is indistinguishable from "this device has no
        // activity data" by design, and both want the same offer.
        let before = HealthInsightsModel.state(
            for: Self.report(insights: [Self.insight], hasReadableActivity: true),
            hasAsked: true
        )
        #expect(before == .insights([Self.insight]))

        let after = HealthInsightsModel.state(
            for: Self.report(insights: [], hasReadableActivity: false),
            hasAsked: true
        )
        #expect(after == .connect(hasAsked: true))

        // Nothing in that state carries an insight, a chart, or a number.
        if case .insights = after { Issue.record("Revocation left an insight surface behind") }
    }

    // MARK: - Fixture provider

    @Test("The fixture provider zero-fills the window it is asked for")
    func fixtureProviderFillsItsWindow() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_748_779_200))
        let start = calendar.date(byAdding: .day, value: -10, to: today)!

        let provider = FixtureHealthDataProvider(
            samples: [HealthDaySample(day: start, exerciseMinutes: 30, stepCount: 5_000)],
            calendar: calendar
        )

        let samples = await provider.dailyActivity(from: start, to: today, calendar: calendar)

        #expect(samples.count == 10)
        #expect(samples.first?.exerciseMinutes == 30)
        #expect(samples.first?.hasSignal == true)
        #expect(samples.dropFirst().allSatisfy { !$0.hasSignal })
        #expect(provider.readCount == 1)
    }

    @Test("Revoking a fixture's reads empties every answer")
    func fixtureRevocationEmptiesReads() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let today = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_748_779_200))
        let start = calendar.date(byAdding: .day, value: -5, to: today)!

        let provider = FixtureHealthDataProvider(
            samples: FixtureHealthDataProvider.days(
                endingAt: today,
                count: 6,
                exerciseMinutes: 30,
                calendar: calendar
            ),
            calendar: calendar
        )

        let before = await provider.dailyActivity(from: start, to: today, calendar: calendar)
        #expect(before.contains { $0.hasSignal })

        provider.revokeReads()

        let after = await provider.dailyActivity(from: start, to: today, calendar: calendar)
        #expect(after.allSatisfy { !$0.hasSignal })
    }

    // MARK: - Weekly notification cap

    @Test("Activity insights cap at one per rolling week")
    func weeklyCap() async {
        let category = TallyNotificationCategory.activityInsight

        let scheduled = ScheduledRequests()
        let scheduler = ActivityInsightScheduler(
            authorization: { .authorized },
            schedule: { request in scheduled.identifiers.append(request.identifier) }
        )
        scheduler.resetSchedulingHistory()
        defer { scheduler.resetSchedulingHistory() }

        let now = Date(timeIntervalSince1970: 1_748_779_200)

        // Until the integrator flips `isImplemented`, this category has no
        // Settings row, so scheduling it would be a notification the user cannot
        // turn off. Silence is the correct behaviour, and the assertion below is
        // what proves the gate is wired.
        guard category.isImplemented else {
            #expect(await scheduler.submit(Self.insight, now: now) == nil)
            #expect(scheduled.identifiers.isEmpty)
            return
        }

        TallySettings.shared.setEnabled(true, for: category)

        #expect(await scheduler.submit(Self.insight, now: now) != nil)
        #expect(scheduled.identifiers.count == 1)

        // Same finding, same week: nothing.
        #expect(await scheduler.submit(Self.insight, now: now.addingTimeInterval(3_600)) == nil)

        // A *different* finding, still inside the week: still nothing. The cap is
        // on the category, not on the finding.
        let other = HealthInsight(
            kind: .weeklyDrift,
            metric: .steps,
            headline: "Drinks 30% higher, step count 25% lower",
            detail: "Over the last four weeks your drinks are 30% higher while your step count is 25% lower.",
            relativeChange: -0.25,
            sampleCount: 4
        )
        #expect(await scheduler.submit(other, now: now.addingTimeInterval(2 * 86_400)) == nil)
        #expect(scheduled.identifiers.count == 1)

        // Eight days later, a new finding gets through.
        #expect(await scheduler.submit(other, now: now.addingTimeInterval(8 * 86_400)) != nil)
        #expect(scheduled.identifiers.count == 2)
    }

    @Test("Quiet hours postpone an insight rather than dropping it")
    func quietHoursPostpone() {
        // SPEC §5: quiet hours apply to this category, and its declared policy is
        // `postpone` — a 90-day correlation is just as true after breakfast.
        #expect(TallyNotificationCategory.activityInsight.quietHoursPolicy == .postpone)
        #expect(TallyNotificationCategory.activityInsight.respectsQuietHours)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let settings = TallySettings()
        settings.quietHoursEnabled = true
        settings.quietHoursStartMinutes = 0
        settings.quietHoursEndMinutes = 8 * 60

        let scheduler = ActivityInsightScheduler(
            settings: settings,
            calendar: calendar,
            authorization: { .authorized },
            schedule: { _ in }
        )

        // 02:00 — inside the window.
        let inside = Date(timeIntervalSince1970: 1_748_743_200)
        let delivery = scheduler.deliveryDate(for: inside, category: .activityInsight)
        #expect(delivery > inside)
        #expect(calendar.component(.hour, from: delivery) == 8)

        // Midday — untouched.
        let outside = Date(timeIntervalSince1970: 1_748_779_200)
        #expect(scheduler.deliveryDate(for: outside, category: .activityInsight) == outside)
    }

    // MARK: - Notification copy

    @Test("The notification carries the insight's own sentence")
    func notificationBodyIsTheInsight() {
        #expect(Self.insight.notificationBody == Self.insight.detail)
        #expect(Self.insight.signature == "morningAfter.exerciseMinutes.-65")

        // The signature is what stops the same finding being announced twice.
        let redrawn = HealthInsight(
            kind: .morningAfter,
            metric: .exerciseMinutes,
            headline: Self.insight.headline,
            detail: Self.insight.detail,
            relativeChange: -0.6472,
            sampleCount: 31,
            comparison: Self.comparison
        )
        #expect(redrawn.signature == Self.insight.signature)
    }
}
