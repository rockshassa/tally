import CoreLocation
import Foundation
import TallyKit

/// The view-free half of SPEC §2's check-in picker.
///
/// > **Check-in picker.** "Somewhere else nearby…", and any tap-through from a
/// > Bar Radar notification, open a ranked list: every nearby candidate
/// > **ordered by distance**, each row showing name, category, and distance,
/// > with the inferred venue marked.
///
/// Ranking, the saved-venue merge, distance formatting, and the "use what I
/// typed" gate all live here rather than in the view, so every decision the
/// picker makes can be exercised from a fixture — no MapKit, no store, no
/// `ModelContext` (`tallyTests/Place/CheckInPickerTests.swift`).

// MARK: - Request

/// What opened the picker, and everything it starts with.
///
/// Two origins, one screen: the check-in sheet already has a prompt (Session,
/// event, fix, and the candidate inference chose), while a Bar Radar
/// tap-through has nothing but the user's decision to look — SPEC §2: "the
/// inferred venue can be wrong, and the tap is the user saying 'let me look.'"
nonisolated public struct CheckInPickerRequest: Identifiable, Hashable, Sendable {

    public enum Origin: Hashable, Sendable {

        /// "Somewhere else nearby…" — the picker is resolving an outstanding
        /// check-in prompt, so a pick tags that Session and a dismissal answers
        /// it (SPEC §2 step 3).
        case checkIn(CheckInPrompt)

        /// Tapping a Bar Radar notification body. There may be no Session at all
        /// yet: nothing has necessarily been logged.
        case notification
    }

    public let id: UUID
    public let origin: Origin

    /// The fix to rank against. `nil` means "locating…" — the picker takes its
    /// own one-shot fix when it appears (SPEC §2: When-In-Use, one-shot only).
    public let fix: LocationFix?

    /// The candidate the pipeline picked, marked *Suggested* in the list.
    public let suggestion: VenueCandidate?

    /// Candidates already in hand — the prompt's alternates, shown immediately
    /// so the list is never blank while MapKit is still answering.
    public let seeds: [VenueCandidate]

    public init(
        id: UUID = UUID(),
        origin: Origin,
        fix: LocationFix? = nil,
        suggestion: VenueCandidate? = nil,
        seeds: [VenueCandidate] = []
    ) {
        self.id = id
        self.origin = origin
        self.fix = fix
        self.suggestion = suggestion
        self.seeds = seeds
    }

    /// The picker behind "Somewhere else nearby…". Keyed by the Session, like
    /// the prompt it came from — one picker per outing, never one per drink.
    public init(prompt: CheckInPrompt) {
        self.init(
            id: prompt.sessionID,
            origin: .checkIn(prompt),
            fix: prompt.fix,
            suggestion: prompt.primary,
            seeds: prompt.allCandidates
        )
    }

    /// SPEC §2: the Bar Radar tap-through, which knows only which venue the
    /// notification named — if it named one at all.
    public static func notification(
        suggesting suggestion: VenueCandidate? = nil,
        fix: LocationFix? = nil
    ) -> CheckInPickerRequest {
        CheckInPickerRequest(
            origin: .notification,
            fix: fix,
            suggestion: suggestion,
            seeds: suggestion.map { [$0] } ?? []
        )
    }

    public var prompt: CheckInPrompt? {
        if case .checkIn(let prompt) = origin { return prompt }
        return nil
    }

    /// The Session a pick would tag, when the origin knows one. The
    /// notification path resolves its Session at pick time instead — hours can
    /// pass between the banner and the tap.
    public var sessionID: UUID? { prompt?.sessionID }

    public var isFromNotification: Bool { prompt == nil }
}

// MARK: - Ranking

