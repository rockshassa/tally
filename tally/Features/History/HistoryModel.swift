import Foundation
import Observation
import SwiftData
import TallyKit

/// Reads the log, derives the Sessions, scores them (SPEC §1: derive, don't
/// store) and owns the writes History is allowed to make.
///
/// Every annotation goes through `materialize(_:)` first — SPEC §2's
/// materialize-on-touch: "any Session in History can be given a note or
/// pinned; either action materializes it."
@MainActor
@Observable
public final class HistoryModel {

    // MARK: State

    public private(set) var sessions: [DerivedSession] = []
    public private(set) var venues: [UUID: VenueSnapshot] = [:]
    public private(set) var scores: [UUID: SessionScore] = [:]

    /// Rises once the first load has run, so the empty state doesn't flash.
    public private(set) var hasLoaded = false

    // MARK: Dependencies

    private let modelContext: ModelContext
    private let deriver: SessionDeriver
    private let scoring: ScoringEngine

    public init(
        modelContext: ModelContext,
        deriver: SessionDeriver = SessionDeriver(),
        scoring: ScoringEngine = ScoringEngine()
    ) {
        self.modelContext = modelContext
        self.deriver = deriver
        self.scoring = scoring
    }

    // MARK: Loading

    public func reload(asOf now: Date = Date()) {
        let derived = (try? deriver.derive(in: modelContext)) ?? []
        sessions = derived.sorted(by: DerivedSession.isOrderedForHistory)
        venues = ((try? EventStore.venues(in: modelContext)) ?? []).byID
        scores = scoring.scores(for: derived, asOf: now).reduce(into: [:]) { $0[$1.sessionID] = $1 }
        hasLoaded = true
    }

    /// Re-reads one Session after an edit, so detail views can refresh without
    /// re-rendering the whole list.
    public func session(id: UUID) -> DerivedSession? {
        sessions.first { $0.id == id }
    }

    public func venue(for session: DerivedSession) -> VenueSnapshot? {
        session.venueID.flatMap { venues[$0] }
    }

    public func score(for session: DerivedSession) -> SessionScore {
        scores[session.id] ?? SessionScore(
            sessionID: session.id,
            nonAlcoholicPoints: 0,
            spacerPoints: 0,
            balancedSessionPoints: 0
        )
    }

    /// The badge a Session row wears, if any (SPEC §3). Designated Legend beats
    /// Pacer because it's the rarer night.
    public func badge(for session: DerivedSession) -> Badge? {
        if scoring.isDesignatedLegend(session, venue: venue(for: session)) { return .designatedLegend }
        if scoring.isPacer(session) { return .pacer }
        return nil
    }

    // MARK: Sections

    /// SPEC §2: pinned Sessions are surfaced. They keep their own section rather
    /// than jumping the chronology inside one list.
    public var pinnedSessions: [DerivedSession] {
        sessions.filter(\.pinned)
    }

    public var unpinnedSessions: [DerivedSession] {
        sessions.filter { !$0.pinned }
    }

    // MARK: Materialize-on-touch (SPEC §2)

    @discardableResult
    public func materialize(_ session: DerivedSession) -> TallyKit.Session? {
        try? EventStore.materialize(session, in: modelContext)
    }

    /// Notes materialize. An empty note clears the annotation but leaves the
    /// record — once an identity exists, dropping it could dangle a reference.
    public func setNote(_ note: String?, on session: DerivedSession) {
        guard let record = materialize(session) else { return }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        record.note = (trimmed?.isEmpty ?? true) ? nil : trimmed
        save()
    }

    public func setPinned(_ pinned: Bool, on session: DerivedSession) {
        guard let record = materialize(session) else { return }
        record.pinned = pinned
        save()
    }

    public func togglePin(on session: DerivedSession) {
        setPinned(!session.pinned, on: session)
    }

    // MARK: Venue assignment (SPEC §2 step 4)

    /// "Ambiguous or no results: tag with raw coordinates only; the history view
    /// lets you assign a venue later."
    ///
    /// Tags every event in the Session, which is what keeps the deriver from
    /// splitting the outing on a venue change. Materializing is *not* required
    /// here — the derived Session picks the venue up from its events — but a
    /// Session that is already materialized gets its record repointed too.
    public func assignVenue(_ candidate: VenueCandidate, to session: DerivedSession) {
        guard let venue = try? VenueWriter.resolveVenue(for: candidate, in: modelContext) else { return }
        try? VenueWriter.tag(eventIDs: session.eventIDs, with: venue, in: modelContext)
        if session.isMaterialized, let record = try? EventStore.session(id: session.id, in: modelContext) {
            record.venue = venue
            save()
        }
        reload()
    }

    public func clearVenue(from session: DerivedSession) {
        try? VenueWriter.tag(eventIDs: session.eventIDs, with: nil, in: modelContext)
        if session.isMaterialized, let record = try? EventStore.session(id: session.id, in: modelContext) {
            record.venue = nil
            save()
        }
        reload()
    }

    // MARK: Event editing

    /// Retro-corrects a drink's time. An edit can move an event out of a
    /// materialized window — that is TallyKit's documented behavior, and the
    /// reason materialized records own their identity in the first place.
    public func updateTimestamp(_ timestamp: Date, forEventWith id: UUID) {
        guard let event = try? EventStore.event(id: id, in: modelContext) else { return }
        event.timestamp = timestamp
        save()
        reload()
    }

    /// Undo semantics from SPEC §1: deleting an event removes it outright,
    /// location and venue included.
    public func deleteEvent(id: UUID) {
        guard let event = try? EventStore.event(id: id, in: modelContext) else { return }
        modelContext.delete(event)
        save()
        reload()
    }

    // MARK: Venue directory

    /// Saved venues, for the "already know this one" half of venue assignment.
    public func savedVenues() -> [VenueSnapshot] {
        ((try? EventStore.venues(in: modelContext)) ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func save() {
        try? modelContext.save()
    }
}
