import CoreLocation
import Foundation
import TallyKit
import Testing
@testable import tally

/// SPEC §2's venue search, as pure logic.
///
/// > Results are anchored to the fix (or to where the drinks were logged, from
/// > History), tried bar-first (nightlife/brewery/distillery/winery, then
/// > restaurant/cafe), and **widened** — any place, then a wider region — only
/// > when the narrower pass finds nothing, so "bowling alley" still works.
/// > Ranking: name match quality (exact, then prefix, then contains), then bar
/// > categories, then distance. Results dedupe against the nearby list and
/// > saved venues by §1's rule, the saved venue winning name and identity.
///
/// No MapKit here, and none needed: `VenueSearchPlan` decides *what* to ask and
/// `VenueSearchRanking` decides what to do with the answer, so the only thing
/// left in `POISearchService` is the call itself.

// MARK: - Fixtures

private enum Fixture {

    static let latitude = 51.5074
    static let longitude = -0.1278

    /// Roughly `meters` east of the anchor.
    static func longitude(offsetByMeters meters: Double) -> Double {
        let metersPerDegree = 111_320.0 * cos(latitude * .pi / 180)
        return longitude + meters / metersPerDegree
    }

    static let fix = LocationFix(latitude: latitude, longitude: longitude, horizontalAccuracy: 10)

