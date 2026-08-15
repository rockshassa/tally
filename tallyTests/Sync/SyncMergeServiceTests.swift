import Foundation
import SwiftData
import Testing
import TallyKit
@testable import tally

/// Gate 2's SPEC §8 line — *"the same venue created on both merges to one, with
/// events and materialized Sessions repointed"* — as pure logic against an
/// in-memory store, with no CloudKit and no second device.
///
/// **Target setup (integrator):** written but not yet wired, exactly like
/// `tallyUITests/`. `tallyTests` needs a unit-test bundle target in
/// `tally.xcodeproj` with `TEST_HOST` set to the app; Wave 2 agents are not
/// allowed to touch `project.pbxproj`. Nothing in these files changes when it
/// lands.
@Suite("Sync merge — venues")
@MainActor
struct SyncMergeVenueTests {

    // MARK: Fixtures

    /// A bar somewhere. Coordinates are near enough to compute real distances:
    /// at this latitude 0.0001° of longitude is about 8 m.
    private static let anchorLatitude = 51.5074
    private static let anchorLongitude = -0.1278

    private func makeContext() throws -> ModelContext {
        ModelContext(try TallyStore.makeInMemoryContainer())
    }

    /// Offsets a longitude by roughly `meters`, which is all the proximity rule
    /// needs — the 50 m threshold is never tested within a metre of itself.
    private func longitude(offsetByMeters meters: Double) -> Double {
        let metersPerDegree = 111_320.0 * cos(Self.anchorLatitude * .pi / 180)
        return Self.anchorLongitude + meters / metersPerDegree
    }

    @discardableResult
    private func insertVenue(
        _ context: ModelContext,
        name: String = "The Anchor",
        category: VenueCategory = .bar,
        latitude: Double? = nil,
        longitude: Double? = nil,
        radiusMeters: Double? = nil,
        source: VenueSource = .mapKitPOI,
        mapItemID: String? = nil,
        muted: Bool = false,
        createdAt: Date
    ) -> Venue {
        let venue = Venue(
            name: name,
            category: category,
            latitude: latitude ?? Self.anchorLatitude,
            longitude: longitude ?? Self.anchorLongitude,
            radiusMeters: radiusMeters,
            source: source,
            mapItemID: mapItemID,
            muted: muted,
            createdAt: createdAt
        )
        context.insert(venue)
        return venue
    }

    private func venues(in context: ModelContext) throws -> [Venue] {
        try context.fetch(FetchDescriptor<Venue>())
    }

    private let earlier = Date(timeIntervalSince1970: 1_000_000)
    private let later = Date(timeIntervalSince1970: 2_000_000)

    // MARK: Matching — the strong key

    @Test("Two devices creating the same POI collapse into one")
    func mapItemIDMatchCollapses() throws {
        let context = try makeContext()
        let survivor = insertVenue(context, mapItemID: "poi-anchor", createdAt: earlier)
        let duplicate = insertVenue(context, mapItemID: "poi-anchor", createdAt: later)
        let survivorID = survivor.id
        let duplicateID = duplicate.id
        try context.save()

        let report = try SyncMergeService.mergeVenues(in: context)

        #expect(report.duplicateVenuesRemoved == 1)
        let remaining = try venues(in: context)
        #expect(remaining.count == 1)
        // The record that existed first is the one that survives.
        #expect(remaining.first?.id == survivorID)
        #expect(remaining.first?.id != duplicateID)
    }

    @Test("Different MapKit ids are different venues, however close")
    func differentMapItemIDsNeverMerge() throws {
        let context = try makeContext()
        // The bar and the restaurant above it: same doorway, two POIs.
        insertVenue(context, name: "The Anchor", mapItemID: "poi-anchor", createdAt: earlier)
        insertVenue(context, name: "The Anchor", mapItemID: "poi-anchor-restaurant", createdAt: later)
        try context.save()

        let report = try SyncMergeService.mergeVenues(in: context)

        #expect(report.isEmpty)
        #expect(try venues(in: context).count == 2)
    }

