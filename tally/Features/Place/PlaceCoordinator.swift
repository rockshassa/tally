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

    /// Non-nil when the ranked check-in picker should be showing (SPEC §2).
    /// The root view's `.checkInPicker(coordinator:)` modifier binds to this.
    public private(set) var pendingPicker: CheckInPickerRequest?

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

    // MARK: - The app's instance

    /// The coordinator the running app is using, published so surfaces that
    /// cannot be handed one — a notification action handler, which runs before
    /// any view exists — can still reach it (SPEC §2's Bar Radar tap-through).
    ///
    /// `nil` in tests and previews, where nothing has registered one; every
    /// static entry point below degrades rather than trapping.
    public private(set) static var shared: PlaceCoordinator?

    /// Called once, by `PlaceFeatureSlots`, with the instance wired into the
    /// app's slots — so a tap-through resolves against the same pipeline state
    /// (and the same `CheckInMemory`) the check-in sheet uses.
    public static func registerShared(_ coordinator: PlaceCoordinator) {
        shared = coordinator
        if let queued = queuedPickerRequest {
            queuedPickerRequest = nil
            coordinator.present(queued)
        }
    }

    /// A tap-through that arrived before anything was registered. Held rather
    /// than dropped: a notification can launch the app cold, and the tap is the
    /// user asking for a screen.
    private static var queuedPickerRequest: CheckInPickerRequest?

    // MARK: - Picker host claim

    /// Which `.checkInPicker(coordinator:)` modifier owns the presentation.
    ///
    /// Two hosts bound to the same `pendingPicker` would try to present two
    /// sheets for one request, so the first to claim it wins and any later one
    /// stays inert.
    private static var pickerHostID: UUID?

    static func claimPickerHost(_ id: UUID) -> Bool {
        if pickerHostID == nil || pickerHostID == id {
            pickerHostID = id
            return true
        }
        return false
    }

    static func releasePickerHost(_ id: UUID) {
        if pickerHostID == id { pickerHostID = nil }
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

    // MARK: - The check-in picker (SPEC §2)

    /// SPEC §2: "any tap-through from a Bar Radar notification [opens] a ranked
    /// list". The entry point Bar Radar's default action calls.
    ///
    /// No fix is taken here: the picker opens in its "locating…" state and takes
    /// its own one-shot when it appears, so a tap never waits on CoreLocation
    /// before something is on screen.
    ///
    /// If a check-in prompt is already outstanding, the picker adopts it — the
    /// tap is the same user answering the same question, and two sheets over one
    /// Session would be one too many.
    ///
    /// - Parameter suggestion: the venue the notification named, if any. It is
    ///   marked *Suggested* in the list; nothing else about it is assumed.
    public func presentPickerForCurrentFix(suggesting suggestion: VenueCandidate? = nil) {
        if let prompt = pendingCheckIn {
            pendingCheckIn = nil
            present(
                CheckInPickerRequest(
                    id: prompt.sessionID,
                    origin: .checkIn(prompt),
                    fix: prompt.fix,
                    suggestion: suggestion ?? prompt.primary,
                    seeds: prompt.allCandidates
                )
            )
            return
        }
        present(.notification(suggesting: suggestion))
    }

    /// The same thing, for a caller with no coordinator in hand — the
    /// `NotificationService.actionHandler` runs long before any view does.
    ///
    /// - Returns: `true` if a registered coordinator took it now; `false` if it
    ///   was held until one registers (a cold launch from the notification).
    @discardableResult
    public static func presentPickerForCurrentFix(suggesting suggestion: VenueCandidate? = nil) -> Bool {
        guard let shared else {
            queuedPickerRequest = .notification(suggesting: suggestion)
            return false
        }
        shared.presentPickerForCurrentFix(suggesting: suggestion)
        return true
    }

    /// The Tier 1 shape of the same tap: the notification named a saved venue,
    /// so the suggestion is read back out of the store.
    @discardableResult
    public static func presentPickerForCurrentFix(suggestingVenueWith venueID: UUID) -> Bool {
        guard
            let shared,
            let venue = try? EventStore.venue(id: venueID, in: shared.modelContext)
        else {
            return presentPickerForCurrentFix()
        }
        shared.presentPickerForCurrentFix(suggesting: VenueCandidate(venue: venue.snapshot, fix: nil))
        return true
    }

    private func present(_ request: CheckInPickerRequest) {
        pendingPicker = request
    }

    /// SPEC §2: "Picking a venue tags the Session and dismisses."
    ///
    /// One path for both origins. From the check-in sheet that is exactly
    /// `confirmCheckIn`; from a notification there may be no Session yet, in
    /// which case the venue is still resolved — the next drink auto-tags to it
    /// through step 1's geofence check.
    @discardableResult
    public func resolvePicker(_ request: CheckInPickerRequest, with candidate: VenueCandidate) -> UUID? {

        if pendingPicker?.id == request.id { pendingPicker = nil }

        if let prompt = request.prompt {
            confirmCheckIn(candidate, in: prompt)
            return lastResolvedVenueID
        }

        guard let venue = try? VenueWriter.resolveVenue(for: candidate, in: modelContext) else { return nil }

        if let session = activeSession() {
            try? VenueWriter.tag(eventIDs: session.eventIDs, with: venue, in: modelContext)
            memory.recordConfirmation(venueID: venue.id, for: session.id)
        }

        lastResolvedVenueID = venue.id
        return venue.id
    }

    /// Backing out of the picker. From a check-in origin that is the prompt's
    /// "Not now": SPEC §2's "dismissing tags nothing and doesn't re-prompt this
    /// Session". From a notification there is nothing to remember.
    public func dismissPicker(_ request: CheckInPickerRequest? = nil) {
        guard let target = request ?? pendingPicker else { return }
        pendingPicker = nil
        if let prompt = target.prompt {
            memory.recordDismissal(for: prompt.sessionID)
        }
    }

    /// SPEC §2: *Not a bar / don't ask here* "writes a `SuppressedPlace`".
    ///
    /// Written straight to the model rather than through Bar Radar: the radar's
    /// own suppression write is private to a service this feature cannot reach,
    /// so the conventions are matched here instead — same dedupe (map item, or
    /// inside an existing marker's radius), same default radius, same "empty
    /// name means no name".
    @discardableResult
    public func suppressPlace(
        at fix: LocationFix,
        name: String? = nil,
        mapItemID: String? = nil,
        now: Date = Date()
    ) -> Bool {

        let existing = ((try? modelContext.fetch(FetchDescriptor<SuppressedPlace>())) ?? []).contains { place in
            if let mapItemID, place.mapItemID == mapItemID { return true }
            return CLLocation(latitude: place.latitude, longitude: place.longitude)
                .distance(from: fix.clLocation) <= place.radiusMeters
        }
        guard !existing else { return false }

        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        modelContext.insert(
            SuppressedPlace(
                latitude: fix.latitude,
                longitude: fix.longitude,
                mapItemID: mapItemID,
                name: (trimmed?.isEmpty ?? true) ? nil : trimmed,
                createdAt: now
            )
        )
        try? modelContext.save()
        return true
    }

    /// "Not a bar / don't ask here" as the picker performs it: suppress the
    /// spot, and treat the picker as answered so the Session is not re-prompted.
    public func suppressAndDismissPicker(_ request: CheckInPickerRequest, at fix: LocationFix?) {
        if let fix {
            suppressPlace(at: fix, name: request.suggestion?.name, mapItemID: request.suggestion?.mapItemID)
        }
        dismissPicker(request)
    }

    /// Every saved venue, for the picker's "saved venues in range" section.
    public func savedVenues() -> [VenueSnapshot] {
        (try? EventStore.venues(in: modelContext)) ?? []
    }

    // MARK: - Helpers

    private func currentSession(containing eventID: UUID) -> DerivedSession? {
        guard let sessions = try? deriver.derive(in: modelContext) else { return nil }
        return sessions.first { $0.events.contains { $0.id == eventID } }
    }

    /// The Session still accepting drinks, if any — what a notification
    /// tap-through tags, since it arrives with no event of its own.
    private func activeSession(asOf now: Date = Date()) -> DerivedSession? {
        guard let sessions = try? deriver.derive(in: modelContext) else { return nil }
        return sessions.last { $0.startedAt <= now && $0.isActive(asOf: now) }
    }

    private func tagEvent(_ eventID: UUID, venueID: UUID) {
        guard let venue = try? EventStore.venue(id: venueID, in: modelContext) else { return }
        try? VenueWriter.tag(eventIDs: [eventID], with: venue, in: modelContext)
        lastResolvedVenueID = venueID
    }
}
