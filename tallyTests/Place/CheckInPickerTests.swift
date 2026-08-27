import CoreLocation
import Foundation
import TallyKit
import Testing
@testable import tally

/// SPEC §2's check-in picker, as pure logic.
///
/// > "Somewhere else nearby…", and any tap-through from a Bar Radar
/// > notification, open a ranked list: every nearby candidate **ordered by
/// > distance**, each row showing name, category, and distance, with the
/// > inferred venue marked. Includes saved venues in range, a live-updating
/// > distance as a fresh fix arrives, a search field for naming a place MapKit
/// > doesn't return.
///
/// Everything the picker decides before it draws anything lives in
/// `CheckInPickerRanking` / `CheckInPickerFormatting` precisely so this file can
/// exist: no MapKit, no `ModelContext`, no view, no fix but the one below.
///
/// **Target setup (integrator):** same standing note as `tallyTests/Radar/` —
/// these files are written, not run, until the unit-test bundle is wired.

// MARK: - Fixtures

private enum Fixture {

    static let latitude = 51.5074
    static let longitude = -0.1278

    /// Roughly `meters` east of the anchor — the only geometry these tests need.
    static func longitude(offsetByMeters meters: Double) -> Double {
        let metersPerDegree = 111_320.0 * cos(latitude * .pi / 180)
        return longitude + meters / metersPerDegree
    }

    static let fix = LocationFix(latitude: latitude, longitude: longitude, horizontalAccuracy: 10)

    static func poi(
        _ name: String,
        distance: CLLocationDistance,
        mapItemID: String? = nil,
        category: VenueCategory = .bar,
        categoryLabel: String? = nil
    ) -> VenueCandidate {
        VenueCandidate(
            id: mapItemID ?? "poi.\(name.lowercased())",
            name: name,
            category: category,
            latitude: latitude,
            longitude: longitude(offsetByMeters: distance),
            distanceMeters: distance,
            mapItemID: mapItemID ?? "poi.\(name.lowercased())",
            categoryLabel: categoryLabel
        )
    }

    static func saved(
        _ name: String,
        offsetMeters: Double,
        category: VenueCategory = .bar,
        mapItemID: String? = nil,
        id: UUID = UUID()
    ) -> VenueSnapshot {
        VenueSnapshot(
            id: id,
            name: name,
            category: category,
            latitude: latitude,
            longitude: longitude(offsetByMeters: offsetMeters),
            radiusMeters: 75,
            source: mapItemID == nil ? .userDefined : .mapKitPOI,
            mapItemID: mapItemID
        )
    }

    /// A locale that is definitely on the given system, whatever the test
    /// machine's region is set to. The number format stays `en_US`, so the
    /// expected strings below are the ones a reader would write down.
    static func locale(_ system: Locale.MeasurementSystem) -> Locale {
        var components = Locale.Components(identifier: "en_US")
        components.measurementSystem = system
        return Locale(components: components)
    }
}

private func names(_ sections: [CheckInPickerRanking.Section]) -> [String] {
    CheckInPickerRanking.rows(in: sections).map(\.name)
}

private func section(
    _ kind: CheckInPickerRanking.Section.Kind,
    in sections: [CheckInPickerRanking.Section]
) -> CheckInPickerRanking.Section? {
    sections.first { $0.kind == kind }
}

// MARK: - Order

@Suite("Check-in picker — ranking")
struct CheckInPickerRankingTests {

    @Test("Nearby candidates are ordered by distance, ascending")
    func ordersByDistance() {
        let sections = CheckInPickerRanking.sections(
            poi: [
                Fixture.poi("Golden Tap", distance: 95),
                Fixture.poi("The Anchor", distance: 40),
                Fixture.poi("Last Orders", distance: 180)
            ],
            savedVenues: [],
            fix: Fixture.fix
        )

        #expect(names(sections) == ["The Anchor", "Golden Tap", "Last Orders"])
    }