    static func poi(
        _ name: String,
        distance: CLLocationDistance,
        category: VenueCategory = .bar,
        mapItemID: String? = nil
    ) -> VenueCandidate {
        VenueCandidate(
            id: mapItemID ?? "poi.\(name.lowercased())",
            name: name,
            category: category,
            latitude: latitude,
            longitude: longitude(offsetByMeters: distance),
            distanceMeters: distance,
            mapItemID: mapItemID ?? "poi.\(name.lowercased())"
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
}

// MARK: - Planning

@Suite("Venue search — pass planning")
struct VenueSearchPlanTests {

    @Test("With an anchor: bars nearby, then anywhere nearby, then anywhere wider")
    func anchoredPlan() {
        let request = VenueSearchRequest(query: "bowl", anchor: Fixture.fix)
        let passes = VenueSearchPlan.passes(for: request)

        #expect(passes.count == 3)
        #expect(passes.map(\.scope) == [.bars, .anyPlace, .anyPlace])
        #expect(passes[0].radiusMeters == VenueSearchRequest.defaultRadiusMeters)
        #expect(passes[1].radiusMeters == VenueSearchRequest.defaultRadiusMeters)
        #expect(passes[2].radiusMeters == VenueSearchRequest.widenedRadiusMeters)
        // Every pass asks the same question of the same place.
        #expect(passes.allSatisfy { $0.query == "bowl" && $0.anchor == Fixture.fix })
    }

    @Test("Without an anchor there is no region to widen — only the filter narrows")
    func unanchoredPlan() {
        let passes = VenueSearchPlan.passes(for: VenueSearchRequest(query: "bowl"))

        #expect(passes.map(\.scope) == [.bars, .anyPlace])
        #expect(passes.allSatisfy { $0.anchor == nil })
    }

    @Test("A request that already asked for any place keeps its answer")
    func anyPlaceSkipsTheBarPass() {
        let request = VenueSearchRequest(query: "bowl", anchor: Fixture.fix, scope: .anyPlace)
        #expect(VenueSearchPlan.passes(for: request).map(\.scope) == [.anyPlace, .anyPlace])
    }

    @Test("Already as wide as the widening: no pointless third pass")
    func doesNotWidenPastItself() {
        let request = VenueSearchRequest(
            query: "bowl",
            anchor: Fixture.fix,
            radiusMeters: VenueSearchRequest.widenedRadiusMeters
        )
        #expect(VenueSearchPlan.passes(for: request).count == 2)
    }

    @Test("The query is trimmed once, where it is typed")
    func trims() {
        #expect(VenueSearchRequest(query: "  The Anchor \n").trimmedQuery == "The Anchor")
    }
}

// MARK: - Match tiers

@Suite("Venue search — match quality")
struct VenueSearchMatchTierTests {

    @Test("Exact, then prefix, then contains, then whatever MapKit thought")
    func tiers() {
        #expect(VenueSearchRanking.MatchTier.of("The Anchor", for: "the anchor") == .exact)
        #expect(VenueSearchRanking.MatchTier.of("The Anchor", for: "The") == .prefix)
        #expect(VenueSearchRanking.MatchTier.of("The Anchor", for: "anch") == .prefix)
        #expect(VenueSearchRanking.MatchTier.of("Ship and Anchor", for: "and anchor") == .contains)
        #expect(VenueSearchRanking.MatchTier.of("Golden Tap", for: "anchor") == .other)
    }

    @Test("Case and accents are not the question being asked")
    func foldsDiacritics() {
        #expect(VenueSearchRanking.MatchTier.of("Café Rouge", for: "cafe rouge") == .exact)
        #expect(VenueSearchRanking.MatchTier.of("Café Rouge", for: "CAFE") == .prefix)
    }

    @Test("The tiers order the way they read")
    func ordering() {
        #expect(VenueSearchRanking.MatchTier.exact < .prefix)
        #expect(VenueSearchRanking.MatchTier.prefix < .contains)
        #expect(VenueSearchRanking.MatchTier.contains < .other)
    }
}

// MARK: - Ranking

@Suite("Venue search — ranking")
struct VenueSearchRankingTests {

    @Test("Name match quality leads, whatever the distance says")
    func matchQualityBeatsDistance() {
        let ranked = VenueSearchRanking.rank(
            [
                Fixture.poi("Anchor Yard", distance: 40),
                Fixture.poi("The Anchor", distance: 4_000)
            ],
            query: "The Anchor",
            anchor: nil
        )

        #expect(ranked.map(\.name) == ["The Anchor", "Anchor Yard"])
    }

    @Test("At equal match quality, a bar comes before a restaurant")
    func barBeatsRestaurant() {
        let ranked = VenueSearchRanking.rank(
            [
                Fixture.poi("Bowl Kitchen", distance: 40, category: .restaurant),
                Fixture.poi("Bowl Bar", distance: 40, category: .bar)
            ],
            query: "Bowl",
            anchor: nil
        )

        #expect(ranked.map(\.name) == ["Bowl Bar", "Bowl Kitchen"])
    }

    @Test("A bowling alley still ranks — behind the bars, not out of the list")
    func otherCategoriesSurvive() {
        let ranked = VenueSearchRanking.rank(
            [
                Fixture.poi("Bowl Lanes", distance: 40, category: .other),
                Fixture.poi("Bowl Kitchen", distance: 900, category: .restaurant),
                Fixture.poi("Bowl Bar", distance: 4_000, category: .bar)
            ],
            query: "Bowl",
            anchor: nil
        )

        #expect(ranked.map(\.name) == ["Bowl Bar", "Bowl Kitchen", "Bowl Lanes"])
    }

    @Test("Everything else equal, nearer wins")
    func nearerFirst() {
        let ranked = VenueSearchRanking.rank(
            [
                Fixture.poi("Anchor Two", distance: 900),
                Fixture.poi("Anchor One", distance: 120)
            ],
            query: "Anchor",
            anchor: nil
        )

        #expect(ranked.map(\.name) == ["Anchor One", "Anchor Two"])
    }

    @Test("Ranking re-measures against the anchor it was given")
    func remeasuresAgainstTheAnchor() {
        let candidate = VenueCandidate(
            id: "poi.anchor",
            name: "The Anchor",
            category: .bar,
            latitude: Fixture.latitude,
            longitude: Fixture.longitude(offsetByMeters: 300),
            // A distance measured from somewhere else entirely.
            distanceMeters: 9_999,
            mapItemID: "poi.anchor"
        )

        let ranked = VenueSearchRanking.rank([candidate], query: "anchor", anchor: Fixture.fix)

        #expect(ranked.count == 1)
        #expect(abs(ranked[0].distanceMeters - 300) < 5)
    }

    @Test("The order does not depend on the order MapKit answered in")
    func stableUnderInputOrder() {
        let alpha = Fixture.poi("Anchor Alpha", distance: 100, mapItemID: "poi.a")
        let bravo = Fixture.poi("Anchor Bravo", distance: 100, mapItemID: "poi.b")

        let forwards = VenueSearchRanking.rank([alpha, bravo], query: "anchor", anchor: nil)
        let backwards = VenueSearchRanking.rank([bravo, alpha], query: "anchor", anchor: nil)

        #expect(forwards.map(\.id) == backwards.map(\.id))
    }
}

// MARK: - Dedupe & merge

@Suite("Venue search — dedupe against what is already on screen")
struct VenueSearchMergeTests {

    @Test("A remote hit that is already a nearby row is dropped — nearby measured it")
    func dropsWhatIsAlreadyNearby() {
        let nearby = [Fixture.poi("The Anchor", distance: 40, mapItemID: "poi.anchor")]
        let remote = [
            Fixture.poi("The Anchor", distance: 4_000, mapItemID: "poi.anchor"),
            Fixture.poi("Golden Tap", distance: 900, mapItemID: "poi.golden")
        ]

        let merged = VenueSearchRanking.merged(remote: remote, nearby: nearby, saved: [])

        #expect(merged.map(\.name) == ["Golden Tap"])
    }

    @Test("The nearby dedupe is SPEC §1's rule, name + proximity included")
    func dropsByNameAndProximity() {
        let nearby = [Fixture.poi("The Anchor", distance: 40, mapItemID: "poi.anchor")]
        // Same name, 20 m away, no shared MapKit identity: still the same bar.
        let remote = [
            VenueCandidate(
                id: "other",
                name: "the anchor",
                category: .bar,
                latitude: Fixture.latitude,
                longitude: Fixture.longitude(offsetByMeters: 55),
                distanceMeters: 55
            )
        ]

        #expect(VenueSearchRanking.merged(remote: remote, nearby: nearby, saved: []).isEmpty)
    }

    @Test("A remote hit that is a saved venue keeps the saved name and identity")
    func savedWinsNameAndIdentity() {
        let savedID = UUID()
        let saved = Fixture.saved("Anchor (ours)", offsetMeters: 4_000, mapItemID: "poi.anchor", id: savedID)

        let merged = VenueSearchRanking.merged(
            remote: [Fixture.poi("The Anchor", distance: 4_000, mapItemID: "poi.anchor")],
            nearby: [],
            saved: [saved]
        )

        #expect(merged.count == 1)
        #expect(merged[0].name == "Anchor (ours)")
        #expect(merged[0].existingVenueID == savedID)
        // …and the remote side keeps the coordinates and distance it measured.
        #expect(merged[0].distanceMeters == 4_000)
    }

    @Test("One venue is one row, even when MapKit returns it twice")
    func collapsesRemoteDuplicates() {
        let merged = VenueSearchRanking.merged(
            remote: [
                Fixture.poi("The Anchor", distance: 900, mapItemID: "poi.anchor"),
                Fixture.poi("The Anchor", distance: 950, mapItemID: "poi.anchor")
            ],
            nearby: [],
            saved: []
        )

        #expect(merged.count == 1)
        #expect(merged[0].distanceMeters == 900)
    }

    @Test("Merging preserves the ranked order it was handed")
    func preservesOrder() {
        let merged = VenueSearchRanking.merged(
            remote: [
                Fixture.poi("Bowl Bar", distance: 4_000, mapItemID: "poi.bar"),
                Fixture.poi("Bowl Lanes", distance: 40, category: .other, mapItemID: "poi.lanes")
            ],
            nearby: [],
            saved: []
        )

        #expect(merged.map(\.name) == ["Bowl Bar", "Bowl Lanes"])
    }
}
