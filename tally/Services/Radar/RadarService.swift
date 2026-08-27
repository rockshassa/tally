import CoreLocation
import Foundation
import Observation
import SwiftData
import TallyKit
import UserNotifications

/// Bar Radar (SPEC §2), both tiers, in one object.
///
/// > Bar Radar notices you're somewhere worth tracking and prompts before you've
/// > logged anything. It has **two tiers sharing one prompt-and-suppression
/// > machinery**: precise geofences at bars you frequent, and opt-in discovery of
/// > bars you've never logged.
///
/// **What this class actually is.** All of the *rules* live in three pure types —
/// `FrequentedVenues` (who gets a geofence), `RadarVisitMachine` (what an entry,
/// an exit, or a logged drink means), and `DiscoveryGate` (whether a detected
/// visit deserves a prompt). This class is the wiring: it feeds those functions
/// the world's current state, and performs the effects they return. That split is
/// what makes SPEC §2 testable without CoreLocation.
///
/// **Quiet hours.** SPEC §5 exempts every Bar Radar category — "bar hours *are*
/// quiet hours, and those prompts are the feature". The exemption is structural
/// here: these requests go straight to `RadarNotifying`, which never consults
/// `QuietHours`. The one exception is the Session true-up's *scheduled* half,
/// which SPEC §2 asks to postpone through the window and which therefore asks
/// `SessionTrueUp.fireDate(closesAt:quietHours:calendar:)` before it schedules —
/// still down the same delivery path, just with a date that already respects the
/// window it was computed against.
///
/// **What the integrator wires** (and all it has to):
/// ```swift
/// NotificationService.shared.activate(additionalCategories: RadarService.notificationCategories)
/// NotificationService.shared.actionHandler = { RadarService.handleAction($0) }
/// // SPEC §2: tapping a Bar Radar prompt opens the check-in picker, not the
/// // bare counter. See `checkInPickerRequestHandler`.
/// RadarService.checkInPickerRequestHandler = { PlaceCoordinator.present(suggestion: $0) }
/// // and, on the root view:
/// .barRadarCoordination(permissions: permissions)
/// ```
@MainActor
@Observable
public final class RadarService {

    /// One per process. Two would register the same geofences twice and race to
    /// answer the same notification action.
    public static let shared = RadarService()

    /// SPEC §2's "repeated dismissals", after which the arrival prompt starts
    /// offering to mute the venue outright.
    public static let dismissalsBeforeMuteOffer = 2

    // MARK: - Integrator surface

    /// The actionable categories to hand
    /// `NotificationService.activate(additionalCategories:)`.
    public static var notificationCategories: Set<UNNotificationCategory> {
        RadarNotificationCategories.all
    }

    /// The `NotificationService.actionHandler` hook. Anything that is not a Bar
    /// Radar action is ignored, so it is safe to forward everything.
    public static func handleAction(_ action: NotificationAction) {
        shared.handleAction(action)
    }

    // MARK: - Check-in picker (SPEC §2)

    /// **Called when the user taps the body of a Bar Radar prompt.**
    ///
    /// SPEC §2, on the arrival notification:
    ///
    /// > **Tapping the notification body** opens the app on the **check-in
    /// > picker** rather than the bare counter — the inferred venue can be wrong,
    /// > and the tap is the user saying "let me look."
    ///
    /// Fired for the four prompts that are about *where you are* — arrival,
    /// dwell, discovery, and the mid-Session reminder. Not for the Session
    /// true-up: SPEC §2 sends that one's tap-through to "the Session's editable
    /// timeline in History", which is a different screen about a night that is
    /// already over.
    ///
    /// **Why a closure and not a call.** The picker lives in `Features/Place`
    /// and this file is `Services/Radar`; a direct reference would make the
    /// notification layer depend on a view layer, and iOS has already opened the
    /// app by the time this runs, so nothing here needs to know what presenting
    /// looks like. `nil` — the default — means the tap does exactly what it did
    /// before: it opens the app.
    ///
    /// **The integrator's one line**, wherever `activate(additionalCategories:)`
    /// and `actionHandler` are already wired:
    ///
    /// ```swift
    /// RadarService.checkInPickerRequestHandler = { suggestion in
    ///     PlaceCoordinator.present(suggestion: suggestion)
    /// }
    /// ```
    ///
    /// Called on the main actor, synchronously, from inside
    /// `handleAction(_:at:)` — which is itself reached from
    /// `NotificationService`'s delegate callback. Presenting straight from it is
    /// safe and is the point: the sheet should be on screen as the app finishes
    /// coming up, not a frame later.
    /// The suggestion is what the banner named — the picker marks that row
    /// "Suggested" rather than assuming it. `nil` means the prompt named nothing
    /// resolvable, and the picker just ranks by distance.
    public var checkInPickerRequestHandler: ((CheckInPickerSuggestion?) -> Void)?

