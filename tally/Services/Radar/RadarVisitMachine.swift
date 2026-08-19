import Foundation
import TallyKit

// MARK: - Visit

/// One outing's worth of Bar Radar state at one venue (SPEC §2 Tier 1).
///
/// A visit is not a Session: it starts at a geofence entry and survives stepping
/// outside for a cigarette, which is exactly what SPEC §2's re-entry rule is
/// about. Sessions are still derived from the event log and nothing here is ever
/// an input to that — except the exit, which is (SPEC §2).
nonisolated public struct RadarVisit: Identifiable, Hashable, Sendable, Codable {

    public let id: UUID
    public let venueID: UUID

    /// First entry of this visit — the identity moment.
    public var startedAt: Date

    /// Most recent entry, which a same-visit re-entry moves forward.
    public var lastEnteredAt: Date

    /// `nil` while inside. Set on exit, and the clock the 2 h re-entry window
    /// runs from.
    public var lastExitedAt: Date?

    /// The venue's name, cached at entry.
    ///
    /// The visit is the only thing the mid-Session reminder has to go on: it is
    /// armed by a logged drink, and a drink arrives without a `RadarTarget`
    /// attached. Optional because a visit persisted by a build that predates this
    /// field has none — `RadarService` resolves the venue in that case.
    public var venueName: String?

    public var arrivalPromptedAt: Date?

    /// Set when the user acts on the follow-up. Only half the story — see
    /// `dwellScheduledFor`.
    public var dwellDeliveredAt: Date?

    /// A dwell follow-up is currently pending in the notification centre.
    public var dwellScheduled: Bool

    /// When the pending follow-up is due.
    ///
    /// This is what actually enforces SPEC §2's "one follow-up maximum per
    /// visit": an ignored notification produces no callback, so a visit that had
    /// its follow-up is recognised by the fire date having passed, not by
    /// anything the user did. Cancelling clears it — a follow-up that was pulled
    /// was never spent.
    public var dwellScheduledFor: Date?

    /// Any drink logged during this visit. Retracts the pending follow-up, and —
    /// because it also means a Session is running here — arms the mid-Session
    /// reminder (SPEC §2).
    public var lastDrinkLoggedAt: Date?

    /// When the pending mid-Session reminder is due, `nil` when none is armed.
    ///
    /// Same fire-date accounting as `dwellScheduledFor`, one step further: SPEC
    /// §2 allows "two maximum per visit", so a passed fire date is *banked* into
    /// `sessionRemindersFired` rather than left in place as a one-shot receipt.
    /// A reminder pulled before it was due was never spent and banks nothing.
    public var sessionReminderScheduledFor: Date?

    /// Reminders whose fire date has passed, settled.
    ///
    /// Not a delivery count: an ignored notification produces no callback, so
    /// "it fired" can only ever mean "its date arrived and nothing had retracted
    /// it" — exactly the rule the dwell follow-up already runs on.
    public var sessionRemindersFired: Int

    /// SPEC §2: "Not drinking tonight — suppresses all further prompts for this
    /// visit."
    public var isSuppressed: Bool

    /// SPEC §2: "**two maximum per visit**."
    public static let maxSessionReminders = 2

    public init(
        id: UUID = UUID(),
        venueID: UUID,
        startedAt: Date,
        lastEnteredAt: Date? = nil,
        lastExitedAt: Date? = nil,
        venueName: String? = nil,
        arrivalPromptedAt: Date? = nil,
        dwellDeliveredAt: Date? = nil,
        dwellScheduled: Bool = false,
        dwellScheduledFor: Date? = nil,
        lastDrinkLoggedAt: Date? = nil,
        sessionReminderScheduledFor: Date? = nil,
        sessionRemindersFired: Int = 0,
        isSuppressed: Bool = false
    ) {
        self.id = id
        self.venueID = venueID
        self.startedAt = startedAt
        self.lastEnteredAt = lastEnteredAt ?? startedAt
        self.lastExitedAt = lastExitedAt
        self.venueName = venueName
        self.arrivalPromptedAt = arrivalPromptedAt
        self.dwellDeliveredAt = dwellDeliveredAt
        self.dwellScheduled = dwellScheduled
        self.dwellScheduledFor = dwellScheduledFor
        self.lastDrinkLoggedAt = lastDrinkLoggedAt
        self.sessionReminderScheduledFor = sessionReminderScheduledFor
        self.sessionRemindersFired = sessionRemindersFired
        self.isSuppressed = isSuppressed
    }

    /// Every field decoded with `decodeIfPresent`, so a visit written by an older
    /// build survives an app update.
    ///
    /// `RadarStore` reads this state as `?? RadarVisitState()`: one key the old
    /// payload never wrote would throw, drop every open visit, and re-prompt
    /// someone who already said "not drinking tonight" — the exact outcome
    /// persisting the state prevents.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let startedAt = try container.decode(Date.self, forKey: .startedAt)

        self.id = try container.decode(UUID.self, forKey: .id)
        self.venueID = try container.decode(UUID.self, forKey: .venueID)
        self.startedAt = startedAt
        self.lastEnteredAt = try container.decodeIfPresent(Date.self, forKey: .lastEnteredAt) ?? startedAt
        self.lastExitedAt = try container.decodeIfPresent(Date.self, forKey: .lastExitedAt)
        self.venueName = try container.decodeIfPresent(String.self, forKey: .venueName)
        self.arrivalPromptedAt = try container.decodeIfPresent(Date.self, forKey: .arrivalPromptedAt)
        self.dwellDeliveredAt = try container.decodeIfPresent(Date.self, forKey: .dwellDeliveredAt)
        self.dwellScheduled = try container.decodeIfPresent(Bool.self, forKey: .dwellScheduled) ?? false
        self.dwellScheduledFor = try container.decodeIfPresent(Date.self, forKey: .dwellScheduledFor)
        self.lastDrinkLoggedAt = try container.decodeIfPresent(Date.self, forKey: .lastDrinkLoggedAt)
        self.sessionReminderScheduledFor =
            try container.decodeIfPresent(Date.self, forKey: .sessionReminderScheduledFor)
        self.sessionRemindersFired =
            try container.decodeIfPresent(Int.self, forKey: .sessionRemindersFired) ?? 0
        self.isSuppressed = try container.decodeIfPresent(Bool.self, forKey: .isSuppressed) ?? false
    }

    public var isInside: Bool { lastExitedAt == nil }

    /// SPEC §2: "One follow-up maximum per visit — after that, silence."
    public func hasSpentDwellFollowUp(asOf now: Date) -> Bool {
        if dwellDeliveredAt != nil { return true }
        if let due = dwellScheduledFor, due <= now { return true }
        return false
    }

    /// Whether a follow-up may still be armed: none spent, nothing logged, and
    /// the user has not said they are not drinking.
    public func wantsDwellFollowUp(asOf now: Date) -> Bool {
        !hasSpentDwellFollowUp(asOf: now) && lastDrinkLoggedAt == nil && !isSuppressed
    }

    /// How many of SPEC §2's two mid-Session reminders this visit has used.
    ///
    /// The pending one counts the moment its date passes — see
    /// `sessionReminderScheduledFor`.
    public func spentSessionReminders(asOf now: Date) -> Int {
        guard let due = sessionReminderScheduledFor, due <= now else { return sessionRemindersFired }
        return sessionRemindersFired + 1
    }

    /// Whether a mid-Session reminder may be armed.
    ///
    /// Every clause is one of SPEC §2's conditions, and the first two are the
    /// ones that keep this from becoming a second dwell prompt:
    /// * **a Session is running here** — "once a Session is running at the venue";
    ///   with nothing logged this visit the dwell follow-up owns the silence;
    /// * **the visit is still ongoing** — "the venue-presence condition is
    ///   load-bearing: without it this would nag people who simply stopped
    ///   drinking";
    /// * not suppressed, and under the two-per-visit cap.
    public func wantsSessionReminder(asOf now: Date) -> Bool {
        lastDrinkLoggedAt != nil
            && isInside
            && !isSuppressed
            && spentSessionReminders(asOf: now) < Self.maxSessionReminders
    }
}