/// Everything that decides *what the picker shows and in what order*.
nonisolated public enum CheckInPickerRanking {

    /// How far the picker looks.
    ///
    /// Deliberately wider than SPEC §2 step 2's ~75 m inference radius, and for
    /// the same reason `VenueAssignmentView` uses 250 m: this list is a
    /// considered choice by a human who is standing there, not a guess the app
    /// makes on its own. Being one door down must not mean being absent.
    public static let radiusMeters: CLLocationDistance = 250

    /// Shorter than this and "Use 'X'" would be offering to create a venue
    /// called "T".
    public static let minimumTypedNameLength = 2

    // MARK: Sections

    /// SPEC §2's two groups: what MapKit found near you, then the venues you
    /// already saved that it didn't return.
    public struct Section: Identifiable, Hashable, Sendable {

        public enum Kind: String, Hashable, Sendable {
            case nearby
            case saved
        }

        public let kind: Kind
        public let candidates: [VenueCandidate]

        public var id: String { kind.rawValue }

        public var title: String {
            switch kind {
            case .nearby: "Nearby"
            case .saved: "Saved venues"
            }
        }

        public init(kind: Kind, candidates: [VenueCandidate]) {
            self.kind = kind
            self.candidates = candidates
        }
    }

    /// The whole list, in display order: nearby POIs by distance ascending,
    /// then in-range saved venues the POI search missed, also by distance.
    ///
    /// - Parameters:
    ///   - poi: whatever the MapKit lookup returned (plus any seeds).
    ///   - savedVenues: every saved `Venue`. Home is dropped — SPEC §2 tags
    ///     drinks at home without ever asking, so offering it here would be
    ///     offering the one answer the pipeline never needs.
    ///   - fix: the current fix. `nil` leaves distances unknown and keeps
    ///     saved venues in the list rather than range-filtering on nothing.
    ///   - query: the search field's contents; filters both sections by name.
    public static func sections(
        poi: [VenueCandidate],
        savedVenues: [VenueSnapshot],
        fix: LocationFix?,
        withinMeters: CLLocationDistance = radiusMeters,
        query: String = ""
    ) -> [Section] {

        let saved = savedVenues.filter { !$0.category.isHome }

        let nearby = filtered(merging(poi: poi, savedVenues: saved), by: query)
            .sorted(by: VenueCandidate.isOrderedBefore)

        let remaining = filtered(
            savedCandidates(saved, notIn: poi, fix: fix, withinMeters: withinMeters),
            by: query
        )
        .sorted(by: VenueCandidate.isOrderedBefore)

        return [
            Section(kind: .nearby, candidates: nearby),
            Section(kind: .saved, candidates: remaining)
        ]
        .filter { !$0.candidates.isEmpty }
    }

    /// The sections flattened into the order they are drawn in — which is the
    /// order `checkIn.picker.row.<index>` counts in.
    public static func rows(in sections: [Section]) -> [VenueCandidate] {
        sections.flatMap(\.candidates)
    }

    // MARK: Saved-venue merge

    /// A POI that is *already* a saved venue is one row, not two.
    ///
    /// SPEC §1's dedupe rule decides it — `mapItemID`, or name + proximity for
    /// user-defined venues — reused verbatim from `VenueCandidate.matches` at
    /// `VenueWriter.dedupeProximityMeters` rather than restated here. The saved
    /// side wins on name, category, and identity (it carries the user's own
    /// wording, and picking it must reuse the record rather than make a second
    /// one); the POI side wins on coordinates and distance, which are fresher.
    public static func merging(poi: [VenueCandidate], savedVenues: [VenueSnapshot]) -> [VenueCandidate] {
        poi.map { candidate in
            guard let saved = savedVenues.first(where: {
                candidate.matches($0, proximityMeters: VenueWriter.dedupeProximityMeters)
            }) else { return candidate }

            return VenueCandidate(
                id: candidate.id,
                name: saved.name,
                category: saved.category,
                latitude: candidate.latitude,
                longitude: candidate.longitude,
                distanceMeters: candidate.distanceMeters,
                mapItemID: candidate.mapItemID ?? saved.mapItemID,
                categoryLabel: saved.category.displayName,
                existingVenueID: saved.id
            )
        }
    }

    /// SPEC §2: "Includes saved venues in range" — the ones the POI search did
    /// not already return.
    public static func savedCandidates(
        _ savedVenues: [VenueSnapshot],
        notIn poi: [VenueCandidate],
        fix: LocationFix?,
        withinMeters: CLLocationDistance = radiusMeters
    ) -> [VenueCandidate] {

        savedVenues
            .filter { venue in
                !poi.contains { $0.matches(venue, proximityMeters: VenueWriter.dedupeProximityMeters) }
            }
            .map { VenueCandidate(venue: $0, fix: fix) }
            // With no fix there is no range to be in or out of, so every saved
            // venue stays: an unplaceable picker is still a usable one.
            .filter { fix == nil || $0.distanceMeters <= withinMeters }
    }

    // MARK: Freshening

    /// SPEC §2's "live-updating distance as a fresh fix arrives", as a pure
    /// function: the same candidates, measured again from where you are now.
    public static func remeasured(
        _ candidates: [VenueCandidate],
        against fix: LocationFix?
    ) -> [VenueCandidate] {

        guard let fix else { return candidates }

        return candidates.map { candidate in
            VenueCandidate(
                id: candidate.id,
                name: candidate.name,
                category: candidate.category,
                latitude: candidate.latitude,
                longitude: candidate.longitude,
                distanceMeters: fix.distance(toLatitude: candidate.latitude, longitude: candidate.longitude),
                mapItemID: candidate.mapItemID,
                categoryLabel: candidate.categoryLabel,
                existingVenueID: candidate.existingVenueID
            )
        }
    }

    /// A fresh result set, plus anything from the previous one it does not
    /// already cover. The new results win every collision — they are the ones
    /// measured from the current fix.
    public static func unioned(
        _ candidates: [VenueCandidate],
        with extras: [VenueCandidate]
    ) -> [VenueCandidate] {

        var result = candidates
        for extra in extras
        where !result.contains(where: { $0.matches(extra, proximityMeters: VenueWriter.dedupeProximityMeters) }) {
            result.append(extra)
        }
        return result.sorted(by: VenueCandidate.isOrderedBefore)
    }

    // MARK: Search

    public static func filtered(_ candidates: [VenueCandidate], by query: String) -> [VenueCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    /// SPEC §2: "a search field for naming a place MapKit doesn't return".
    ///
    /// Offered whenever the typed name is not already one of the rows on
    /// screen — not only when the list is empty, since the place you mean can
    /// be missing while three others still match the letters you typed. An
    /// exact name match suppresses it: that row *is* the answer, and creating a
    /// second venue with the same name is the duplicate SPEC §1 works to avoid.
    ///
    /// Returns `nil` without a fix: a user-defined venue is created "at the
    /// current fix", and one pinned at 0°, 0° would be worse than none.
    public static func typedNameCandidate(
        for query: String,
        matching visible: [VenueCandidate],
        fix: LocationFix?
    ) -> VenueCandidate? {

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumTypedNameLength, let fix else { return nil }

        let alreadyListed = visible.contains {
            $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        guard !alreadyListed else { return nil }

        return VenueCandidate(
            // Stable for the row's identity, and never collides with a MapKit
            // identifier or a UUID.
            id: "typed:\(trimmed.lowercased())",
            name: trimmed,
            // The picker only ever opens in a drinking context, so a name typed
            // into it is a bar until the user says otherwise in Settings.
            category: .bar,
            latitude: fix.latitude,
            longitude: fix.longitude,
            distanceMeters: 0,
            mapItemID: nil,
            categoryLabel: VenueCategory.bar.displayName
        )
    }

    // MARK: Suggestion

    /// Which row wears the *Suggested* marker: the candidate inference chose.
    ///
    /// Matched by SPEC §1's dedupe rule as well as by id, because the suggestion
    /// may have arrived as a raw POI while the row that represents it has since
    /// been merged with a saved venue.
    public static func isSuggested(_ candidate: VenueCandidate, in request: CheckInPickerRequest) -> Bool {
        guard let suggestion = request.suggestion else { return false }
        if candidate.id == suggestion.id { return true }
        if let venueID = candidate.existingVenueID, venueID == suggestion.existingVenueID { return true }
        return candidate.matches(suggestion, proximityMeters: VenueWriter.dedupeProximityMeters)
    }
}

// MARK: - Formatting

/// Distances, in the units the reader actually uses.
///
/// `CLLocationDistance.tallyShortDistanceDescription` is metric-only by design —
/// it backs the check-in chip, which the mockups draw in meters. The picker is a
/// list of numbers a user compares against each other while standing on a
/// pavement, so it follows the locale instead (SPEC §9's "respect the system").
nonisolated public enum CheckInPickerFormatting {

    /// "40 m" · "1.2 km" · "130 ft" · "0.3 mi" · "220 yd".
    ///
    /// The unit switches at 1000 of the small unit, matching the threshold the
    /// rest of the app already reads in meters.
    public static func distance(
        _ meters: CLLocationDistance,
        locale: Locale = .autoupdatingCurrent
    ) -> String {

        let meters = max(0, meters)
        let system = locale.measurementSystem

        if system == .us {
            let feet = meters * 3.280_839_895
            return feet < 1000 ? whole(feet, "ft", locale) : fractional(meters / 1609.344, "mi", locale)
        }
        if system == .uk {
            let yards = meters * 1.093_613_298
            return yards < 1000 ? whole(yards, "yd", locale) : fractional(meters / 1609.344, "mi", locale)
        }
        return meters < 1000 ? whole(meters, "m", locale) : fractional(meters / 1000, "km", locale)
    }

    /// The row's second line: "Bar · 40 m", or just the category when the
    /// picker has no fix to measure from yet.
    public static func detail(
        for candidate: VenueCandidate,
        hasFix: Bool,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard hasFix else { return candidate.categoryLabel }
        return "\(candidate.categoryLabel) · \(distance(candidate.distanceMeters, locale: locale))"
    }

    private static func whole(_ value: Double, _ unit: String, _ locale: Locale) -> String {
        let rounded = Int(value.rounded())
        return "\(rounded.formatted(.number.grouping(.never).locale(locale))) \(unit)"
    }

    private static func fractional(_ value: Double, _ unit: String, _ locale: Locale) -> String {
        let text = value.formatted(
            .number.precision(.fractionLength(1)).grouping(.never).locale(locale)
        )
        return "\(text) \(unit)"
    }
}