    /// The same hook on the shared instance, so the integrator's line matches the
    /// two beside it (`RadarService.notificationCategories`,
    /// `RadarService.handleAction`).
    public static var checkInPickerRequestHandler: ((CheckInPickerSuggestion?) -> Void)? {
        get { shared.checkInPickerRequestHandler }
        set { shared.checkInPickerRequestHandler = newValue }
    }

    // MARK: - Observable state

    public private(set) var isRunning = false

    /// The venues currently holding a geofence (SPEC §2 Tier 1).
    public private(set) var targets: [RadarTarget] = []

    /// Why the last detected visit was discarded. Diagnostic only — SPEC §2 says
    /// discovery discards "on the spot", silently.
    public private(set) var lastDiscoveryRejection: DiscoveryGate.Rejection?

    public private(set) var lastDiscoveryPromptAt: Date?

    // MARK: - Dependencies

    private let settings: TallySettings
    private let store: RadarStore
    private let notifier: any RadarNotifying
    private let regionMonitor: any RadarRegionMonitoring
    private let visitMonitor: any RadarVisitMonitoring
    private let poiSearch: any POISearching
    private let frequented: FrequentedVenues
    private let deriver: SessionDeriver
    private let calendar: Calendar

    private var modelContext: ModelContext?
    private let saveObserver = NotificationObserverToken()
    private var lastSeenEventAt: Date?

    /// Every dependency is injectable, and every default is resolved in the body
    /// rather than the parameter list — a default argument is evaluated in the
    /// *caller's* isolation, and most of these are main-actor bound.
    public init(
        settings: TallySettings? = nil,
        store: RadarStore? = nil,
        notifier: (any RadarNotifying)? = nil,
        regionMonitor: (any RadarRegionMonitoring)? = nil,
        visitMonitor: (any RadarVisitMonitoring)? = nil,
        poiSearch: (any POISearching)? = nil,
        frequented: FrequentedVenues = FrequentedVenues(),
        deriver: SessionDeriver = SessionDeriver(),
        calendar: Calendar = .current
    ) {
        self.settings = settings ?? .shared
        self.store = store ?? RadarStore()
        self.notifier = notifier ?? LiveRadarNotifier()
        self.regionMonitor = regionMonitor ?? CLMonitorRegionMonitor()
        self.visitMonitor = visitMonitor ?? CLVisitMonitor()
        self.poiSearch = poiSearch ?? POISearchService()
        self.frequented = frequented
        self.deriver = deriver
        self.calendar = calendar
    }

    // MARK: - Lifecycle

    /// Starts both tiers. Idempotent — a second call just refreshes the geofence
    /// set.
    ///
    /// - Parameter context: the app's model context. Defaults to the shared
    ///   store, which is what a background launch from a geofence gets.
    public func start(context: ModelContext? = nil, asOf now: Date = Date()) async {

        if let context { modelContext = context }
        if modelContext == nil { modelContext = try? TallyRuntime.container().mainContext }

        // SPEC §2: the master toggle governs both tiers.
        guard settings.barRadarEnabled else {
            await stop()
            return
        }

        guard !isRunning else {
            await refresh(asOf: now)
            return
        }

        isRunning = true
        lastSeenEventAt = latestEventTimestamp()

        await regionMonitor.start { [weak self] event in
            self?.receive(regionEvent: event)
        }

        // SPEC §2: discovery has "its own sub-toggle, on by default".
        if settings.barRadarDiscoveryEnabled {
            visitMonitor.start { [weak self] visit in
                self?.receive(visit: visit)
            }
        }

        observeStoreSaves()
        await refresh(asOf: now)
    }

    /// SPEC §2: "disabling Bar Radar drops back to When-In-Use." Every condition
    /// is removed, visit monitoring stops, and anything pending is retracted.
    public func stop() async {
        isRunning = false
        saveObserver.clear()

        await regionMonitor.stop()
        visitMonitor.stop()
        await cancelEverythingPending()

        var state = store.visitState
        state.removeAll()
        store.visitState = state

        targets = []
    }

