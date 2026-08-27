import Foundation
import Testing
import TallyKit
import UserNotifications
@testable import tally

/// SPEC §2's anti-truncation rule, applied to every notification the app sends.
///
/// > **Notification copy** must survive the banner's two-line clamp: the venue
/// > name goes in the **title**, the question in the **body**, and any secondary
/// > line (e.g. the recovery rebound class, §4) in a **subtitle** — never
/// > appended to the body, where it is the first thing truncated. Titles stay
/// > under ~40 characters; long venue names truncate in the middle, keeping the
/// > distinguishing tail.
///
/// Three things are under test, and the middle one is the regression that
/// prompted the rule: that every category splits into three fields, that no body
/// ever carries a second line, and that a long bar name is folded in the middle
/// rather than left for iOS to cut wherever the line ran out.
///
/// **Target setup (integrator):** same as `RadarTests.swift` — this file needs no
/// wiring beyond the `tallyTests` bundle those tests already assume.

// MARK: - Venue names

@Suite("Notification copy — venue names in titles (SPEC §2)")
@MainActor
struct VenueTitleTests {

    @Test("A name that fits is left exactly alone")
    func shortNamesAreUntouched() {
        #expect(NotificationText.shortVenue("The Anchor") == "The Anchor")
        #expect(NotificationText.shortVenue("The Salty Dog") == "The Salty Dog")
        #expect(NotificationText.shortVenue("Bar") == "Bar")
        #expect(NotificationText.shortVenue("") == "")
        // Exactly at the limit is still "fits" — the ellipsis is only bought when
        // something has to be given up for it.
        let exact = String(repeating: "a", count: NotificationText.titleLimit)
        #expect(NotificationText.shortVenue(exact) == exact)
    }

    @Test("SPEC §2's own shape: the middle goes, the distinguishing tail stays")
    func middleTruncation() {
        #expect(
            NotificationText.shortVenue("The Very Long Tavern And Grill", limit: 25)
                == "The Very Long…And Grill"
        )
    }

    @Test("Whole words are dropped, so the result never ends mid-word")
    func foldsOnSpaces() {
        let short = NotificationText.shortVenue(
            "The Old Fitzroy Hotel Public Bar And Beer Garden",
            limit: 40
        )
        #expect(short == "The Old Fitzroy…Bar And Beer Garden")
        #expect(short.hasPrefix("The Old"))
        // The tail is the half that tells two "The Old …" bars apart.
        #expect(short.hasSuffix("Beer Garden"))
        #expect(short.contains("…"))
    }

    @Test("A name with no spaces to fold on is cut mid-word rather than left long")
    func characterFallback() {
        let long = "Supercalifragilisticexpialidociousbrewingcompanytaproom"
        let short = NotificationText.shortVenue(long, limit: 40)

        #expect(short.count == 40)
        #expect(short.contains("…"))
        #expect(short.hasPrefix("Supercalifragilistic"))
        #expect(short.hasSuffix("ewingcompanytaproom"))
    }

    @Test(
        "Whatever the name, the result fits the budget",
        arguments: [
            "The Anchor",
            "The Very Long Tavern And Grill",
            "The Old Fitzroy Hotel Public Bar And Beer Garden",
            "Ye Olde Cheshire Cheese Wine Bar & Chop House Fleet Street",
            "Supercalifragilisticexpialidociousbrewingcompanytaproom",
            "🍻 The Very Long Emoji Tavern And Grill House",
            "A B C D E F G H I J K L M N O P Q R S T U V W X Y Z",
            "Café Zoë"
        ]
    )
    func neverExceedsTheLimit(name: String) {
        for limit in [12, 19, 23, 31, 40] {
            let short = NotificationText.shortVenue(name, limit: limit)
            #expect(short.count <= limit, "\"\(short)\" is over \(limit)")
        }
    }

    @Test("The fixed words are charged to the same budget as the name")
    func compositionFitsTheTitle() {
        let long = "The Old Fitzroy Hotel Public Bar And Beer Garden"

        let arrival = NotificationText.venueTitle(prefix: "Looks like you're at ", venue: long)
        let dwell = NotificationText.venueTitle(prefix: "Still at ", venue: long)
        let trueUp = NotificationText.venueTitle(prefix: "Session at ", venue: long, suffix: " ended")

        for title in [arrival, dwell, trueUp] {
            #expect(title.count <= NotificationText.titleLimit, "\"\(title)\"")
        }
        // The suffix is charged too, or the last word would be the one cut off.
        #expect(trueUp.hasSuffix(" ended"))
        #expect(arrival.hasPrefix("Looks like you're at "))
    }

    @Test("A prefix long enough to squeeze the name out still leaves it readable")
    func venueFloorHolds() {
        let title = NotificationText.venueTitle(
            prefix: String(repeating: "x", count: 60),
            venue: "The Very Long Tavern And Grill"
        )
        // Past the point where arithmetic would ask for a negative budget, the
        // floor takes over: a title that shortened the name to nothing has lost
        // the only part the user needed.
        #expect(title.hasSuffix(NotificationText.shortVenue(
            "The Very Long Tavern And Grill",
            limit: NotificationText.venueFloor
        )))
        #expect(!title.hasSuffix("x"))
    }

    @Test("Surrounding whitespace is not part of the name")
    func trimsWhitespace() {
        #expect(NotificationText.shortVenue("  The Anchor \n") == "The Anchor")
    }
}