// MARK: - State

/// Every open visit, keyed by venue.
///
/// Persisted between launches (`RadarStore`): a geofence entry can wake the app
/// in the background hours after it was last foregrounded, and losing the visit
/// would re-prompt someone who already said no.
nonisolated public struct RadarVisitState: Hashable, Sendable, Codable {

    public private(set) var visits: [RadarVisit]

    public init(visits: [RadarVisit] = []) {
        self.visits = visits
    }

    public func visit(atVenue venueID: UUID) -> RadarVisit? {
        visits.first { $0.venueID == venueID }
    }

    public func visit(id: UUID) -> RadarVisit? {
        visits.first { $0.id == id }
    }

    public mutating func upsert(_ visit: RadarVisit) {
        if let index = visits.firstIndex(where: { $0.id == visit.id }) {
            visits[index] = visit
        } else {
            visits.removeAll { $0.venueID == visit.venueID }
            visits.append(visit)
        }
    }

    public mutating func remove(id: UUID) {
        visits.removeAll { $0.id == id }
    }

    public mutating func removeAll() {
        visits.removeAll()
    }
}

// MARK: - Inputs

/// Everything that can move a Tier 1 visit forward.
nonisolated public enum RadarVisitInput: Hashable, Sendable {

    case entered(target: RadarTarget, at: Date)
    case exited(venueID: UUID, at: Date)

    /// Any drink logged anywhere — from the app, the widget, the watch, or the
    /// notification's own "+1 drink" button.
    case drinkLogged(at: Date)

    /// The follow-up actually fired. Spends the one-per-visit budget.
    case dwellDelivered(visitID: UUID, at: Date)

    /// The "Not drinking tonight" button.
    case declined(visitID: UUID, at: Date)
}