    /// Re-derives the frequented set and makes the monitored regions match.
    ///
    /// Cheap enough for every foreground: it is one derivation over the log.
    public func refresh(asOf now: Date = Date()) async {
        guard isRunning, let modelContext else { return }

        targets = frequented.targets(
            in: modelContext,
            deriver: deriver,
            venueExits: store.venueExits(asOf: now),
            asOf: now
        )
        await regionMonitor.sync(targets: targets)

        // Discovery can be flipped independently of the master toggle.
        if settings.barRadarDiscoveryEnabled {
            visitMonitor.start { [weak self] visit in
                self?.receive(visit: visit)
            }
        } else {
            visitMonitor.stop()
        }
    }

    // MARK: - Exits (SPEC §2 → SessionDeriver)

    /// The Bar Radar exits `SessionDeriver.derive(…, venueExits:)` should be fed.
    ///
    /// SPEC §2: a Session "closes … immediately when a Bar Radar exit event
    /// fires, whichever comes first". Exits are an input to derivation rather
    /// than stored Session state, so anything that derives Sessions while Bar
    /// Radar is on should pass these.
    public func venueExits(asOf now: Date = Date()) -> [SessionDeriver.VenueExit] {
        store.venueExits(asOf: now)
    }

    // MARK: - Tier 1

    private func receive(regionEvent event: RadarRegionEvent) {
        Task { await process(regionEvent: event) }
    }

    /// Exposed for fixtures: this is exactly what a `CLMonitor` event does.
    public func process(regionEvent event: RadarRegionEvent) async {
        guard settings.barRadarEnabled else { return }

        let input: RadarVisitInput
        switch event {
        case .entered(let venueID, let at):
            guard let target = resolveTarget(venueID: venueID) else { return }
            input = .entered(target: target, at: at)
        case .exited(let venueID, let at):
            input = .exited(venueID: venueID, at: at)
        }

        await run(input)
    }

    /// **Call this from the log path.** Any logged drink retracts the pending
    /// dwell follow-up, re-arms the mid-Session reminder from its own timestamp,
    /// and re-projects the Session true-up (SPEC §2).
    ///
    /// The store's own `didSave` notification covers the in-app, widget, and
    /// watch paths automatically; this exists for callers that would rather be
    /// explicit, and is what the "+1 drink" action uses.
    public func sessionDidLogDrink(at date: Date = Date()) {
        Task { await drinkLogged(at: date) }
    }

    /// Everything a logged drink means to Bar Radar, in one place so the three
    /// callers cannot drift.
    private func drinkLogged(at date: Date) async {
        await run(.drinkLogged(at: date))
        await projectTrueUp(asOf: date)
    }

    private func run(_ input: RadarVisitInput) async {
        let machine = makeMachine()
        let outcome = machine.handle(input, state: store.visitState)
        store.visitState = outcome.state
        await apply(outcome.effects)
    }

    private func makeMachine() -> RadarVisitMachine {
        RadarVisitMachine(
            configuration: RadarVisitMachine.Configuration(
                dwellDelay: TimeInterval(max(1, settings.barRadarDwellMinutes) * 60),
                sessionReminderDelay: TimeInterval(max(1, settings.sessionReminderMinutes) * 60)
            )
        )
    }

    /// The target a geofence event belongs to.
    ///
    /// `targets` is the fast path, but a background launch can deliver an entry
    /// before anything has been derived, so the venue is looked up directly as a
    /// fallback — an arrival prompt must never depend on the app having been
    /// opened recently.
    private func resolveTarget(venueID: UUID) -> RadarTarget? {
        if let known = targets.first(where: { $0.venueID == venueID }) { return known }

        guard
            let modelContext,
            let venue = try? EventStore.venue(id: venueID, in: modelContext)
        else { return nil }

        let snapshot = venue.snapshot
        // SPEC §2: "Home and muted venues are excluded" — belt and braces, in
        // case a mute landed after the condition was registered.
        guard !snapshot.category.isHome, !snapshot.muted else { return nil }

        return RadarTarget(venue: snapshot, sessionCount: 0, lastSessionAt: .distantPast)
    }

    // MARK: - Effects