    // MARK: Matching — name + proximity

    @Test("Same name within 50 m merges")
    func nameAndProximityMerges() throws {
        let context = try makeContext()
        insertVenue(context, source: .userDefined, createdAt: earlier)
        insertVenue(
            context,
            longitude: longitude(offsetByMeters: 20),
            source: .userDefined,
            createdAt: later
        )
        try context.save()

        #expect(try SyncMergeService.mergeVenues(in: context).duplicateVenuesRemoved == 1)
        #expect(try venues(in: context).count == 1)
    }

    @Test("Same name beyond 50 m is a different branch of the same chain")
    func nameBeyondProximityDoesNotMerge() throws {
        let context = try makeContext()
        insertVenue(context, source: .userDefined, createdAt: earlier)
        insertVenue(
            context,
            longitude: longitude(offsetByMeters: 400),
            source: .userDefined,
            createdAt: later
        )
        try context.save()

        #expect(try SyncMergeService.mergeVenues(in: context).isEmpty)
        #expect(try venues(in: context).count == 2)
    }

    @Test("Name matching ignores case, accents, and stray whitespace")
    func nameMatchingIsNormalized() throws {
        let context = try makeContext()
        insertVenue(context, name: "Café Oto", source: .userDefined, createdAt: earlier)
        insertVenue(context, name: "  cafe oto ", source: .userDefined, createdAt: later)
        try context.save()

        #expect(try SyncMergeService.mergeVenues(in: context).duplicateVenuesRemoved == 1)
        #expect(try venues(in: context).count == 1)
    }

    @Test("Different names at the same coordinates stay separate")
    func differentNamesDoNotMerge() throws {
        let context = try makeContext()
        insertVenue(context, name: "The Anchor", source: .userDefined, createdAt: earlier)
        insertVenue(context, name: "The Crown", source: .userDefined, createdAt: later)
        try context.save()

        #expect(try SyncMergeService.mergeVenues(in: context).isEmpty)
        #expect(try venues(in: context).count == 2)
    }

    @Test("Blank names never merge on proximity alone")
    func blankNamesDoNotMerge() throws {
        let context = try makeContext()
        insertVenue(context, name: "", source: .userDefined, createdAt: earlier)
        insertVenue(context, name: "   ", source: .userDefined, createdAt: later)
        try context.save()

        #expect(try SyncMergeService.mergeVenues(in: context).isEmpty)
        #expect(try venues(in: context).count == 2)
    }

    // MARK: Repointing (SPEC §1)

