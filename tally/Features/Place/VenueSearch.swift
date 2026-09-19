import CoreLocation
import Foundation
import TallyKit

/// SPEC §2's **venue search**, as values and pure functions.
///
/// > The search field searches MapKit **as you type**: debounced (~300 ms), one
/// > in-flight request at a time, stale responses discarded. Results are
/// > anchored to the fix (or to where the drinks were logged, from History),
/// > tried bar-first (nightlife/brewery/distillery/winery, then
/// > restaurant/cafe), and **widened** — any place, then a wider region — only
/// > when the narrower pass finds nothing, so "bowling alley" still works.
/// > Ranking: name match quality (exact, then prefix, then contains), then bar
/// > categories, then distance.
///
/// Nothing in this file touches MapKit or a view: `POISearchService` executes
/// what `VenueSearchPlan` describes, `VenueSearchModel` drives the typing, and
/// `tallyTests/Place/VenueSearchTests.swift` exercises every decision from a
/// fixture.

// MARK: - Request

/// One MapKit lookup, described rather than performed.
///
/// A pass — not the whole search: `VenueSearchPlan.passes(for:)` expands a
/// user's request into the ordered passes the service actually runs.
nonisolated public struct VenueSearchRequest: Hashable, Sendable {

    /// Which places a pass is allowed to return.
    public enum Scope: String, Hashable, Sendable, CaseIterable {

        /// `POISearchService.categories` — nightlife, brewery, distillery,
        /// winery, restaurant, cafe. The first pass, because the picker only
        /// ever opens in a drinking context.
        case bars

        /// No category filter at all. SPEC §2's widening step: "any place",
        /// which is how a bowling alley or a village hall gets found.
        case anyPlace
    }

    /// Wide enough to cover the next neighbourhood on foot, narrow enough that
    /// a common name still resolves to the one you meant.
    public static let defaultRadiusMeters: CLLocationDistance = 5_000

    /// SPEC §2's "then a wider region" — the last thing tried before giving up.
    public static let widenedRadiusMeters: CLLocationDistance = 50_000

    /// What the user typed. Untrimmed: the field owns the text, this type owns
    /// the trimming.
    public let query: String

    /// Where results are measured and biased from. `nil` searches unbounded —
    /// a History assignment for events that never got a fix (SPEC §6, §7).
    public let anchor: LocationFix?

    /// Half the side of the search box around `anchor`. Ignored without one.
    public let radiusMeters: CLLocationDistance

    public let scope: Scope

    public init(
        query: String,
        anchor: LocationFix? = nil,
        radiusMeters: CLLocationDistance = defaultRadiusMeters,
        scope: Scope = .bars
    ) {
        self.query = query
        self.anchor = anchor
        self.radiusMeters = max(0, radiusMeters)
        self.scope = scope
    }

    public var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same search, run differently. How a plan is built.
    public func with(scope: Scope, radiusMeters: CLLocationDistance? = nil) -> VenueSearchRequest {
        VenueSearchRequest(
            query: query,
            anchor: anchor,
            radiusMeters: radiusMeters ?? self.radiusMeters,
            scope: scope
        )
    }
}

// MARK: - Plan

/// SPEC §2's bar-first-then-widen order, as a pure function.
///
/// The service runs the passes in order and stops at the first one that returns
/// anything — so a bar named "Bowl" wins over a bowling alley, and a bowling
/// alley is still reachable when no bar answers to the name.
nonisolated public enum VenueSearchPlan {

    /// With an anchor: bars nearby, then anywhere nearby, then anywhere in a
    /// much wider region. Without one there is no region to widen, so the
    /// narrowing that remains is the category filter.
    ///
    /// A request that already asked for `.anyPlace` keeps its answer: the
    /// caller opted out of the bar-first pass, and re-adding it here would
    /// override a deliberate choice.
    public static func passes(for request: VenueSearchRequest) -> [VenueSearchRequest] {

        var passes: [VenueSearchRequest] = []

        if request.scope == .bars {
            passes.append(request.with(scope: .bars))
        }
        passes.append(request.with(scope: .anyPlace))

        if request.anchor != nil, request.radiusMeters < VenueSearchRequest.widenedRadiusMeters {
            passes.append(
                request.with(scope: .anyPlace, radiusMeters: VenueSearchRequest.widenedRadiusMeters)
            )
        }

        return passes
    }
}

// MARK: - Failure