    private func apply(_ effects: [RadarEffect]) async {
        for effect in effects {
            switch effect {
            case .autoCheckIn(let venueID, _):
                autoCheckIn(venueID: venueID)

            case .deliver(var prompt):
                // SPEC §2: per-venue mute is "also offered on the arrival
                // notification after repeated dismissals".
                if prompt.kind == .arrival, let venueID = prompt.venueID {
                    prompt.offersMute =
                        store.arrivalDismissals(venueID: venueID) >= Self.dismissalsBeforeMuteOffer
                }
                await deliver(prompt, fireDate: nil)

            case .scheduleDwell(let prompt, let date):
                await deliver(prompt, fireDate: date)

            case .cancelDwell(let visitID):
                notifier.cancel(identifiers: [dwellIdentifier(visitID)])

            case .scheduleSessionReminder(var prompt, let date):
                // The machine builds this one from the visit, which caches the
                // venue's name — except for a visit persisted by a build that
                // predates that field. The venue itself still knows it.
                if prompt.placeName.isEmpty, let venueID = prompt.venueID {
                    prompt.placeName = resolveTarget(venueID: venueID)?.name ?? ""
                }
                // "Still at  — anything to add?" is worse than silence.
                guard !prompt.placeName.isEmpty else { break }
                await deliver(prompt, fireDate: date)

            case .cancelSessionReminder(let visitID):
                notifier.cancel(identifiers: [sessionReminderIdentifier(visitID)])

            case .recordExit(let venueID, let at):
                store.recordExit(venueID: venueID, at: at)

            case .deliverTrueUp(let venueID, let closedAt):
                await deliverTrueUp(venueID: venueID, closedAt: closedAt)
            }
        }
    }

    /// SPEC §5's quiet-hours exemption lives here, by omission: this is the only
    /// path Bar Radar notifications take, and it asks `QuietHours` nothing.
    ///
    /// - Returns: whether the request reached the system. The Session true-up is
    ///   the one caller that has to know — it writes a "this Session has had its
    ///   prompt" record, and a prompt the category toggle refused was never had.
    @discardableResult
    private func deliver(_ prompt: RadarPrompt, fireDate: Date?) async -> Bool {
        // The per-category toggle still applies (SPEC §5: "opt-in per category").
        guard settings.isEnabled(prompt.category) else { return false }
        guard await notifier.canDeliver() else { return false }
        await notifier.deliver(RadarNotificationBuilder.request(for: prompt, fireDate: fireDate))
        return true
    }

    private func dwellIdentifier(_ visitID: UUID) -> String {
        "\(TallyNotificationCategory.barRadarDwell.identifier).\(visitID.uuidString)"
    }

    /// One identifier per visit, not per reminder: SPEC §2 allows two per visit
    /// but only ever one in flight, so the second replaces the first rather than
    /// stacking beside it. Same scheme as `RadarPrompt.requestIdentifier`.
    private func sessionReminderIdentifier(_ visitID: UUID) -> String {
        "\(TallyNotificationCategory.sessionReminder.identifier).\(visitID.uuidString)"
    }

    /// SPEC §2: "auto check-in to the venue (it's known — no confirmation sheet
    /// needed)."
    ///
    /// Tags the outing rather than one drink, which is what a confirmed check-in
    /// does (SPEC §2 step 3). Drinks logged *after* this land tagged on their
    /// own: the fix falls inside the venue's geofence, which is step 1 of the
    /// check-in pipeline.
    private func autoCheckIn(venueID: UUID) {
        guard
            let modelContext,
            let venue = try? EventStore.venue(id: venueID, in: modelContext),
            let session = activeSession()
        else { return }

        // A Session that already knows where it is keeps its answer.
        guard session.venueID == nil else { return }
        try? VenueWriter.tag(eventIDs: session.eventIDs, with: venue, in: modelContext)
    }

    private func activeSession(asOf now: Date = Date()) -> DerivedSession? {
        guard
            let modelContext = resolvedContext(),
            let events = try? EventStore.snapshots(in: modelContext),
            let materialized = try? EventStore.materializedSessions(in: modelContext)
        else { return nil }

        return deriver.activeSession(
            events: events,
            materialized: materialized,
            venueExits: store.venueExits(asOf: now),
            asOf: now
        )
    }

    /// The app's store, resolved on demand.
    ///
    /// `start()` normally supplies it, but the Session true-up runs off the log
    /// path rather than off a geofence — see `projectTrueUp(asOf:)` — so it can be
    /// the first thing to need a context in a process where Bar Radar itself was
    /// never started.
    private func resolvedContext() -> ModelContext? {
        if modelContext == nil { modelContext = try? TallyRuntime.container().mainContext }
        return modelContext
    }

    // MARK: - Session true-up (SPEC §2)