    @Test("Events and materialized Sessions repoint to the survivor")
    func eventsAndSessionsRepoint() throws {
        let context = try makeContext()
        let survivor = insertVenue(context, mapItemID: "poi-anchor", createdAt: earlier)
        let duplicate = insertVenue(context, mapItemID: "poi-anchor", createdAt: later)
        let survivorID = survivor.id

        let keptEvent = DrinkEvent(timestamp: earlier, venue: survivor)
        let strandedEvent = DrinkEvent(timestamp: later, venue: duplicate)
        context.insert(keptEvent)
        context.insert(strandedEvent)

        let strandedSession = Session(startedAt: later, endedAt: later, note: "Dave's birthday", venue: duplicate)
        context.insert(strandedSession)
        try context.save()

        let report = try SyncMergeService.mergeVenues(in: context)

        #expect(report.eventsRepointed == 1)
        #expect(report.sessionsRepointed == 1)

        // Nothing was untagged by the delete — the nullify rule would have done
        // exactly that had the merge deleted before repointing.
        let events = try context.fetch(FetchDescriptor<DrinkEvent>())
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.venue?.id == survivorID })

        let sessions = try context.fetch(FetchDescriptor<Session>())
        #expect(sessions.first?.venue?.id == survivorID)
        #expect(sessions.first?.note == "Dave's birthday")
    }

    // MARK: Field merges

    @Test("The survivor inherits the strong key, the mute, and the wider fence")
    func survivorInheritsInformation() throws {
        let context = try makeContext()
        // Created by hand on the phone before the POI was ever matched.
        insertVenue(
            context,
            source: .userDefined,
            mapItemID: nil,
            muted: false,
            createdAt: earlier
        )
        // The watch's copy, matched to a POI and muted there.
        insertVenue(
            context,
            longitude: longitude(offsetByMeters: 15),
            radiusMeters: 120,
            mapItemID: nil,
            muted: true,
            createdAt: later
        )
        try context.save()

        #expect(try SyncMergeService.mergeVenues(in: context).duplicateVenuesRemoved == 1)

        let survivor = try #require(try venues(in: context).first)
        #expect(survivor.muted)
        #expect(survivor.radiusMeters == 120)
        #expect(survivor.createdAt == earlier)
    }

    @Test("A merged venue adopts the MapKit id the other device found")
    func survivorAdoptsMapItemID() throws {
        let context = try makeContext()
        insertVenue(context, source: .userDefined, mapItemID: nil, createdAt: earlier)
        insertVenue(
            context,
            longitude: longitude(offsetByMeters: 10),
            mapItemID: "poi-anchor",
            createdAt: later
        )
        try context.save()

        try SyncMergeService.mergeVenues(in: context)

        #expect(try venues(in: context).first?.mapItemID == "poi-anchor")
    }

    @Test("Home survives a merge as Home")
    func homeCategoryWins() throws {
        let context = try makeContext()
        insertVenue(context, name: "Home", category: .other, source: .userDefined, createdAt: earlier)
        insertVenue(
            context,
            name: "Home",
            category: .home,
            longitude: longitude(offsetByMeters: 12),
            source: .userDefined,
            createdAt: later
        )
        try context.save()

        try SyncMergeService.mergeVenues(in: context)

        #expect(try venues(in: context).first?.category == .home)
    }

    @Test("A survivor that inherits a MapKit id then matches on the strong key")
    func inheritedKeyMatchesLaterDuplicates() throws {
        let context = try makeContext()
        // Hand-created, no key.
        insertVenue(context, source: .userDefined, mapItemID: nil, createdAt: earlier)
        // Nearby, same name, carries the key — merges on name + proximity.
        insertVenue(
            context,
            longitude: longitude(offsetByMeters: 15),
            mapItemID: "poi-anchor",
            createdAt: later
        )
        // Renamed on a third device and 200 m of GPS drift away, so only the
        // inherited strong key can catch it.
        insertVenue(
            context,
            name: "The Anchor Tavern",
            longitude: longitude(offsetByMeters: 200),
            mapItemID: "poi-anchor",
            createdAt: later.addingTimeInterval(60)
        )
        try context.save()

        #expect(try SyncMergeService.mergeVenues(in: context).duplicateVenuesRemoved == 2)
        #expect(try venues(in: context).count == 1)
    }

    // MARK: Invariants

    @Test("A clean store reports nothing and changes nothing")
    func cleanStoreIsUntouched() throws {
        let context = try makeContext()
        insertVenue(context, name: "The Anchor", mapItemID: "poi-anchor", createdAt: earlier)
        insertVenue(context, name: "The Crown", mapItemID: "poi-crown", createdAt: later)
        try context.save()

        #expect(try SyncMergeService.run(in: context).isEmpty)
        #expect(try venues(in: context).count == 2)
    }

    @Test("Running the pass twice is a no-op the second time")
    func mergeIsIdempotent() throws {
        let context = try makeContext()
        insertVenue(context, mapItemID: "poi-anchor", createdAt: earlier)
        insertVenue(context, mapItemID: "poi-anchor", createdAt: later)
        try context.save()

        #expect(try SyncMergeService.mergeVenues(in: context).duplicateVenuesRemoved == 1)
        #expect(try SyncMergeService.mergeVenues(in: context).isEmpty)
        #expect(try venues(in: context).count == 1)
    }

    @Test("Insert order cannot change which record survives")
    func survivorIsOrderIndependent() throws {
        let timestamps = [later, earlier, later.addingTimeInterval(60)]

        var survivingIDs: [UUID] = []
        for ordering in [[0, 1, 2], [2, 1, 0], [1, 2, 0]] {
            let context = try makeContext()
            var created: [Date: UUID] = [:]
            for index in ordering {
                let venue = insertVenue(context, mapItemID: "poi-anchor", createdAt: timestamps[index])
                created[timestamps[index]] = venue.id
            }
            try context.save()

            try SyncMergeService.mergeVenues(in: context)
            let remaining = try venues(in: context)
            #expect(remaining.count == 1)
            #expect(remaining.first?.createdAt == earlier)
            if let id = remaining.first?.id { survivingIDs.append(id) }
            #expect(created[earlier] == remaining.first?.id)
        }
        #expect(survivingIDs.count == 3)
    }
}