// MARK: - Machine

/// The Tier 1 rules of SPEC §2, as a pure function of state and one input.
///
/// The rules, verbatim from the spec, and where each one lives below:
/// * **On entry** — auto check-in, fire the arrival prompt, arm the follow-up.
/// * **Dwell follow-up** at +45 min (configurable), "cancelled if any drink gets
///   logged or the exit event fires first", **one maximum per visit**.
/// * **Mid-Session reminder** at +60 min (configurable) after the *last logged
///   drink*, while the visit is still ongoing: "Any log resets the timer; the
///   geofence exit or 'Not drinking tonight' cancels it; **two maximum per
///   visit**." The two prompts never overlap — the dwell follow-up speaks only
///   before the first drink, this one only after it.
/// * **Exit** closes the Session (an exit is an input to `SessionDeriver`), and —
///   when anything was logged during the visit — asks for the **Session true-up**:
///   "when a Session with ≥1 drink closes, one reconciliation prompt."
/// * **"Exit followed by re-entry within 2 h counts as the same visit"** —
///   stepping outside must not re-trigger the arrival prompt.
nonisolated public struct RadarVisitMachine: Sendable {

    // MARK: Configuration

    nonisolated public struct Configuration: Hashable, Sendable {

        /// SPEC §2: "re-entry within 2 h counts as the same visit".
        public var reentryWindow: TimeInterval

        /// SPEC §2: "+45 min (configurable)", read from `TallyDefaults`.
        public var dwellDelay: TimeInterval

        /// SPEC §2's mid-Session reminder: "no drink has been logged for 60 min
        /// (configurable)". Measured from the last drink, not from arrival.
        public var sessionReminderDelay: TimeInterval

        /// How long a visit that never got an exit event is kept. A missed exit
        /// is a normal CoreLocation outcome; without this, one stale visit would
        /// silence a venue forever.
        public var staleVisitAge: TimeInterval

        /// The two delays mirror `TallyDefaults.Fallback.barRadarDwellMinutes`
        /// (45 min) and `.barRadarSessionReminderMinutes` (60 min), written out
        /// because that enum is main-actor isolated and this machine has to stay
        /// usable from anywhere.
        public init(
            reentryWindow: TimeInterval = 2 * 60 * 60,
            dwellDelay: TimeInterval = 45 * 60,
            sessionReminderDelay: TimeInterval = 60 * 60,
            staleVisitAge: TimeInterval = 12 * 60 * 60
        ) {
            self.reentryWindow = max(0, reentryWindow)
            self.dwellDelay = max(60, dwellDelay)
            self.sessionReminderDelay = max(60, sessionReminderDelay)
            self.staleVisitAge = max(reentryWindow, staleVisitAge)
        }

        public static let `default` = Configuration()
    }

    public var configuration: Configuration

    /// Injected so a test can assert on visit identity. Production uses `UUID()`.
    public var makeVisitID: @Sendable () -> UUID

    public init(
        configuration: Configuration = .default,
        makeVisitID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.configuration = configuration
        self.makeVisitID = makeVisitID
    }

    // MARK: Outcome

    nonisolated public struct Outcome: Hashable, Sendable {
        public var state: RadarVisitState
        public var effects: [RadarEffect]

        public init(state: RadarVisitState, effects: [RadarEffect] = []) {
            self.state = state
            self.effects = effects
        }
    }

    // MARK: Reduce

    public func handle(_ input: RadarVisitInput, state: RadarVisitState) -> Outcome {
        var state = prune(state, asOf: date(of: input))

        switch input {
        case .entered(let target, let at):
            return entered(target: target, at: at, state: &state)

        case .exited(let venueID, let at):
            return exited(venueID: venueID, at: at, state: &state)

        case .drinkLogged(let at):
            return drinkLogged(at: at, state: &state)

        case .dwellDelivered(let visitID, let at):
            guard var visit = state.visit(id: visitID) else { return Outcome(state: state) }
            visit.dwellDeliveredAt = at
            visit.dwellScheduled = false
            state.upsert(visit)
            return Outcome(state: state)

        case .declined(let visitID, let at):
            guard var visit = state.visit(id: visitID) else { return Outcome(state: state) }
            visit.isSuppressed = true
            // SPEC §2: "the geofence exit or 'Not drinking tonight' cancels it".
            let effects = [
                cancelDwell(&visit, at: at),
                cancelSessionReminder(&visit, at: at)
            ].compactMap { $0 }
            state.upsert(visit)
            return Outcome(state: state, effects: effects)
        }
    }

    // MARK: Entry

    private func entered(target: RadarTarget, at: Date, state: inout RadarVisitState) -> Outcome {

        if var existing = state.visit(atVenue: target.venueID) {

            // Already inside: CoreLocation re-delivering a satisfied condition is
            // not a new arrival, and must never re-prompt.
            if existing.isInside {
                return Outcome(state: state)
            }

            // SPEC §2: "Exit followed by re-entry within 2 h counts as the same
            // visit (stepping outside shouldn't re-trigger the arrival prompt)."
            if let exitedAt = existing.lastExitedAt,
               at.timeIntervalSince(exitedAt) <= configuration.reentryWindow {

                existing.lastExitedAt = nil
                existing.lastEnteredAt = at
                // A venue renamed since the entry prompt should say its new name.
                existing.venueName = target.name

                var effects: [RadarEffect] = [
                    .autoCheckIn(venueID: target.venueID, visitID: existing.id)
                ]

                // The exit cancelled the pending follow-up. Coming back inside
                // re-arms it — still one delivery maximum, since a visit that has
                // already had its follow-up (or a drink, or a "not tonight") does
                // not want another.
                if existing.wantsDwellFollowUp(asOf: at) {
                    let due = at.addingTimeInterval(configuration.dwellDelay)
                    existing.dwellScheduled = true
                    existing.dwellScheduledFor = due
                    effects.append(
                        .scheduleDwell(prompt(.dwell, visit: existing, target: target), at: due)
                    )
                }

                // Same story for the mid-Session reminder the exit pulled: a
                // Session that was running when they stepped out is running again
                // now they are back, and still under the two-per-visit cap.
                if existing.wantsSessionReminder(asOf: at), let drink = existing.lastDrinkLoggedAt {
                    let due = sessionReminderDue(after: drink, notBefore: at)
                    existing.sessionReminderScheduledFor = due
                    effects.append(.scheduleSessionReminder(sessionReminderPrompt(existing), at: due))
                }

                state.upsert(existing)
                return Outcome(state: state, effects: effects)
            }

            // Out for longer than the window: that outing is over.
            state.remove(id: existing.id)
        }

        let due = at.addingTimeInterval(configuration.dwellDelay)
        // No mid-Session reminder is armed here: nothing has been logged yet, so
        // SPEC §2's "once a Session is running at the venue" is not satisfied and
        // the dwell follow-up above owns this stretch of the visit.
        let visit = RadarVisit(
            id: makeVisitID(),
            venueID: target.venueID,
            startedAt: at,
            venueName: target.name,
            arrivalPromptedAt: at,
            dwellScheduled: true,
            dwellScheduledFor: due
        )

        let effects: [RadarEffect] = [
            // SPEC §2: "auto check-in to the venue (it's known — no confirmation
            // sheet needed)".
            .autoCheckIn(venueID: target.venueID, visitID: visit.id),
            .deliver(prompt(.arrival, visit: visit, target: target)),
            .scheduleDwell(prompt(.dwell, visit: visit, target: target), at: due)
        ]

        state.upsert(visit)
        return Outcome(state: state, effects: effects)
    }

    // MARK: Exit

    private func exited(venueID: UUID, at: Date, state: inout RadarVisitState) -> Outcome {

        guard var visit = state.visit(atVenue: venueID) else {
            // An exit with no visit still closes the Session — CoreLocation can
            // deliver an exit for a region the app was not running to enter.
            return Outcome(state: state, effects: [.recordExit(venueID: venueID, at: at)])
        }

        guard visit.isInside else { return Outcome(state: state) }

        visit.lastExitedAt = at

        // SPEC §2: a Session "closes … immediately when a Bar Radar exit event
        // fires, whichever comes first".
        var effects: [RadarEffect] = [.recordExit(venueID: venueID, at: at)]

        // SPEC §2: the follow-up "is cancelled if … the exit event fires first".
        if let cancel = cancelDwell(&visit, at: at) { effects.append(cancel) }

        // SPEC §2: "the geofence exit … cancels it". The venue-presence condition
        // is the point of the reminder, and it is no longer met.
        if let cancel = cancelSessionReminder(&visit, at: at) { effects.append(cancel) }

        // SPEC §2's Session true-up: "when a Session with ≥1 drink closes, one
        // reconciliation prompt … a geofence exit delivers immediately".
        //
        // A drink logged during this visit is all the evidence this machine can
        // have that the Session the exit just closed has something in it — the
        // counts themselves come from the event log, which is the service's job.
        // Emitted last, because it describes the outcome of `.recordExit` above.
        //
        // Not gated on `isSuppressed`: "Not drinking tonight" silences the
        // prompts that ask someone to *log*, and a visit that then logged drinks
        // has answered that question already. SPEC §2 says the true-up "fires on
        // every close", and the timeout path below has no visit to consult
        // anyway — honouring the flag here alone would make the behaviour depend
        // on which path happened to win the race.
        if visit.lastDrinkLoggedAt != nil {
            effects.append(.deliverTrueUp(venueID: venueID, closedAt: at))
        }

        state.upsert(visit)
        return Outcome(state: state, effects: effects)
    }

    // MARK: Drink

    private func drinkLogged(at: Date, state: inout RadarVisitState) -> Outcome {

        var effects: [RadarEffect] = []

        for var visit in state.visits where visit.isInside {
            visit.lastDrinkLoggedAt = at
            // SPEC §2: the follow-up "is cancelled if any drink gets logged".
            if let cancel = cancelDwell(&visit, at: at) { effects.append(cancel) }

            // SPEC §2: "Any log resets the timer." Retract whatever was pending
            // and re-arm from this drink's own timestamp — one reminder in flight
            // per visit, never a queue of them. Cancelling first is what settles
            // the cap: a reminder that had already fired is banked here.
            if let cancel = cancelSessionReminder(&visit, at: at) { effects.append(cancel) }

            if visit.wantsSessionReminder(asOf: at) {
                let due = sessionReminderDue(after: at, notBefore: at)
                visit.sessionReminderScheduledFor = due
                effects.append(.scheduleSessionReminder(sessionReminderPrompt(visit), at: due))
            }

            state.upsert(visit)
        }

        return Outcome(state: state, effects: effects)
    }

    // MARK: Helpers

    /// Retracts a pending follow-up, if there is anything left to retract.
    ///
    /// The distinction matters for SPEC §2's "one follow-up maximum per visit":
    /// a follow-up that has **already fired** cannot be cancelled and must stay
    /// spent, or stepping outside an hour into the night would silently buy a
    /// second one. Only a follow-up still in the future is genuinely withdrawn.
    private func cancelDwell(_ visit: inout RadarVisit, at: Date) -> RadarEffect? {
        guard visit.dwellScheduled else { return nil }
        visit.dwellScheduled = false

        guard let due = visit.dwellScheduledFor, due > at else { return nil }
        visit.dwellScheduledFor = nil
        return .cancelDwell(visitID: visit.id)
    }

    /// Retracts a pending mid-Session reminder, and settles the cap on the way.
    ///
    /// Three outcomes, and the middle one is SPEC §2's "two maximum per visit":
    /// * nothing armed — no state change, no effect;
    /// * armed and **already due** — it fired without telling anyone, so it is
    ///   banked as spent and there is nothing left to cancel;
    /// * armed and still in the future — genuinely withdrawn, and it cost the
    ///   visit nothing.
    private func cancelSessionReminder(_ visit: inout RadarVisit, at: Date) -> RadarEffect? {
        guard let due = visit.sessionReminderScheduledFor else { return nil }
        visit.sessionReminderScheduledFor = nil

        guard due > at else {
            visit.sessionRemindersFired += 1
            return nil
        }
        return .cancelSessionReminder(visitID: visit.id)
    }

    /// SPEC §2 measures the interval "since the last log", so the clock is the
    /// drink's own timestamp.
    ///
    /// `notBefore` only bites on re-entry: an interval that ran out while the
    /// user was outside was never a *mid-Session* interval — the venue-presence
    /// condition SPEC §2 calls load-bearing was not met — so rather than firing
    /// the moment they walk back in, the clock restarts from the doorway.
    private func sessionReminderDue(after drink: Date, notBefore floor: Date) -> Date {
        let due = drink.addingTimeInterval(configuration.sessionReminderDelay)
        return due > floor ? due : floor.addingTimeInterval(configuration.sessionReminderDelay)
    }

    /// Built from the visit rather than a `RadarTarget`: a logged drink is the
    /// trigger, and it arrives with no idea where it happened.
    private func sessionReminderPrompt(_ visit: RadarVisit) -> RadarPrompt {
        RadarPrompt(
            kind: .sessionReminder,
            visitID: visit.id,
            placeName: visit.venueName ?? "",
            venueID: visit.venueID
        )
    }

    private func prompt(_ kind: RadarPrompt.Kind, visit: RadarVisit, target: RadarTarget) -> RadarPrompt {
        RadarPrompt(
            kind: kind,
            visitID: visit.id,
            placeName: target.name,
            venueID: target.venueID
        )
    }

    private func date(of input: RadarVisitInput) -> Date {
        switch input {
        case .entered(_, let at), .exited(_, let at), .drinkLogged(let at):
            at
        case .dwellDelivered(_, let at), .declined(_, let at):
            at
        }
    }

    /// Drops visits that can no longer matter: departed longer ago than the
    /// re-entry window, or inside for implausibly long after a missed exit.
    public func prune(_ state: RadarVisitState, asOf now: Date) -> RadarVisitState {
        var pruned = state
        for visit in state.visits {
            if let exitedAt = visit.lastExitedAt,
               now.timeIntervalSince(exitedAt) > configuration.reentryWindow {
                pruned.remove(id: visit.id)
            } else if now.timeIntervalSince(visit.lastEnteredAt) > configuration.staleVisitAge {
                pruned.remove(id: visit.id)
            }
        }
        return pruned
    }
}