    /// The exit-close half: "a geofence exit delivers immediately (quiet-hours
    /// exempt — the user is demonstrably out and awake)".
    ///
    /// Immediate delivery down the `RadarNotifying` path, which is where the
    /// exemption lives for the whole Bar Radar family: nothing on it consults
    /// `QuietHours`. The category declares `.postpone` for the *scheduled* half
    /// below, and this path simply never asks — a category has one policy, and
    /// the honest split is to declare the one that can be enforced and make the
    /// other structural.
    private func deliverTrueUp(venueID: UUID, closedAt: Date) async {
        guard let session = closedSession(atVenue: venueID, closedAt: closedAt) else { return }
        guard !store.hasSpentTrueUp(sessionID: session.id, asOf: closedAt) else { return }

        guard let prompt = SessionTrueUp.prompt(
            for: session,
            placeName: venueName(venueID: session.venueID) ?? ""
        ) else { return }

        // The timeout half may have one pending for this same Session under this
        // same identifier. Adding a request with a matching identifier replaces
        // it anyway; cancelling first also covers the case where delivery is
        // refused, which must not leave a stale projection to fire hours later.
        notifier.cancel(identifiers: [prompt.requestIdentifier])

        guard await deliver(prompt, fireDate: nil) else { return }
        store.recordTrueUpDelivered(sessionID: session.id, at: closedAt)
    }

    /// The timeout-close half: "a timeout close (home, or no geofence) delivers
    /// with quiet-hours *postpone* semantics."
    ///
    /// A Session that closes on the 3 h timeout does so **silently** — no geofence
    /// fires, nothing wakes the app, and SPEC §2 buys none of that with background
    /// machinery. So the prompt is projected forward from the log path instead:
    /// every logged drink schedules one at that Session's current `closesAt`,
    /// under an identifier keyed by the Session, so the next drink replaces it
    /// rather than stacking a second banner.
    ///
    /// **Why every Session, and not only the unmonitored ones.** A monitored
    /// venue's true-up belongs to the exit path, so the obvious worry is a
    /// scheduled one going off while the user is still at the bar. It cannot
    /// arrive early: each drink pushes the fire date to that drink's own +3 h, so
    /// the only way it lands is three hours with nothing logged — at which point
    /// `SessionDeriver` says the Session *has* closed, and "Session at The Anchor
    /// ended — 4 drinks. Look right?" with a "+1 drink" button is exactly the
    /// right thing to say to someone who stopped logging. Meanwhile the simple
    /// rule covers the case venue special-casing would lose outright: a missed
    /// exit event, which is a normal CoreLocation outcome this module already
    /// plans for elsewhere. So — schedule for every Session, let each drink push
    /// it out, and let an exit cancel and replace it.
    ///
    /// **Not gated on the Bar Radar master toggle**, unlike everything else in
    /// this class. This half needs no geofence, no visit, and no location
    /// permission at all; SPEC §2 names "home" as its case, and Bar Radar never
    /// applies to Home. Gating it would leave a Settings toggle switched on with
    /// nothing behind it, which SPEC §9 treats as a lie. The per-category toggle
    /// in `deliver(_:fireDate:)` is the control that matters here.
    private func projectTrueUp(asOf now: Date) async {
        guard let session = activeSession(asOf: now), !session.events.isEmpty else { return }
        guard !store.hasSpentTrueUp(sessionID: session.id, asOf: now) else { return }

        guard let prompt = SessionTrueUp.prompt(
            for: session,
            placeName: venueName(venueID: session.venueID) ?? ""
        ) else { return }

        let fireDate = SessionTrueUp.fireDate(
            closesAt: session.closesAt,
            quietHours: settings.quietHours,
            calendar: calendar
        )

        guard await deliver(prompt, fireDate: fireDate) else { return }
        store.recordTrueUpScheduled(sessionID: session.id, fireDate: fireDate, at: now)
    }

    /// The Session a geofence exit just closed.
    ///
    /// Derived *after* `.recordExit` has been applied, so the exit is already an
    /// input and the Session's `closesAt` is the exit's own timestamp.
    private func closedSession(atVenue venueID: UUID, closedAt: Date) -> DerivedSession? {
        guard
            let modelContext = resolvedContext(),
            let sessions = try? deriver.derive(
                in: modelContext,
                venueExits: store.venueExits(asOf: closedAt)
            )
        else { return nil }

        let candidates = sessions.filter {
            $0.venueID == venueID && !$0.events.isEmpty && $0.isClosed(asOf: closedAt)
        }
        guard let session = candidates.last else { return nil }

        // An exit that arrives long after the Session had already timed out is not
        // what closed it, and reconciling last Tuesday's outing because a stale
        // region event finally landed would be worse than silence. The projected
        // half owns anything that closed on the clock.
        guard closedAt.timeIntervalSince(session.closesAt) <= deriver.configuration.inactivityWindow else {
            return nil
        }
        return session
    }