/// SPEC §2: "A failed lookup reads as *Search unavailable*, never as *No
/// match*." Which means the failure has to survive the trip back to the view
/// instead of being flattened into an empty array.
nonisolated public enum VenueSearchError: Error, Hashable, Sendable {

    /// MapKit refused or could not answer — offline, throttled, or no route to
    /// the service. The description is for logs, never for the user.
    case lookupFailed(String)
}

// MARK: - Ranking

/// SPEC §2's ranking, dedupe, and saved-venue merge for *remote* results.
///
/// The nearby list has its own order (pure distance — you are standing in it);
/// search results are answers to a name, so the name leads.
nonisolated public enum VenueSearchRanking {

    /// How well a name answers what was typed. Lower is better.
    public enum MatchTier: Int, Comparable, Hashable, Sendable {

        /// "the anchor" for `The Anchor`.
        case exact = 0
        /// "anch" for `The Anchor`'s first word, or the whole name's start.
        case prefix = 1
        /// The letters appear somewhere in the name.
        case contains = 2
        /// MapKit thought it was relevant for a reason of its own.
        case other = 3

        public static func < (lhs: MatchTier, rhs: MatchTier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        /// Diacritic- and case-insensitive throughout: a user typing "cafe"
        /// means "Café".
        public static func of(_ name: String, for query: String) -> MatchTier {
            let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return .other }

            if name.compare(query, options: options) == .orderedSame { return .exact }
            if name.range(of: query, options: options.union(.anchored)) != nil { return .prefix }
            // "Anchor" should be a prefix match for "The Anchor" — the leading
            // article is noise, and MapKit names carry plenty of it.
            if name.split(separator: " ").dropFirst().contains(where: {
                $0.range(of: query, options: options.union(.anchored)) != nil
            }) {
                return .prefix
            }
            if name.range(of: query, options: options) != nil { return .contains }
            return .other
        }
    }

    /// Bars first, then anywhere that plates, then everything else. Home never
    /// reaches a search result, but it sorts last if it ever did.
    public static func categoryRank(_ category: VenueCategory) -> Int {
        switch category {
        case .bar: 0
        case .restaurant: 1
        case .other: 2
        case .home: 3
        }
    }

    /// SPEC §2: "name match quality (exact, then prefix, then contains), then
    /// bar categories, then distance."
    ///
    /// `id` breaks the last tie so the order is stable across identical runs —
    /// a list that reshuffles under the thumb is a list you cannot tap.
    ///
    /// - Parameter anchor: re-measures every candidate before sorting, so a
    ///   result set built against a stale fix ranks against the current one.
    public static func rank(
        _ candidates: [VenueCandidate],
        query: String,
        anchor: LocationFix?
    ) -> [VenueCandidate] {

        CheckInPickerRanking.remeasured(candidates, against: anchor)
            .sorted { lhs, rhs in
                let leftTier = MatchTier.of(lhs.name, for: query)
                let rightTier = MatchTier.of(rhs.name, for: query)
                if leftTier != rightTier { return leftTier < rightTier }

                let leftCategory = categoryRank(lhs.category)
                let rightCategory = categoryRank(rhs.category)
                if leftCategory != rightCategory { return leftCategory < rightCategory }

                if lhs.distanceMeters != rhs.distanceMeters { return lhs.distanceMeters < rhs.distanceMeters }
                return lhs.id < rhs.id
            }
    }

    /// What is left of a remote result set once the rows already on screen have
    /// had their say.
    ///
    /// * A hit that matches something in the local list is dropped — that row
    ///   was measured from the live fix, and one venue is one row (SPEC §1's
    ///   dedupe rule, via `VenueCandidate.matches`).
    /// * A hit that matches a *saved* venue keeps its place but takes the saved
    ///   name and identity, so picking it reuses the record instead of creating
    ///   a second one — `CheckInPickerRanking.merging`, unchanged.
    ///
    /// Order is preserved: whatever ranked this list stays in charge.
    public static func merged(
        remote: [VenueCandidate],
        nearby: [VenueCandidate],
        saved: [VenueSnapshot]
    ) -> [VenueCandidate] {

        var kept: [VenueCandidate] = []

        for candidate in remote {
            let alreadyShown = nearby.contains {
                $0.matches(candidate, proximityMeters: VenueWriter.dedupeProximityMeters)
            }
            guard !alreadyShown else { continue }
            // A remote pass can return the same place twice across name and
            // identity; one venue is one row here too.
            guard !kept.contains(where: {
                $0.matches(candidate, proximityMeters: VenueWriter.dedupeProximityMeters)
            }) else { continue }
            kept.append(candidate)
        }

        return CheckInPickerRanking.merging(poi: kept, savedVenues: saved)
    }
}