// MARK: - Materialized Sessions

/// SPEC §8: CloudKit can briefly hold two records carrying the same app-level
/// `Session.id`, because record identity is per-device and the UUID is ours.
@Suite("Sync merge — materialized Sessions")
@MainActor
struct SyncMergeSessionTests {

    private func makeContext() throws -> ModelContext {
        ModelContext(try TallyStore.makeInMemoryContainer())
    }

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Two records with one id collapse, keeping the earlier one")
    func duplicateSessionsCollapse() throws {
        let context = try makeContext()
        let id = UUID()

        let earlier = Session(id: id, startedAt: start, endedAt: start.addingTimeInterval(3_600))
        let later = Session(
            id: id,
            startedAt: start,
            endedAt: start.addingTimeInterval(7_200),
            note: "Dave's birthday",
            pinned: true
        )
        context.insert(earlier)
        context.insert(later)
        try context.save()

        let report = try SyncMergeService.mergeSessions(in: context)

        #expect(report.duplicateSessionsRemoved == 1)
        let sessions = try context.fetch(FetchDescriptor<Session>())
        #expect(sessions.count == 1)

        let survivor = try #require(sessions.first)
        #expect(survivor.id == id)
        // Annotations favour information over absence…
        #expect(survivor.note == "Dave's birthday")
        #expect(survivor.pinned)
        // …and the window is the union, so no event falls out of the
        // materialized record back into free derivation.
        #expect(survivor.startedAt == start)
        #expect(survivor.endedAt == start.addingTimeInterval(7_200))
    }

    @Test("A note already on the survivor is not overwritten")
    func survivorNoteWins() throws {
        let context = try makeContext()
        let id = UUID()

        context.insert(
            Session(id: id, startedAt: start, endedAt: start.addingTimeInterval(3_600), note: "First")
        )
        context.insert(
            Session(id: id, startedAt: start, endedAt: start.addingTimeInterval(3_600), note: "Second")
        )
        try context.save()

        try SyncMergeService.mergeSessions(in: context)

        let sessions = try context.fetch(FetchDescriptor<Session>())
        #expect(sessions.count == 1)
        #expect(sessions.first?.note == "First")
    }

    @Test("A blank note counts as no note")
    func blankNoteIsAbsent() throws {
        let context = try makeContext()
        let id = UUID()

        context.insert(
            Session(id: id, startedAt: start, endedAt: start.addingTimeInterval(3_600), note: "   ")
        )
        context.insert(
            Session(id: id, startedAt: start, endedAt: start.addingTimeInterval(3_600), note: "Dave's birthday")
        )
        try context.save()

        try SyncMergeService.mergeSessions(in: context)

        #expect(try context.fetch(FetchDescriptor<Session>()).first?.note == "Dave's birthday")
    }