    private func venueName(venueID: UUID?) -> String? {
        guard let venueID, let modelContext = resolvedContext() else { return nil }
        return (try? EventStore.venue(id: venueID, in: modelContext))?.name
    }

    // MARK: - Tier 2

    private func receive(visit: RadarVisitObservation) {
        Task { await process(visit: visit) }
    }

    /// Exposed for fixtures: this is exactly what a `CLVisit` does.
    ///
    /// SPEC §2: "On a visit event, the app runs the same MapKit POI lookup as
    /// check-in; a single confident nightlife candidate within the visit's
    /// accuracy radius fires the same *'start a Session?'* prompt. No candidate,
    /// or an ambiguous cluster → the event is discarded on the spot."
    public func process(visit: RadarVisitObservation, asOf now: Date = Date()) async {

        let gate = DiscoveryGate(configuration: .fromSettings(settings))
        let context = discoveryContext(asOf: now)

        // Everything decidable without asking MapKit anything, first: a visit
        // outside discovery hours should cost nothing at all.
        if let rejection = gate.preflight(visit: visit, context: context, asOf: now, calendar: calendar) {
            lastDiscoveryRejection = rejection
            return
        }

        let candidates = await poiSearch.nearbyVenues(
            around: visit.fix,
            radiusMeters: gate.searchRadius(for: visit)
        )

        let decision = gate.resolve(candidates: candidates, visit: visit, context: context)
        guard case .prompt(let candidate) = decision else {
            lastDiscoveryRejection = decision.rejection
            return
        }

        lastDiscoveryRejection = nil
        lastDiscoveryPromptAt = now

        // SPEC §2's "max 3 discovery prompts per week" counts prompts fired, so
        // the counter moves here rather than at delivery.
        store.recordDiscoveryPrompt(at: now)

        let prompt = RadarPrompt(
            kind: .discovery,
            visitID: UUID(),
            placeName: candidate.name,
            venueID: nil,
            place: RadarPlace(candidate: candidate)
        )
        await deliver(prompt, fireDate: nil)
    }

    private func discoveryContext(asOf now: Date) -> DiscoveryGate.Context {
        DiscoveryGate.Context(
            isRadarEnabled: settings.barRadarEnabled,
            isDiscoveryEnabled: settings.barRadarDiscoveryEnabled,
            home: homeSnapshot(),
            suppressedPlaces: suppressedPlaces(),
            monitoredTargets: targets,
            recentPromptDates: store.discoveryPromptDates(asOf: now)
        )
    }

    private func homeSnapshot() -> VenueSnapshot? {
        guard let modelContext else { return nil }
        return (try? VenueWriter.home(in: modelContext))?.snapshot
    }

    private func suppressedPlaces() -> [SuppressedPlaceSnapshot] {
        guard let modelContext else { return [] }
        return ((try? modelContext.fetch(FetchDescriptor<SuppressedPlace>())) ?? []).map(\.snapshot)
    }

    // MARK: - Notification actions

    /// Handles a Bar Radar notification action. Ignores everything else.
    public func handleAction(_ action: NotificationAction, at date: Date = Date()) {
        guard let payload = RadarActionPayload(userInfo: action.userInfo) else { return }

        switch action.actionIdentifier {

        case RadarIdentifiers.logDrinkAction:
            logDrink(payload: payload, at: date)

        case RadarIdentifiers.notDrinkingAction:
            // SPEC §2: "suppresses all further prompts for this visit".
            guard let visitID = payload.visitID else { return }
            Task { await run(.declined(visitID: visitID, at: date)) }

        case RadarIdentifiers.looksRightAction:
            // SPEC §2: "**Looks right** (dismisses)". Deliberately nothing else —
            // the Session was already right, and the one-per-Session ledger closed
            // the book when this was delivered.
            break

        case RadarIdentifiers.notABarAction:
            suppressPlace(payload: payload, at: date)

        case RadarIdentifiers.muteVenueAction:
            muteVenue(payload: payload)

        case UNNotificationDismissActionIdentifier:
            recordDismissal(payload: payload, at: date)

        default:
            // The default action opens the app, which is not an answer to
            // anything — but it does mean the follow-up has been seen. The
            // mid-Session reminder and the true-up need no equivalent: their fire
            // dates are their own receipts, and both budgets are settled from that.
            //
            // Deliberately not gated on the identifier being the default action:
            // an identifier this switch does not recognise is one of ours that
            // nothing handles yet, and it reached the user the same way.
            if payload.kind == .dwell, let visitID = payload.visitID {
                Task { await run(.dwellDelivered(visitID: visitID, at: date)) }
            }

            // …and *then* the tap-through, after the bookkeeping above, so the
            // visit is settled before anything is presented over it.
            guard action.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
            requestCheckInPicker(for: payload)
        }
    }

