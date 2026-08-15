import CoreLocation
import Foundation
import SwiftData
import TallyKit

/// Every write this feature makes to `Venue`, in one place.
///
/// Venue dedupe is an app-level concern (SPEC §1) — there is no unique
/// constraint to lean on, so *all* venue creation funnels through
/// `resolveVenue(for:in:)` and matches by `mapItemID`, or by name + proximity
/// for user-defined ones.
public enum VenueWriter {

    /// SPEC §1: name + proximity is how user-defined venues dedupe.
    public static let dedupeProximityMeters: CLLocationDistance = 60

    // MARK: - Lookup

    public static func existingVenue(matching candidate: VenueCandidate, in context: ModelContext) throws -> Venue? {

        // 1. The venue the candidate already came from.
        if let id = candidate.existingVenueID, let venue = try EventStore.venue(id: id, in: context) {
            return venue
        }

        let all = try context.fetch(FetchDescriptor<Venue>())

        // 2. MapKit identity — the strongest signal, and the one CloudKit merges use.
        if let mapItemID = candidate.mapItemID,
           let match = all.first(where: { $0.mapItemID == mapItemID }) {
            return match
        }

        // 3. Name + proximity.
        return all.first { candidate.matches($0.snapshot, proximityMeters: dedupeProximityMeters) }
    }

    /// Reuses a saved venue when one matches, otherwise creates it.
    @discardableResult
    public static func resolveVenue(for candidate: VenueCandidate, in context: ModelContext) throws -> Venue {

        if let existing = try existingVenue(matching: candidate, in: context) {
            // A POI confirmed by hand earns its MapKit identity, so the next
            // device to see it dedupes on the strong key rather than the fuzzy one.
            if existing.mapItemID == nil, let mapItemID = candidate.mapItemID {
                existing.mapItemID = mapItemID
            }
            try context.save()
            return existing
        }

        let venue = Venue(
            name: candidate.name,
            category: candidate.category,
            latitude: candidate.latitude,
            longitude: candidate.longitude,
            source: candidate.mapItemID == nil ? .userDefined : .mapKitPOI,
            mapItemID: candidate.mapItemID
        )
        context.insert(venue)
        try context.save()
        return venue
    }

    // MARK: - Tagging

    /// Tags a set of events with a venue. Used by check-in confirmation (the
    /// whole Session), by History's venue assignment, and by reconciliation.
    public static func tag(eventIDs: [UUID], with venue: Venue?, in context: ModelContext) throws {
        guard !eventIDs.isEmpty else { return }
        for id in eventIDs {
            guard let event = try EventStore.event(id: id, in: context) else { continue }
            event.venue = venue
        }
        try context.save()
    }

    /// Writes a fix onto an already-logged event. The tap never waited for this
    /// (SPEC §1, §6) — the coordinates land a moment later.
    public static func attach(fix: LocationFix, toEventWith id: UUID, in context: ModelContext) throws {
        guard let event = try EventStore.event(id: id, in: context) else { return }
        event.latitude = fix.latitude
        event.longitude = fix.longitude
        event.horizontalAccuracy = fix.horizontalAccuracy
        try context.save()
    }

    // MARK: - Home

    /// SPEC §2: "Home is a user-defined venue set during onboarding, not
    /// inferred — inferring where someone sleeps is a privacy footgun."
    ///
    /// Idempotent: editing Home later updates the same record rather than
    /// leaving a second one behind for the merge pass to clean up.
    @discardableResult
    public static func saveHome(
        coordinate: CLLocationCoordinate2D,
        radiusMeters: Double = VenueCategory.home.defaultRadiusMeters,
        name: String = "Home",
        in context: ModelContext
    ) throws -> Venue {

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "Home" : trimmedName

        if let existing = try home(in: context) {
            existing.name = resolvedName
            existing.latitude = coordinate.latitude
            existing.longitude = coordinate.longitude
            existing.radiusMeters = radiusMeters
            existing.category = .home
            existing.source = .userDefined
            try context.save()
            return existing
        }

        let venue = Venue(
            name: resolvedName,
            category: .home,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            radiusMeters: radiusMeters,
            source: .userDefined
        )
        context.insert(venue)
        try context.save()
        return venue
    }

    public static func home(in context: ModelContext) throws -> Venue? {
        let raw = VenueCategory.home.rawValue
        var descriptor = FetchDescriptor<Venue>(predicate: #Predicate<Venue> { $0.categoryRaw == raw })
        descriptor.sortBy = [SortDescriptor(\Venue.createdAt, order: .forward)]
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