    @Test("A venue on either record ends up on the survivor")
    func venueIsPreserved() throws {
        let context = try makeContext()
        let id = UUID()

        let venue = Venue(name: "The Anchor", category: .bar, mapItemID: "poi-anchor")
        context.insert(venue)
        context.insert(Session(id: id, startedAt: start, endedAt: start.addingTimeInterval(3_600)))
        context.insert(
            Session(id: id, startedAt: start, endedAt: start.addingTimeInterval(3_600), venue: venue)
        )
        try context.save()

        try SyncMergeService.mergeSessions(in: context)

        let sessions = try context.fetch(FetchDescriptor<Session>())
        #expect(sessions.count == 1)
        #expect(sessions.first?.venue?.id == venue.id)
    }

    @Test("Distinct Sessions are never touched")
    func distinctSessionsSurvive() throws {
        let context = try makeContext()
        context.insert(Session(id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(3_600)))
        context.insert(
            Session(
                id: UUID(),
                startedAt: start.addingTimeInterval(86_400),
                endedAt: start.addingTimeInterval(90_000)
            )
        )
        try context.save()

        #expect(try SyncMergeService.mergeSessions(in: context).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Session>()).count == 2)
    }

    @Test("Running the pass twice is a no-op the second time")
    func mergeIsIdempotent() throws {
        let context = try makeContext()
        let id = UUID()
        context.insert(Session(id: id, startedAt: start, endedAt: start.addingTimeInterval(3_600)))
        context.insert(Session(id: id, startedAt: start, endedAt: start.addingTimeInterval(3_600)))
        try context.save()

        #expect(try SyncMergeService.mergeSessions(in: context).duplicateSessionsRemoved == 1)
        #expect(try SyncMergeService.mergeSessions(in: context).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Session>()).count == 1)
    }
}

// MARK: - The sync switch

/// SPEC §8: "Settings toggle, on by default when an iCloud account is present;
/// the app remains fully functional signed-out."
@Suite("Sync settings")
@MainActor
struct SyncSettingsTests {

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "tally.sync.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName) ?? .standard, suiteName)
    }

    @Test("Flipping the toggle writes the key the store reads")
    func togglePersistsToTheStoreKey() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SyncSettings(defaults: defaults)
        settings.isOn = false
        #expect(defaults.bool(forKey: TallyStore.syncPreferenceKey) == false)
        #expect(
            TallyStore.resolvedCloudKitMode(
                defaults: defaults, accountIsAvailable: true, processMirrors: true
            ) == .disabled
        )

        settings.isOn = true
        #expect(defaults.bool(forKey: TallyStore.syncPreferenceKey))
        #expect(
            TallyStore.resolvedCloudKitMode(
                defaults: defaults, accountIsAvailable: true, processMirrors: true
            ).isEnabled
        )
    }

    @Test("An untouched toggle reports the SPEC §8 default rather than a stored value")
    func defaultFollowsTheAccount() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SyncSettings(defaults: defaults)
        #expect(settings.isOn == TallyStore.hasICloudAccount)
        // Reading the setting must not itself persist a choice — otherwise a
        // device that later signs in would stay off forever.
        #expect(defaults.object(forKey: TallyStore.syncPreferenceKey) == nil)
    }

    @Test("The status line names the state it is in")
    func statusLineCopy() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SyncSettings(defaults: defaults)
        if !settings.hasAccount {
            #expect(settings.statusLine == "No iCloud account")
            #expect(settings.isToggleEnabled == false)
        }
    }

    @Test("Erase-all clears the sync bookkeeping")
    func clearingSyncHistory() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SyncSettings(defaults: defaults)
        settings.recordRemoteChange(at: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(settings.lastRemoteChange != nil)

        settings.clearSyncHistory()
        #expect(settings.lastRemoteChange == nil)
    }
}