// MARK: - The three fields, category by category

@Suite("Notification copy — the banner's three fields (SPEC §2, §5)")
@MainActor
struct NotificationTextSplitTests {

    // MARK: Bar Radar

    private func prompt(_ kind: RadarPrompt.Kind, place: String) -> RadarPrompt {
        RadarPrompt(kind: kind, visitID: UUID(), placeName: place, venueID: UUID())
    }

    @Test("Arrival: the venue in the title, the question in the body, no subtitle")
    func arrivalSplit() {
        let text = RadarNotificationBuilder.text(for: prompt(.arrival, place: "The Anchor"))

        #expect(text.title == "Looks like you're at The Anchor")
        #expect(text.body == "Start a Session?")
        #expect(text.subtitle == "")
        #expect(!text.hasSubtitle)
    }

    @Test("Dwell: SPEC §5's example, split the same way")
    func dwellSplit() {
        let text = RadarNotificationBuilder.text(for: prompt(.dwell, place: "The Anchor"))

        #expect(text.title == "Still at The Anchor")
        #expect(text.body == "Nothing logged yet — start a Session?")
        #expect(text.subtitle == "")
    }

    @Test("Discovery: SPEC §5's example, split the same way")
    func discoverySplit() {
        let text = RadarNotificationBuilder.text(for: prompt(.discovery, place: "The Salty Dog"))

        #expect(text.title == "Looks like you're at The Salty Dog")
        #expect(text.body == "Start a Session?")
        #expect(text.subtitle == "")
    }

    @Test("Session reminder: SPEC §5's example, split the same way")
    func sessionReminderSplit() {
        let text = RadarNotificationBuilder.text(for: prompt(.sessionReminder, place: "The Anchor"))

        #expect(text.title == "Still at The Anchor")
        #expect(text.body == "Anything to add?")
        #expect(text.subtitle == "")
    }

    @Test("True-up: counts in the body, the modeled line in the subtitle")
    func trueUpSplit() {
        let text = RadarCopy.TrueUp.text(
            placeName: "The Anchor",
            alcoholic: 4,
            nonAlcoholic: 1,
            rebound: .compressed
        )

        #expect(text.title == "Session at The Anchor ended")
        #expect(text.body == "4 drinks, 1 water. Look right?")
        #expect(text.subtitle == FibrinolysisModel.ReboundClass.compressed.summary)
        // The line SPEC §4 adds is the one SPEC §2 says must not be in the body.
        #expect(!text.body.contains("\n"))
        #expect(!text.body.contains("Compressed"))
    }

    @Test("Every Bar Radar title fits the clamp, however long the bar's name is")
    func radarTitlesFit() {
        let long = "Ye Olde Cheshire Cheese Wine Bar & Chop House Fleet Street"

        for kind in [RadarPrompt.Kind.arrival, .dwell, .discovery, .sessionReminder] {
            let text = RadarNotificationBuilder.text(for: prompt(kind, place: long))
            #expect(text.title.count <= NotificationText.titleLimit, "\(kind): \"\(text.title)\"")
            #expect(text.title.contains("…"))
        }

        let trueUp = RadarCopy.TrueUp.text(placeName: long, alcoholic: 2, nonAlcoholic: 0)
        #expect(trueUp.title.count <= NotificationText.titleLimit)
        #expect(trueUp.title.hasSuffix(" ended"))
    }