    @Test("A dead heat is broken deterministically, not by input order")
    func breaksTiesDeterministically() {
        let first = Fixture.poi("Bravo", distance: 50, mapItemID: "poi.b")
        let second = Fixture.poi("Alpha", distance: 50, mapItemID: "poi.a")

        let forwards = CheckInPickerRanking.sections(poi: [first, second], savedVenues: [], fix: Fixture.fix)
        let backwards = CheckInPickerRanking.sections(poi: [second, first], savedVenues: [], fix: Fixture.fix)

        #expect(names(forwards) == names(backwards))
        #expect(names(forwards) == ["Alpha", "Bravo"])
    }

    @Test("Saved venues follow the nearby section, still nearest-first")
    func savedFollowNearby() {
        let sections = CheckInPickerRanking.sections(
            poi: [Fixture.poi("The Anchor", distance: 40)],
            savedVenues: [
                Fixture.saved("The Old Bell", offsetMeters: 200),
                Fixture.saved("Dive Bar", offsetMeters: 120)
            ],
            fix: Fixture.fix
        )

        #expect(sections.map(\.kind) == [.nearby, .saved])
        #expect(names(sections) == ["The Anchor", "Dive Bar", "The Old Bell"])
    }

    @Test("Row indices count across both sections, top to bottom")
    func rowsFlattenAcrossSections() {
        let sections = CheckInPickerRanking.sections(
            poi: [Fixture.poi("The Anchor", distance: 40)],
            savedVenues: [Fixture.saved("Dive Bar", offsetMeters: 120)],
            fix: Fixture.fix
        )

        let rows = CheckInPickerRanking.rows(in: sections)
        #expect(rows.count == 2)
        #expect(rows[0].name == "The Anchor")
        #expect(rows[1].name == "Dive Bar")
    }

    @Test("Empty sections are dropped rather than drawn as a bare heading")
    func dropsEmptySections() {
        let sections = CheckInPickerRanking.sections(
            poi: [Fixture.poi("The Anchor", distance: 40)],
            savedVenues: [],
            fix: Fixture.fix
        )

        #expect(sections.count == 1)
        #expect(sections[0].kind == .nearby)
    }
}

// MARK: - Saved-venue merge

@Suite("Check-in picker — saved venue merge")
struct CheckInPickerMergeTests {

    @Test("A POI that is already a saved venue is one row, with the saved identity")
    func mapItemMatchCollapses() {
        let savedID = UUID()
        let saved = Fixture.saved("Anchor (ours)", offsetMeters: 40, mapItemID: "poi.anchor", id: savedID)

        let sections = CheckInPickerRanking.sections(
            poi: [Fixture.poi("The Anchor", distance: 40, mapItemID: "poi.anchor")],
            savedVenues: [saved],
            fix: Fixture.fix
        )

        let rows = CheckInPickerRanking.rows(in: sections)
        #expect(rows.count == 1)
        // The saved side wins the name and the identity; picking it must reuse
        // the record rather than create a second one (SPEC §1).
        #expect(rows[0].name == "Anchor (ours)")
        #expect(rows[0].existingVenueID == savedID)
        #expect(rows[0].isSaved)
        // …and the POI side keeps the distance, which is the fresher fact.
        #expect(rows[0].distanceMeters == 40)
    }

    @Test("A user-defined venue matches by name + proximity, like VenueWriter")
    func nameAndProximityMatchCollapses() {
        let savedID = UUID()
        let saved = Fixture.saved("The Anchor", offsetMeters: 45, id: savedID)

        let sections = CheckInPickerRanking.sections(
            poi: [Fixture.poi("the anchor", distance: 40, mapItemID: "poi.anchor")],
            savedVenues: [saved],
            fix: Fixture.fix
        )

        let rows = CheckInPickerRanking.rows(in: sections)
        #expect(rows.count == 1)
        #expect(rows[0].existingVenueID == savedID)
    }

    @Test("Same name, far apart, is two different bars")
    func nameMatchNeedsProximity() {
        // Beyond `VenueWriter.dedupeProximityMeters`, so the rule must not fire.
        let saved = Fixture.saved("The Anchor", offsetMeters: 200)

        let sections = CheckInPickerRanking.sections(
            poi: [Fixture.poi("The Anchor", distance: 20, mapItemID: "poi.anchor")],
            savedVenues: [saved],
            fix: Fixture.fix
        )

        #expect(CheckInPickerRanking.rows(in: sections).count == 2)
        #expect(section(.saved, in: sections)?.candidates.count == 1)
    }

