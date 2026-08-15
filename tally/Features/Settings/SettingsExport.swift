import Foundation
import SwiftData
import TallyKit

/// SPEC §9 Data: *"export everything as CSV/JSON via the share sheet."*
///
/// "Everything" is taken literally — the CSV is the event log, and the JSON is
/// the whole store: events, venues, materialized Sessions, and suppressed
/// places. Nothing derived is exported (SPEC §1: points, streaks, and Session
/// groupings are recomputed, never stored, so writing them into a file would be
/// inventing a second source of truth).
enum TallyExport {

    /// The two files, written and ready for `ShareLink`.
    struct Bundle: Identifiable, Hashable {
        let id = UUID()
        let csv: URL
        let json: URL
        let eventCount: Int
    }

    // MARK: - Payload

    /// The JSON document's shape. Snapshot types are already `Codable`, so the
    /// export format tracks the schema automatically.
    private struct Payload: Encodable {
        let exportedAt: Date
        let schemaVersion: Int
        let events: [DrinkEventSnapshot]
        let venues: [VenueSnapshot]
        let materializedSessions: [MaterializedSession]
        let suppressedPlaces: [SuppressedPlaceSnapshot]
    }

    /// Bumped when the exported shape changes, so a future importer can tell.
    static let schemaVersion = 1

    // MARK: - Building

    static func make(context: ModelContext, now: Date = Date()) throws -> Bundle {
        let events = try EventStore.snapshots(in: context)
        let venues = try EventStore.venues(in: context)
        let sessions = try EventStore.materializedSessions(in: context)
        let suppressed = try context.fetch(FetchDescriptor<SuppressedPlace>()).map(\.snapshot)

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TallyExport", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = now.formatted(
            .iso8601.year().month().day().dateSeparator(.dash)
        )

        let csvURL = directory.appending(path: "Tally-\(stamp).csv")
        let jsonURL = directory.appending(path: "Tally-\(stamp).json")

        let names = venues.reduce(into: [UUID: String]()) { $0[$1.id] = $1.name }
        try csv(events: events, venueNames: names).write(to: csvURL, atomically: true, encoding: .utf8)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload = Payload(
            exportedAt: now,
            schemaVersion: schemaVersion,
            events: events,
            venues: venues,
            materializedSessions: sessions,
            suppressedPlaces: suppressed
        )
        try encoder.encode(payload).write(to: jsonURL, options: .atomic)

        return Bundle(csv: csvURL, json: jsonURL, eventCount: events.count)
    }

    // MARK: - CSV

    static let csvHeader = [
        "id",
        "type",
        "timestamp",
        "latitude",
        "longitude",
        "horizontalAccuracy",
        "source",
        "venueID",
        "venueName"
    ]

    /// One row per event, ordered oldest first, ISO-8601 timestamps — parseable
    /// by anything, which is the point of offering CSV at all.
    static func csv(events: [DrinkEventSnapshot], venueNames: [UUID: String]) -> String {
        var lines: [String] = [csvHeader.joined(separator: ",")]

        for event in events.sorted(by: DrinkEventSnapshot.isOrderedBefore) {
            let fields: [String] = [
                event.id.uuidString,
                event.type.rawValue,
                event.timestamp.formatted(.iso8601),
                event.latitude.map { String($0) } ?? "",
                event.longitude.map { String($0) } ?? "",
                event.horizontalAccuracy.map { String($0) } ?? "",
                event.source.rawValue,
                event.venueID?.uuidString ?? "",
                event.venueID.flatMap { venueNames[$0] } ?? ""
            ]
            lines.append(fields.map(escape).joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// RFC 4180 quoting: only when needed, and doubled quotes inside.
    ///
    /// `nonisolated` so it can be passed to `map` — it is pure string work and
    /// has no business being main-actor bound.
    nonisolated private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
