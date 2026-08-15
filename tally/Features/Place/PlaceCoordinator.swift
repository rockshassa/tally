import CoreLocation
import Foundation
import Observation
import SwiftData
import TallyKit

/// The one object the rest of the app talks to about *where* (SPEC §2).
///
/// Owns the whole pipeline: take a fix, attach it to the event that was already
/// logged, walk steps 1–4, and publish `pendingCheckIn` when — and only when —
/// there is a single confident candidate. The tap that started all this has long
/// since returned: nothing in here can block or fail a log (SPEC §1, §2).
@MainActor
@Observable
public final class PlaceCoordinator {

    // MARK: - Published state

    /// Non-nil when the check-in sheet should be showing. The integrator's
    /// `checkInSheet(context:)` slot binds to this.
    public private(set) var pendingCheckIn: CheckInPrompt?

    /// The venue tagged onto the most recent logged drink, if any. Lets the
    /// Tally screen name the place on its live Session card without re-deriving.
    public private(set) var lastResolvedVenueID: UUID?

    /// Set when a fix was skipped because permission is missing. Surfaces the
    /// inline "enable location to tag venues" affordance — never a popup (SPEC §9).
    public private(set) var lastOutcome: VenueInferenceOutcome?

    // MARK: - Dependencies

    private let modelContext: ModelContext
    private let locationService: any LocationFixProviding
    private let poiSearch: any POISearching
    private let inference: VenueInference
    private let deriver: SessionDeriver
    private let memory: CheckInMemory

    public init(
        modelContext: ModelContext,
        locationService: (any LocationFixProviding)? = nil,
        poiSearch: (any POISearching)? = nil,
        inference: VenueInference = VenueInference(),
        deriver: SessionDeriver = SessionDeriver(),
        memory: CheckInMemory? = nil
    ) {
        self.modelContext = modelContext
        self.locationService = locationService ?? LocationService()
        self.poiSearch = poiSearch ?? POISearchService()
        self.inference = inference
        self.deriver = deriver
        self.memory = memory ?? CheckInMemory()
    }

    // MARK: - Location passthrough

    public var locationAuthorization: LocationAuthorization {
        locationService.authorization
    }

    /// A bare fix, for the Home-setup map's "start where I am".
    public func currentFix() async -> LocationFix? {
        await locationService.oneShotFix(timeout: inference.configuration.fixTimeout)
    }

    // MARK: - The pipeline

    /// Call once per logged drink, right after `EventStore.logDrink` returns.
    ///
    /// Fire-and-forget by design — the count is already on screen. The result is
    /// returned for tests and for callers that want to react; UI can just read
    /// `pendingCheckIn` afterwards.
    @discardableResult
    public func attachPlace(toEventWith eventID: UUID) async -> VenueInferenceOutcome {
        let outcome = await runPipeline(eventID: eventID)
        lastOutcome = outcome
        return outcome
    }

    private func runPipeline(eventID: UUID) async -> VenueInferenceOutcome {

        guard let fix = await locationService.oneShotFix(timeout: inference.configuration.fixTimeout) else {
            // SPEC §2: "If permission is denied, logging still works; events just
            // have no location." Same for a timeout (SPEC §6).
            return .noFix
        }

        try? VenueWriter.attach(fix: fix, toEventWith: eventID, in: modelContext)

        let venues = (try? EventStore.venues(in: modelContext)) ?? []

        // Step 1 — user venues first. Home, then any previously confirmed bar.
        if let saved = inference.savedVenue(for: fix, in: venues) {
            tagEvent(eventID, venueID: saved.id)
            return .savedVenue(saved.id)
        }

        // The Session this drink belongs to — the unit the prompt is scoped to.
        guard let session = currentSession(containing: eventID) else {
            return .coordinatesOnly
        }

        // Asked and answered for this outing (SPEC §2 step 3).
        switch memory.decision(for: session.id) {
        case .confirmed(let venueID):
            tagEvent(eventID, venueID: venueID)
            return .sessionMemory(venueID)
        case .dismissed:
            return .sessionMemory(nil)
        case nil:
            break
        }

        // A Session that already has a venue keeps it: the check-in happened on
        // an earlier drink, possibly in a previous launch.
        if let venueID = session.venueID {
            tagEvent(eventID, venueID: venueID)
            return .sessionMemory(venueID)
        }

        // Step 2 — POI lookup around the fix.
        let poiResults = await poiSearch.nearbyVenues(
            around: fix,
            radiusMeters: inference.configuration.searchRadius(for: fix)
        )
        let candidates = inference.merge(
            poiCandidates: poiResults,
            savedVenues: venues.filter { !$0.category.isHome },
            fix: fix,
            withinMeters: inference.configuration.searchRadius(for: fix)
        )

        // Step 3 — a single confident candidate, or step 4's silence.
        guard let primary = inference.confidentCandidate(among: candidates, fix: fix) else {
            return .coordinatesOnly
        }

        let context = CheckInPrompt(
            sessionID: session.id,
            eventID: eventID,
            primary: primary,
            alternates: inference.alternates(among: candidates, excluding: primary),
            fix: fix
        )
        pendingCheckIn = context
        return .prompt(context)
    }

    // MARK: - Check-in resolution

    /// Confirming "creates/reuses the Venue and tags the Session's events"
    /// (SPEC §2). Every later drink in the outing then auto-tags silently.
    public func confirmCheckIn(_ candidate: VenueCandidate, in context: CheckInPrompt? = nil) {
        guard let context = context ?? pendingCheckIn else { return }
        pendingCheckIn = nil

        guard let venue = try? VenueWriter.resolveVenue(for: candidate, in: modelContext) else { return }

        let eventIDs = currentSession(containing: context.eventID)?.eventIDs ?? [context.eventID]
        try? VenueWriter.tag(eventIDs: eventIDs, with: venue, in: modelContext)

        memory.recordConfirmation(venueID: venue.id, for: context.sessionID)
        lastResolvedVenueID = venue.id
    }

    /// "Dismissing tags nothing and doesn't re-prompt this Session" (SPEC §2).
    public func dismissCheckIn(_ context: CheckInPrompt? = nil) {
        guard let context = context ?? pendingCheckIn else { return }
        pendingCheckIn = nil
        memory.recordDismissal(for: context.sessionID)
    }

    /// Lets a host clear the sheet without recording an answer — e.g. the app
    /// going to the background mid-prompt.
    public func cancelPendingCheckIn() {
        pendingCheckIn = nil
    }

    // MARK: - Helpers

    private func currentSession(containing eventID: UUID) -> DerivedSession? {
        guard let sessions = try? deriver.derive(in: modelContext) else { return nil }
        return sessions.first { $0.events.contains { $0.id == eventID } }
    }

    private func tagEvent(_ eventID: UUID, venueID: UUID) {
        guard let venue = try? EventStore.venue(id: venueID, in: modelContext) else { return }
        try? VenueWriter.tag(eventIDs: [eventID], with: venue, in: modelContext)
        lastResolvedVenueID = venueID
    }
}