    /// SPEC §2: the tap on a Bar Radar prompt "opens the app on the **check-in
    /// picker** … rather than the bare counter".
    ///
    /// The true-up is the one prompt excluded — its tap-through belongs to the
    /// Session's timeline in History, and offering to check in somewhere would be
    /// answering a question about a night that has already ended.
    private func requestCheckInPicker(for payload: RadarActionPayload) {
        switch payload.kind {
        case .arrival, .dwell, .discovery, .sessionReminder:
            // Tier 1 knows a saved venue; discovery only ever has the POI it
            // matched. Either way the picker treats it as a hint, not an answer.
            let suggestion: CheckInPickerSuggestion? =
                if let venueID = payload.venueID { .venue(venueID) }
                else if let place = payload.place { .place(place) }
                else { nil }
            checkInPickerRequestHandler?(suggestion)
        case .trueUp:
            break
        }
    }

    /// SPEC §2: "**+1 drink** — logs directly from the notification, opening the
    /// Session auto-tagged to the venue, without launching the app."
    ///
    /// Tier 2's version is also SPEC §2's graduation rule: "a confirmed Session
    /// at a discovered bar creates the Venue and counts toward frequented status".
    private func logDrink(payload: RadarActionPayload, at date: Date) {
        guard let modelContext = resolvedContext() else { return }

        var venue: Venue?
        if let venueID = payload.venueID {
            venue = try? EventStore.venue(id: venueID, in: modelContext)
        } else if let place = payload.place {
            venue = try? VenueWriter.resolveVenue(for: place.candidate, in: modelContext)
        }

        // SPEC §2's true-up: "+1 drink — retro-logs, venue-tagged, **timestamped
        // at close**". The tap can be hours after the Session ended, and a drink
        // stamped *now* would open a brand-new Session instead of correcting the
        // closed one. Every other prompt speaks about the present and stamps the
        // tap.
        let timestamp = payload.trueUp?.logAt ?? date

        guard let event = try? EventStore.logDrink(
            type: .alcoholic,
            timestamp: timestamp,
            source: TallyRuntime.eventSource,
            // No coordinates: the venue is known, and inventing a fix from its
            // centre would put a location on an event that never had one.
            venue: venue,
            in: modelContext
        ) else { return }

        // Tag the outing, not the tap — same as confirming a check-in.
        if let venue, let session = activeSession(asOf: timestamp), session.venueID == nil {
            let ids = session.eventIDs.contains(event.id) ? session.eventIDs : session.eventIDs + [event.id]
            try? VenueWriter.tag(eventIDs: ids, with: venue, in: modelContext)
        }

        // SPEC §5's pacing nudge is event-driven off the log path, and this is a
        // log path. It ignores back-dated events itself, which is the right answer
        // for a true-up correction: nobody needs pacing advice about last night.
        NotificationService.shared.sessionDidLogDrink(type: .alcoholic, in: modelContext, at: timestamp)

        Task {
            await drinkLogged(at: date)
            await refresh(asOf: date)
        }
    }

    /// SPEC §2: "'Not a bar / don't ask here' … writes a `SuppressedPlace` and
    /// that spot goes permanently quiet."
    private func suppressPlace(payload: RadarActionPayload, at date: Date) {
        guard let place = payload.place else { return }
        writeSuppression(place: place, at: date)
    }

    /// SPEC §2: "Per-venue mute … covers Tier 1", and muting drops the venue out
    /// of the frequented set, which drops its geofence on the next sync.
    private func muteVenue(payload: RadarActionPayload) {
        guard
            let modelContext,
            let venueID = payload.venueID,
            let venue = try? EventStore.venue(id: venueID, in: modelContext)
        else { return }

        venue.muted = true
        try? modelContext.save()
        store.clearArrivalDismissals(venueID: venueID)

        Task {
            // Muting arrives from a prompt that always has a visit; the guard is
            // for the type, not for a case that happens.
            if let visitID = payload.visitID {
                await run(.declined(visitID: visitID, at: Date()))
            }
            await refresh()
        }
    }