    @Test("Saved venues out of range are left out")
    func rangeFiltersSaved() {
        let sections = CheckInPickerRanking.sections(
            poi: [],
            savedVenues: [
                Fixture.saved("Dive Bar", offsetMeters: 120),
                Fixture.saved("Across Town", offsetMeters: 4_000)
            ],
            fix: Fixture.fix
        )

        #expect(names(sections) == ["Dive Bar"])
    }

    @Test("With no fix, every saved venue stays — there is no range to fail")
    func noFixKeepsSaved() {
        let sections = CheckInPickerRanking.sections(
            poi: [],
            savedVenues: [Fixture.saved("Across Town", offsetMeters: 4_000)],
            fix: nil
        )

        #expect(names(sections) == ["Across Town"])
    }

    @Test("Home is never offered — SPEC §2 tags drinks there without asking")
    func excludesHome() {
        let sections = CheckInPickerRanking.sections(
            poi: [],
            savedVenues: [
                Fixture.saved("Home", offsetMeters: 10, category: .home),
                Fixture.saved("Dive Bar", offsetMeters: 60)
            ],
            fix: Fixture.fix
        )

        #expect(names(sections) == ["Dive Bar"])
    }

    @Test("The suggested row is marked even after it merges with a saved venue")
    func suggestionSurvivesMerge() {
        let suggestion = Fixture.poi("The Anchor", distance: 40, mapItemID: "poi.anchor")
        let request = CheckInPickerRequest.notification(suggesting: suggestion)

        let sections = CheckInPickerRanking.sections(
            poi: [suggestion, Fixture.poi("Golden Tap", distance: 95, mapItemID: "poi.golden")],
            savedVenues: [Fixture.saved("Anchor (ours)", offsetMeters: 40, mapItemID: "poi.anchor")],
            fix: Fixture.fix
        )

        let rows = CheckInPickerRanking.rows(in: sections)
        #expect(rows.filter { CheckInPickerRanking.isSuggested($0, in: request) }.map(\.name) == ["Anchor (ours)"])
    }

    @Test("Nothing is suggested when nothing was inferred")
    func noSuggestionMarksNothing() {
        let request = CheckInPickerRequest.notification()
        let candidate = Fixture.poi("The Anchor", distance: 40)
        #expect(!CheckInPickerRanking.isSuggested(candidate, in: request))
    }
}

// MARK: - A fresher fix

@Suite("Check-in picker — live distances")
struct CheckInPickerFreshnessTests {

    @Test("Candidates are re-measured against the newer fix")
    func remeasures() {
        let candidate = Fixture.poi("The Anchor", distance: 40)
        let closer = LocationFix(
            latitude: Fixture.latitude,
            longitude: Fixture.longitude(offsetByMeters: 30),
            horizontalAccuracy: 8
        )

        let updated = CheckInPickerRanking.remeasured([candidate], against: closer)

        #expect(updated.count == 1)
        #expect(updated[0].id == candidate.id)
        #expect(abs(updated[0].distanceMeters - 10) < 2)
    }

    @Test("Re-measuring against nothing leaves the candidates alone")
    func remeasureWithoutFixIsIdentity() {
        let candidates = [Fixture.poi("The Anchor", distance: 40)]
        #expect(CheckInPickerRanking.remeasured(candidates, against: nil) == candidates)
    }

    @Test("Fresh results win; seeds they don't cover are kept")
    func unionKeepsUncoveredSeeds() {
        let fresh = Fixture.poi("The Anchor", distance: 20, mapItemID: "poi.anchor")
        let staleSameBar = Fixture.poi("The Anchor", distance: 40, mapItemID: "poi.anchor")
        let onlySeed = Fixture.poi("Golden Tap", distance: 95, mapItemID: "poi.golden")

        let merged = CheckInPickerRanking.unioned([fresh], with: [staleSameBar, onlySeed])

        #expect(merged.map(\.name) == ["The Anchor", "Golden Tap"])
        #expect(merged[0].distanceMeters == 20)
    }
}