    @Test("No body in the whole family carries a second line")
    func noBodyHasASecondLine() {
        var bodies: [String] = []
        for kind in [RadarPrompt.Kind.arrival, .dwell, .discovery, .sessionReminder] {
            bodies.append(RadarNotificationBuilder.text(for: prompt(kind, place: "The Anchor")).body)
        }
        for rebound in FibrinolysisModel.ReboundClass.allCases {
            bodies.append(
                RadarCopy.TrueUp.text(
                    placeName: "The Anchor",
                    alcoholic: 3,
                    nonAlcoholic: 1,
                    rebound: rebound
                ).body
            )
        }
        for body in bodies { #expect(!body.contains("\n"), "\"\(body)\"") }
    }

    @Test("The request carries all three fields onto the system's content")
    func requestCarriesTheSplit() {
        let closed = RadarPrompt(
            kind: .trueUp,
            placeName: "The Anchor",
            trueUp: RadarTrueUp(
                sessionID: UUID(),
                alcoholicCount: 4,
                nonAlcoholicCount: 1,
                logAt: Date()
            ),
            reboundClass: .elevated
        )
        let content = RadarNotificationBuilder.request(for: closed).content

        #expect(content.title == "Session at The Anchor ended")
        #expect(content.subtitle == FibrinolysisModel.ReboundClass.elevated.summary)
        #expect(content.body == "4 drinks, 1 water. Look right?")
    }

    // MARK: The SPEC §5 categories

    @Test("Weekly digest: the news in the body, the supporting numbers above it")
    func digestSplit() {
        let facts = NotificationTriggers.DigestFacts(
            alcoholicThisWeek: 12,
            alcoholicLastWeek: 15,
            nonAlcoholicThisWeek: 6,
            spacersThisWeek: 3
        )
        let text = NotificationCopy.Digest.text(facts)

        #expect(text.title == "Your week")
        #expect(text.body == "12 drinks this week, down 3 from last.")
        #expect(text.subtitle == "7-day avg: 1.7/day. 3 spacers.")
        #expect(!text.body.contains("7-day avg"))
    }

    @Test("A flat week says so, and a week with no spacers falls back to NA drinks")
    func digestVariants() {
        let flat = NotificationTriggers.DigestFacts(
            alcoholicThisWeek: 7,
            alcoholicLastWeek: 7,
            nonAlcoholicThisWeek: 2,
            spacersThisWeek: 0
        )
        #expect(NotificationCopy.Digest.text(flat).body == "7 drinks this week, same as last.")
        #expect(NotificationCopy.Digest.text(flat).subtitle == "7-day avg: 1.0/day. 2 NA drinks.")

        let bare = NotificationTriggers.DigestFacts(
            alcoholicThisWeek: 1,
            alcoholicLastWeek: 0,
            nonAlcoholicThisWeek: 0,
            spacersThisWeek: 0
        )
        #expect(NotificationCopy.Digest.text(bare).body == "1 drink this week, up 1 from last.")
        #expect(NotificationCopy.Digest.text(bare).subtitle == "7-day avg: 0.1/day.")
    }

    @Test("Trend alert: the sentence in the body, the percentage in the subtitle")
    func trendSplit() {
        let falling = NotificationTriggers.TrendFinding(direction: .down, weeks: 3, percentChange: 20)
        let text = NotificationCopy.Trend.text(falling)

        #expect(text.title == "7-day average")
        #expect(text.body == "Third week trending down — nice.")
        #expect(text.subtitle == "Down 20% over the run.")
    }

    @Test("SPEC §5's asymmetry survives the split: the number, and no verdict")
    func trendUpwardIsFactual() {
        let rising = NotificationTriggers.TrendFinding(direction: .up, weeks: 3, percentChange: 20)
        let text = NotificationCopy.Trend.text(rising)

        #expect(text.body == "Third week trending up.")
        #expect(text.subtitle == "Up 20% over the run.")
        // Praise is allowed downward and nowhere else.
        #expect(!text.body.contains("nice"))
        #expect(!text.subtitle.contains("nice"))
    }

    @Test("Pacing nudge: the offer in the body, the user's own count above it")
    func pacingSplit() {
        let finding = NotificationTriggers.PacingFinding(alcoholicCount: 3, windowMinutes: 90)
        let text = NotificationCopy.Pacing.text(finding)

        #expect(text.title == "Time for a spacer?")
        #expect(text.subtitle == "3 in the last 90 minutes.")
        #expect(text.body == "A non-alcoholic one now counts as a spacer: +25 pts.")
        // The reward is SPEC §3's, and it is the half that must not be cut.
        #expect(text.body.contains("+25 pts"))
    }

    @Test("Streak protection was already short and safe: its strings are unchanged")
    func streakSplit() {
        let risk = NotificationTriggers.StreakRisk(streakDays: 5, nonAlcoholicNeeded: 1)
        let text = NotificationCopy.Streak.text(risk)

        #expect(text.title == "5-day streak on the line")
        #expect(text.body == "One non-alcoholic drink keeps it going.")
        #expect(text.subtitle == "")
        #expect(text.title == NotificationCopy.Streak.title(risk))
        #expect(text.body == NotificationCopy.Streak.body(risk))
    }

    @Test("Every §5 title fits the clamp too")
    func categoryTitlesFit() {
        let titles = [
            NotificationCopy.Digest.title,
            NotificationCopy.Trend.title,
            NotificationCopy.Pacing.title,
            NotificationCopy.Streak.title(
                NotificationTriggers.StreakRisk(streakDays: 365, nonAlcoholicNeeded: 2)
            )
        ]
        for title in titles {
            #expect(title.count <= NotificationText.titleLimit, "\"\(title)\"")
        }
    }

    @Test("`apply` writes all three fields, including an empty subtitle")
    func applyClearsAStaleSubtitle() {
        let content = UNMutableNotificationContent()
        content.apply(NotificationText(title: "a", subtitle: "b", body: "c"))
        #expect(content.subtitle == "b")

        // A content object reused for a Session with recovery context off must
        // not keep the previous one's modeled line.
        content.apply(NotificationText(title: "a", body: "c"))
        #expect(content.subtitle == "")
    }
}

// MARK: - Tapping the notification body

/// SPEC §2, on the arrival prompt:
///
/// > **Tapping the notification body** opens the app on the **check-in picker**
/// > rather than the bare counter — the inferred venue can be wrong, and the tap
/// > is the user saying "let me look."
///
/// The picker itself lives in `Features/Place`; this suite tests the seam
/// `RadarService` publishes for it, which is all this module owns: the default
/// action asks, exactly once, for the four prompts that are about where you are —
/// and never for a button, a swipe, or the true-up.
@Suite("Bar Radar — tapping the notification body (SPEC §2)")
@MainActor
struct CheckInPickerTapThroughTests {