    /// SPEC §2: "Two plain dismissals at the same spot auto-suppress it", and —
    /// for Tier 1 — repeated dismissals at a venue start offering the mute.
    private func recordDismissal(payload: RadarActionPayload, at date: Date) {
        // A swiped-away mid-Session reminder is not a vote against the venue —
        // the user is demonstrably logging drinks there — so it must not push
        // the arrival prompt toward offering to mute the place. Nor is a
        // swiped-away true-up, which is a receipt for an outing that is over.
        guard payload.kind != .sessionReminder, payload.kind != .trueUp else { return }

        if let venueID = payload.venueID, payload.kind != .discovery {
            store.recordArrivalDismissal(venueID: venueID, at: date)
            return
        }

        guard payload.kind == .discovery, let place = payload.place else { return }

        let count = store.recordDismissal(
            at: place.coordinate,
            name: place.name,
            mapItemID: place.mapItemID,
            at: date
        )

        let threshold = DiscoveryGate.Configuration.default.dismissalsBeforeSuppression
        guard count >= threshold else { return }
        writeSuppression(place: place, at: date)
    }

    private func writeSuppression(place: RadarPlace, at date: Date) {
        guard let modelContext else { return }

        let existing = ((try? modelContext.fetch(FetchDescriptor<SuppressedPlace>())) ?? []).contains {
            if let mapItemID = place.mapItemID, $0.mapItemID == mapItemID { return true }
            return CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)) <= $0.radiusMeters
        }
        guard !existing else { return }

        modelContext.insert(
            SuppressedPlace(
                latitude: place.latitude,
                longitude: place.longitude,
                mapItemID: place.mapItemID,
                name: place.name.isEmpty ? nil : place.name,
                createdAt: date
            )
        )
        try? modelContext.save()

        // The spot is suppressed outright now; un-suppressing it from Settings
        // should start the two-dismissal count over rather than resume it.
        store.clearDismissals(near: place.coordinate)
    }

    // MARK: - Log-path observation

    /// Watches the store so any drink — app, widget, watch, or notification —
    /// retracts the pending follow-up without every logging surface having to
    /// know Bar Radar exists.
    private func observeStoreSaves() {
        guard saveObserver.value == nil else { return }
        saveObserver.value = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.storeDidSave() }
        }
    }

    private func storeDidSave(now: Date = Date()) {
        guard isRunning else { return }
        guard let latest = latestEventTimestamp() else { return }

        defer { lastSeenEventAt = max(latest, lastSeenEventAt ?? latest) }

        guard let previous = lastSeenEventAt else { return }
        guard latest > previous else { return }

        // A retro-logged drink from last Tuesday is not evidence that anyone is
        // at the bar right now.
        guard abs(now.timeIntervalSince(latest)) < 10 * 60 else { return }

        Task { await drinkLogged(at: latest) }
    }

    private func latestEventTimestamp() -> Date? {
        guard let modelContext else { return nil }
        var descriptor = FetchDescriptor<DrinkEvent>()
        descriptor.sortBy = [SortDescriptor(\DrinkEvent.timestamp, order: .reverse)]
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.timestamp
    }

    // MARK: - Cancellation & erase

    /// Everything the *venue* tiers have pending.
    ///
    /// Session true-ups are deliberately not on this list: `stop()` uses it, and
    /// turning Bar Radar off does not un-close a Session that already happened —
    /// see `projectTrueUp(asOf:)` for why that half runs without the master
    /// toggle. `eraseAll()` pulls them, because then the Session is gone too.
    private func cancelEverythingPending() async {
        let prefixes = [
            TallyNotificationCategory.barRadarArrival.identifier,
            TallyNotificationCategory.barRadarDwell.identifier,
            TallyNotificationCategory.barRadarDiscovery.identifier,
            TallyNotificationCategory.sessionReminder.identifier
        ]
        let pending = await notifier.pendingIdentifiers()
        let ours = pending.filter { identifier in prefixes.contains { identifier.hasPrefix($0) } }
        guard !ours.isEmpty else { return }
        notifier.cancel(identifiers: ours)
    }

    private func cancelPendingTrueUps() async {
        let prefix = TallyNotificationCategory.sessionTrueUp.identifier
        let ours = await notifier.pendingIdentifiers().filter { $0.hasPrefix(prefix) }
        guard !ours.isEmpty else { return }
        notifier.cancel(identifiers: ours)
    }

    /// Settings → Erase all data (SPEC §9). Every suppression rule Bar Radar
    /// remembers is about events that no longer exist.
    public func eraseAll() async {
        await cancelEverythingPending()
        await cancelPendingTrueUps()
        store.reset()
        lastSeenEventAt = nil
        lastDiscoveryRejection = nil
        lastDiscoveryPromptAt = nil
    }
}