// MARK: - Search & "use what I typed"

@Suite("Check-in picker — search")
struct CheckInPickerSearchTests {

    private var poi: [VenueCandidate] {
        [
            Fixture.poi("The Anchor", distance: 40),
            Fixture.poi("Golden Tap", distance: 95)
        ]
    }

    @Test("The query filters both sections by name")
    func filters() {
        let sections = CheckInPickerRanking.sections(
            poi: poi,
            savedVenues: [Fixture.saved("Anchor Yard", offsetMeters: 150)],
            fix: Fixture.fix,
            query: "anchor"
        )

        #expect(names(sections) == ["The Anchor", "Anchor Yard"])
    }

    @Test("Whitespace is not a query")
    func blankQueryDoesNotFilter() {
        let sections = CheckInPickerRanking.sections(poi: poi, savedVenues: [], fix: Fixture.fix, query: "   ")
        #expect(names(sections).count == 2)
    }

    @Test("'Use what I typed' is offered when the typed name is not on screen")
    func offersTypedName() {
        let typed = CheckInPickerRanking.typedNameCandidate(
            for: "Ye Olde Pub",
            matching: poi,
            fix: Fixture.fix
        )

        #expect(typed?.name == "Ye Olde Pub")
        // SPEC §2: "creating a user-defined Venue at the current fix".
        #expect(typed?.mapItemID == nil)
        #expect(typed?.category == .bar)
        #expect(typed?.latitude == Fixture.fix.latitude)
        #expect(typed?.longitude == Fixture.fix.longitude)
    }

    @Test("It is offered alongside fuzzy matches — the right place can still be missing")
    func offersTypedNameEvenWithMatches() {
        let matches = CheckInPickerRanking.filtered(poi, by: "Anch")
        #expect(matches.count == 1)
        #expect(CheckInPickerRanking.typedNameCandidate(for: "Anch", matching: matches, fix: Fixture.fix) != nil)
    }

    @Test("An exact name already on screen suppresses it — that row is the answer")
    func exactMatchSuppressesTypedName() {
        #expect(
            CheckInPickerRanking.typedNameCandidate(for: "the anchor", matching: poi, fix: Fixture.fix) == nil
        )
        #expect(
            CheckInPickerRanking.typedNameCandidate(for: "  The Anchor ", matching: poi, fix: Fixture.fix) == nil
        )
    }

    @Test("Too short to be a venue name")
    func gatesOnLength() {
        #expect(CheckInPickerRanking.typedNameCandidate(for: "", matching: [], fix: Fixture.fix) == nil)
        #expect(CheckInPickerRanking.typedNameCandidate(for: "T", matching: [], fix: Fixture.fix) == nil)
        #expect(CheckInPickerRanking.typedNameCandidate(for: "Ye", matching: [], fix: Fixture.fix) != nil)
    }

    @Test("No fix, no offer — a venue pinned at 0°, 0° is worse than none")
    func gatesOnFix() {
        #expect(CheckInPickerRanking.typedNameCandidate(for: "Ye Olde Pub", matching: [], fix: nil) == nil)
    }
}

// MARK: - Distance formatting

@Suite("Check-in picker — distance formatting")
struct CheckInPickerFormattingTests {

    @Test("Metric: meters, then kilometers")
    func metric() {
        let locale = Fixture.locale(.metric)
        #expect(CheckInPickerFormatting.distance(40, locale: locale) == "40 m")
        #expect(CheckInPickerFormatting.distance(999, locale: locale) == "999 m")
        #expect(CheckInPickerFormatting.distance(1_200, locale: locale) == "1.2 km")
    }

    @Test("US: feet, then miles")
    func us() {
        let locale = Fixture.locale(.us)
        #expect(CheckInPickerFormatting.distance(40, locale: locale) == "131 ft")
        #expect(CheckInPickerFormatting.distance(1_609.344, locale: locale) == "1.0 mi")
    }

