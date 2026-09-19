import CoreLocation
import Foundation
import Observation
import TallyKit

/// The typing half of SPEC §2's venue search.
///
/// > debounced (~300 ms), one in-flight request at a time, stale responses
/// > discarded.
///
/// One model, two screens: the check-in picker's field and History's venue
/// assignment both own one of these, because "search as you type" is the same
/// problem in both places and a second implementation would be a second set of
/// race conditions.
///
/// Three rules, and everything else falls out of them:
/// * **Debounce** — a keystroke schedules, it does not search.
/// * **Cancel** — the next keystroke cancels the one before it, so the service
///   sees one request per pause rather than one per letter.
/// * **Generation** — a response that comes back for anything but the current
///   query is dropped, whether it was cancelled, slow, or both. Cancellation is
///   cooperative and MapKit's is best-effort; the counter is what makes "stale
///   responses discarded" true rather than likely.
@MainActor
@Observable
public final class VenueSearchModel {

    /// What the list should be showing. `empty` and `unavailable` are
    /// deliberately different states — SPEC §2: "A failed lookup reads as
    /// *Search unavailable*, never as *No match*."
    public enum State: Hashable, Sendable {

        /// Nothing typed, or not enough of it.
        case idle
        /// A request is scheduled or in flight.
        case searching
        /// `results` is non-empty.
        case results
        /// MapKit answered, and the answer was nothing.
        case empty
        /// MapKit could not answer at all.
        case unavailable
    }

    /// SPEC §2's "~300 ms".
    nonisolated public static let defaultDebounce: Duration = .milliseconds(300)

    /// One letter is not a search; it is a round trip for every bar in town.
    nonisolated public static let minimumQueryLength = 2

    // MARK: - State

    /// Bound straight to the search field. Setting it is the only trigger.
    public var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            queryDidChange()
        }
    }

    public private(set) var results: [VenueCandidate] = []

    public private(set) var state: State = .idle

    /// Where results are measured and biased from. The picker sets this when
    /// its one-shot fix lands; History anchors it on where the drinks were
    /// logged. Changing it does not re-search — the next keystroke will.
    public var anchor: LocationFix?

    // MARK: - Dependencies

    @ObservationIgnored private let injectedService: (any POISearching)?
    @ObservationIgnored private var resolvedService: (any POISearching)?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let radiusMeters: CLLocationDistance
    @ObservationIgnored private let scope: VenueSearchRequest.Scope

    /// Bumped on every query change; a response carrying anything else is late.
    @ObservationIgnored private var generation = 0

    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - service: omit it and the model makes its own `POISearchService` the
    ///     first time it actually needs one — same lazy resolution the views use.
    ///   - debounce: injectable so tests run in milliseconds rather than
    ///     seconds.
    public init(
        service: (any POISearching)? = nil,
        anchor: LocationFix? = nil,
        debounce: Duration = VenueSearchModel.defaultDebounce,
        radiusMeters: CLLocationDistance = VenueSearchRequest.defaultRadiusMeters,
        scope: VenueSearchRequest.Scope = .bars
    ) {
        self.injectedService = service
        self.anchor = anchor
        self.debounce = debounce
        self.radiusMeters = radiusMeters
        self.scope = scope
    }

    // MARK: - Driving

    /// Drops any scheduled or in-flight search and goes quiet. The sheet closing
    /// is not a reason to keep talking to MapKit.
    public func cancel() {
        task?.cancel()
        task = nil
    }

    /// Back to nothing typed — what the field's clear button does.
    public func clear() {
        query = ""
    }

    private func queryDidChange() {

        task?.cancel()
        generation &+= 1
        let generation = generation

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryLength else {
            // Below the threshold there is nothing to show and nothing to ask:
            // the list falls back to what is nearby (SPEC §2's picker) or to the
            // saved venues (History).
            task = nil
            results = []
            state = .idle
            return
        }

        state = .searching

        task = Task { [weak self] in
            guard let self else { return }
            // A keystroke inside the window cancels this before it ever reaches
            // the service — which is what "one request per pause" means.
            do { try await Task.sleep(for: self.debounce) } catch { return }
            await self.run(query: trimmed, generation: generation)
        }
    }

    private func run(query: String, generation: Int) async {

        let anchor = anchor
        let request = VenueSearchRequest(
            query: query,
            anchor: anchor,
            radiusMeters: radiusMeters,
            scope: scope
        )

        do {
            let found = try await service().search(request)
            guard generation == self.generation else { return }
            results = VenueSearchRanking.rank(found, query: query, anchor: anchor)
            state = results.isEmpty ? .empty : .results
        } catch {
            // A cancelled pass is not a failed one: the field moved on, and
            // *Search unavailable* would be reporting the app's own decision
            // back to the user as MapKit's.
            guard !Task.isCancelled, generation == self.generation else { return }
            results = []
            state = .unavailable
        }
    }

    private func service() -> any POISearching {
        if let injectedService { return injectedService }
        if let resolvedService { return resolvedService }
        let service = POISearchService()
        resolvedService = service
        return service
    }
}