    private let venueID = UUID()

    /// The store is resolved in the body, not in the parameter list: a default
    /// argument is evaluated in the *caller's* isolation, and `RadarStore` is
    /// main-actor bound — the same reason every service in this app resolves its
    /// own defaults this way.
    private func service(store: RadarStore? = nil) -> RadarService {
        RadarService(
            store: store ?? .ephemeral(),
            notifier: MockRadarNotifier(),
            regionMonitor: MockRadarRegionMonitor(),
            visitMonitor: MockRadarVisitMonitor(),
            poiSearch: MockPOISearchService()
        )
    }

    private func prompt(_ kind: RadarPrompt.Kind, visitID: UUID = UUID()) -> RadarPrompt {
        RadarPrompt(
            kind: kind,
            visitID: kind == .trueUp ? nil : visitID,
            placeName: "The Anchor",
            venueID: venueID,
            trueUp: kind == .trueUp
                ? RadarTrueUp(
                    sessionID: UUID(),
                    alcoholicCount: 2,
                    nonAlcoholicCount: 1,
                    logAt: Date()
                )
                : nil
        )
    }

    private func action(_ prompt: RadarPrompt, _ identifier: String) -> NotificationAction {
        NotificationAction(
            categoryIdentifier: prompt.notificationCategoryIdentifier,
            actionIdentifier: identifier,
            requestIdentifier: prompt.requestIdentifier,
            userInfo: RadarActionPayload(prompt: prompt).userInfo
        )
    }

    /// Lets the `Task`s `handleAction` spawns run to completion.
    private func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    @Test(
        "The default action asks for the picker, exactly once",
        arguments: [
            RadarPrompt.Kind.arrival,
            .dwell,
            .discovery,
            .sessionReminder
        ]
    )
    func defaultActionRequestsThePicker(kind: RadarPrompt.Kind) async {
        let service = self.service()
        var requests = 0
        service.checkInPickerRequestHandler = { _ in requests += 1 }

        service.handleAction(action(prompt(kind), UNNotificationDefaultActionIdentifier))
        await settle()

        #expect(requests == 1)
    }