    @Test("UK: yards, then miles")
    func uk() {
        let locale = Fixture.locale(.uk)
        #expect(CheckInPickerFormatting.distance(40, locale: locale) == "44 yd")
        #expect(CheckInPickerFormatting.distance(3_218.688, locale: locale) == "2.0 mi")
    }

    @Test("A negative distance is a bug upstream, not a negative row")
    func clampsNegative() {
        #expect(CheckInPickerFormatting.distance(-5, locale: Fixture.locale(.metric)) == "0 m")
    }

    @Test("The row's second line is category, then distance")
    func detailLine() {
        let candidate = Fixture.poi("Golden Tap", distance: 95, categoryLabel: "Brewery")

        #expect(
            CheckInPickerFormatting.detail(for: candidate, hasFix: true, locale: Fixture.locale(.metric))
                == "Brewery · 95 m"
        )
        // Nothing to measure from yet: the category alone, never "0 m".
        #expect(
            CheckInPickerFormatting.detail(for: candidate, hasFix: false, locale: Fixture.locale(.metric))
                == "Brewery"
        )
    }
}

// MARK: - Request

@Suite("Check-in picker — request")
struct CheckInPickerRequestTests {

    private func prompt() -> CheckInPrompt {
        CheckInPrompt(
            sessionID: UUID(),
            eventID: UUID(),
            primary: Fixture.poi("The Anchor", distance: 40),
            alternates: [Fixture.poi("Golden Tap", distance: 95)],
            fix: Fixture.fix
        )
    }

    @Test("From a check-in prompt: keyed by the Session, seeded with its candidates")
    func fromPrompt() {
        let prompt = prompt()
        let request = CheckInPickerRequest(prompt: prompt)

        #expect(request.id == prompt.sessionID)
        #expect(request.sessionID == prompt.sessionID)
        #expect(request.prompt == prompt)
        #expect(!request.isFromNotification)
        #expect(request.fix == prompt.fix)
        #expect(request.suggestion == prompt.primary)
        #expect(request.seeds.map(\.name) == ["The Anchor", "Golden Tap"])
    }

    @Test("From a notification: no Session, no fix — the picker locates itself")
    func fromNotification() {
        let suggestion = Fixture.poi("The Anchor", distance: 40)
        let request = CheckInPickerRequest.notification(suggesting: suggestion)

        #expect(request.isFromNotification)
        #expect(request.prompt == nil)
        #expect(request.sessionID == nil)
        #expect(request.fix == nil)
        #expect(request.seeds == [suggestion])
    }

    @Test("A tap-through with nothing named still opens a picker")
    func fromBareNotification() {
        let request = CheckInPickerRequest.notification()
        #expect(request.suggestion == nil)
        #expect(request.seeds.isEmpty)
        #expect(request.fix == nil)
    }

    /// The signatures the Bar Radar workstream calls from its default-action
    /// handler (SPEC §2: "tapping the notification body opens the app on the
    /// check-in picker"). Pinned here so a rename breaks a test rather than the
    /// other side of the seam.
    ///
    /// Safe with or without a registered coordinator: without one the request
    /// is held until `PlaceCoordinator.registerShared` lands, which is what a
    /// cold launch from a notification looks like.
    @Test("The tap-through entry points are callable with no coordinator in hand")
    @MainActor
    func tapThroughEntryPoints() {
        let suggestion = Fixture.poi("The Anchor", distance: 40)

        _ = PlaceCoordinator.presentPickerForCurrentFix()
        _ = PlaceCoordinator.presentPickerForCurrentFix(suggesting: suggestion)
        _ = PlaceCoordinator.presentPickerForCurrentFix(suggestingVenueWith: UUID())

        // Whatever the host process had registered, the picker is a request —
        // never a fix taken on the spot, so nothing here can block on CoreLocation.
        if let shared = PlaceCoordinator.shared {
            #expect(shared.pendingPicker?.isFromNotification == true)
            #expect(shared.pendingPicker?.fix == nil)
            shared.dismissPicker()
        }
    }
}