    @Test("The true-up taps through to History, not to the picker (SPEC §2)")
    func trueUpDoesNotAsk() async {
        let service = self.service()
        var requests = 0
        service.checkInPickerRequestHandler = { _ in requests += 1 }

        service.handleAction(action(prompt(.trueUp), UNNotificationDefaultActionIdentifier))
        await settle()

        #expect(requests == 0)
    }

    @Test(
        "A button is an answer, not a request to look around",
        arguments: [
            RadarIdentifiers.logDrinkAction,
            RadarIdentifiers.notDrinkingAction,
            RadarIdentifiers.looksRightAction,
            RadarIdentifiers.notABarAction,
            RadarIdentifiers.muteVenueAction,
            UNNotificationDismissActionIdentifier
        ]
    )
    func buttonsDoNotAsk(identifier: String) async {
        let service = self.service()
        var requests = 0
        service.checkInPickerRequestHandler = { _ in requests += 1 }

        service.handleAction(action(prompt(.arrival), identifier))
        await settle()

        #expect(requests == 0)
    }

    @Test("Another stream's notification is not ours to answer")
    func foreignNotificationIsIgnored() async {
        let service = self.service()
        var requests = 0
        service.checkInPickerRequestHandler = { _ in requests += 1 }

        service.handleAction(
            NotificationAction(
                categoryIdentifier: TallyNotificationCategory.weeklyDigest.identifier,
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                requestIdentifier: "tally.category.weeklyDigest.next",
                userInfo: ["tallyCategory": "weeklyDigest"]
            )
        )
        await settle()

        #expect(requests == 0)
    }

    @Test("No handler wired is the behaviour this app had before: the tap just opens it")
    func noHandlerIsSafe() async {
        let service = self.service()
        service.checkInPickerRequestHandler = nil

        service.handleAction(action(prompt(.arrival), UNNotificationDefaultActionIdentifier))
        await settle()
    }

    @Test("Two taps on two prompts ask twice — the seam holds no state of its own")
    func eachTapAsksOnce() async {
        let service = self.service()
        var requests = 0
        service.checkInPickerRequestHandler = { _ in requests += 1 }

        service.handleAction(action(prompt(.arrival), UNNotificationDefaultActionIdentifier))
        service.handleAction(action(prompt(.discovery), UNNotificationDefaultActionIdentifier))
        await settle()

        #expect(requests == 2)
    }

    // MARK: The bookkeeping the tap already did

    @Test("Tapping a dwell follow-up still spends it — SPEC §2's one per visit")
    func dwellIsStillSpentByTheTap() async {
        let store = RadarStore.ephemeral()
        let visit = RadarVisit(
            venueID: venueID,
            startedAt: Date(),
            venueName: "The Anchor",
            arrivalPromptedAt: Date(),
            dwellScheduled: true,
            dwellScheduledFor: Date().addingTimeInterval(45 * 60)
        )
        var state = RadarVisitState()
        state.upsert(visit)
        store.visitState = state

        let service = self.service(store: store)
        var requests = 0
        service.checkInPickerRequestHandler = { _ in requests += 1 }

        service.handleAction(
            action(prompt(.dwell, visitID: visit.id), UNNotificationDefaultActionIdentifier)
        )
        await settle()

        // The follow-up is marked delivered, exactly as it was before the picker
        // seam existed — and the picker was asked for as well, not instead.
        #expect(store.visitState.visit(id: visit.id)?.dwellDeliveredAt != nil)
        #expect(store.visitState.visit(id: visit.id)?.dwellScheduled == false)
        #expect(requests == 1)
    }

    @Test("The banner's venue rides along as the picker's suggestion")
    func defaultActionCarriesTheSuggestion() async {
        let service = self.service()
        var received: [CheckInPickerSuggestion?] = []
        service.checkInPickerRequestHandler = { received.append($0) }

        // A Tier 1 prompt names a saved venue, so the picker is told which row
        // to mark "Suggested" rather than being left to guess.
        service.handleAction(action(prompt(.arrival), UNNotificationDefaultActionIdentifier))
        await settle()

        #expect(received.count == 1)
        #expect(received.first ?? nil == .venue(venueID))
    }

    @Test("The static hook and the instance property are the same seam")
    func staticHookMirrorsTheInstance() {
        var requests = 0
        RadarService.checkInPickerRequestHandler = { _ in requests += 1 }
        defer { RadarService.checkInPickerRequestHandler = nil }

        RadarService.shared.checkInPickerRequestHandler?(nil)

        #expect(requests == 1)
        #expect(RadarService.checkInPickerRequestHandler != nil)
    }
}
