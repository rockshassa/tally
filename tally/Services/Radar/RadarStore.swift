import CoreLocation
import Foundation
import TallyKit

/// The little bit of Bar Radar that has to survive a launch (SPEC §2).
///
/// Almost nothing here is app state in the usual sense — it is all *bookkeeping
/// for suppression rules*, and every one of those rules is worthless if it is
/// forgotten when the app is killed:
///
/// | Stored | Rule it enforces |
/// |---|---|
/// | Open visits | "re-entry within 2 h counts as the same visit", "one follow-up maximum per visit" |
/// | Geofence exits | a Session "closes … immediately when a Bar Radar exit event fires" |
/// | Discovery prompt dates | "max 3 discovery prompts per week" |
/// | Spot dismissals | "Two plain dismissals at the same spot auto-suppress it" |
///
/// A geofence entry can wake the app in the background hours after it was last
/// used, so this is written to the App Group suite (`TallyDefaults`) that every
/// Tally process reads.
@MainActor
public final class RadarStore {

    // MARK: - Keys

    public enum Keys {
        public static let visitState = "tally.radar.visitState"
        public static let venueExits = "tally.radar.venueExits"
        public static let discoveryPrompts = "tally.radar.discoveryPrompts"
        public static let spotDismissals = "tally.radar.spotDismissals"
        public static let venueDismissals = "tally.radar.venueDismissals"

        public static let all: [String] = [
            visitState, venueExits, discoveryPrompts, spotDismissals, venueDismissals
        ]
    }

    /// Exits older than this cannot affect any derivation: SPEC §2 closes a
    /// Session 3 h after its last drink, so an exit a day old has nothing left to
    /// close.
    static let exitRetention: TimeInterval = 24 * 60 * 60

    /// Long enough for the rolling weekly cap plus slack.
    static let promptRetention: TimeInterval = 14 * 24 * 60 * 60

    /// A dismissal that old is not evidence about tonight.
    static let dismissalRetention: TimeInterval = 90 * 24 * 60 * 60

    static let maxRecords = 200

    // MARK: - Records

    struct StoredExit: Hashable, Sendable, Codable {
        var venueID: UUID
        var occurredAt: Date
    }

    /// SPEC §2: "Two plain dismissals at the same spot auto-suppress it."
    public struct SpotDismissal: Hashable, Sendable, Codable {
        public var latitude: Double
        public var longitude: Double
        public var count: Int
        public var lastAt: Date
        public var name: String?
        public var mapItemID: String?
    }

    // MARK: - Init

    private let read: @MainActor (String) -> Any?
    private let write: @MainActor (Any?, String) -> Void

    /// Defaults to the App Group suite. The closures exist so a test can drive a
    /// store without touching the process's real defaults.
    public init(
        read: @escaping @MainActor (String) -> Any? = { TallyDefaults.object(forKey: $0) },
        write: @escaping @MainActor (Any?, String) -> Void = { TallyDefaults.set($0, forKey: $1) }
    ) {
        self.read = read
        self.write = write
    }

    /// An in-memory store, for tests and previews.
    public static func ephemeral() -> RadarStore {
        let box = Box()
        return RadarStore(
            read: { box.values[$0] },
            write: { value, key in
                if let value { box.values[key] = value } else { box.values.removeValue(forKey: key) }
            }
        )
    }

    @MainActor
    private final class Box {
        var values: [String: Any] = [:]
    }

    // MARK: - Visits

    public var visitState: RadarVisitState {
        get { decode(Keys.visitState) ?? RadarVisitState() }
        set { encode(newValue, forKey: Keys.visitState) }
    }

    // MARK: - Exits

    /// SPEC §2's exit hook, persisted so `SessionDeriver` can consume it.
    public func recordExit(venueID: UUID, at date: Date) {
        var exits: [StoredExit] = decode(Keys.venueExits) ?? []
        exits.append(StoredExit(venueID: venueID, occurredAt: date))
        exits = exits
            .filter { date.timeIntervalSince($0.occurredAt) <= Self.exitRetention }
            .suffix(Self.maxRecords)
            .map { $0 }
        encode(exits, forKey: Keys.venueExits)
    }

    /// The exits `SessionDeriver.derive(…, venueExits:)` should be given.
    public func venueExits(asOf now: Date = Date()) -> [SessionDeriver.VenueExit] {
        let exits: [StoredExit] = decode(Keys.venueExits) ?? []
        return exits
            .filter { now.timeIntervalSince($0.occurredAt) <= Self.exitRetention }
            .map { SessionDeriver.VenueExit(venueID: $0.venueID, occurredAt: $0.occurredAt) }
    }

    // MARK: - Discovery cap

    public func recordDiscoveryPrompt(at date: Date = Date()) {
        var dates: [Date] = decode(Keys.discoveryPrompts) ?? []
        dates.append(date)
        dates = dates
            .filter { date.timeIntervalSince($0) <= Self.promptRetention }
            .suffix(Self.maxRecords)
            .map { $0 }
        encode(dates, forKey: Keys.discoveryPrompts)
    }

    public func discoveryPromptDates(asOf now: Date = Date()) -> [Date] {
        let dates: [Date] = decode(Keys.discoveryPrompts) ?? []
        return dates.filter { now.timeIntervalSince($0) <= Self.promptRetention }
    }

    // MARK: - Dismissals

    /// Records a plain dismissal and reports how many this spot has now had.
    ///
    /// - Returns: the running count, so the caller can apply SPEC §2's
    ///   "two plain dismissals … auto-suppress it".
    @discardableResult
    public func recordDismissal(
        at coordinate: CLLocationCoordinate2D,
        name: String? = nil,
        mapItemID: String? = nil,
        radiusMeters: CLLocationDistance = 75,
        at date: Date = Date()
    ) -> Int {

        var records: [SpotDismissal] = decode(Keys.spotDismissals) ?? []
        records = records.filter { date.timeIntervalSince($0.lastAt) <= Self.dismissalRetention }

        let index = records.firstIndex { record in
            if let mapItemID, let stored = record.mapItemID { return stored == mapItemID }
            return CLLocation(latitude: record.latitude, longitude: record.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
                <= radiusMeters
        }

        let count: Int
        if let index {
            records[index].count += 1
            records[index].lastAt = date
            if records[index].mapItemID == nil { records[index].mapItemID = mapItemID }
            if records[index].name == nil { records[index].name = name }
            count = records[index].count
        } else {
            records.append(
                SpotDismissal(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    count: 1,
                    lastAt: date,
                    name: name,
                    mapItemID: mapItemID
                )
            )
            count = 1
        }

        encode(Array(records.suffix(Self.maxRecords)), forKey: Keys.spotDismissals)
        return count
    }

    public func dismissals() -> [SpotDismissal] {
        decode(Keys.spotDismissals) ?? []
    }

    // MARK: - Arrival dismissals (Tier 1)

    /// SPEC §2: per-venue mute is "also offered on the arrival notification after
    /// repeated dismissals" — so the arrival prompt has to know how many times it
    /// has been waved off here.
    @discardableResult
    public func recordArrivalDismissal(venueID: UUID, at date: Date = Date()) -> Int {
        var counts: [String: Int] = decode(Keys.venueDismissals) ?? [:]
        let next = (counts[venueID.uuidString] ?? 0) + 1
        counts[venueID.uuidString] = next
        encode(counts, forKey: Keys.venueDismissals)
        return next
    }

    public func arrivalDismissals(venueID: UUID) -> Int {
        let counts: [String: Int] = decode(Keys.venueDismissals) ?? [:]
        return counts[venueID.uuidString] ?? 0
    }

    /// Called once the venue is muted, or when it is unmuted from Settings: the
    /// offer has been answered either way.
    public func clearArrivalDismissals(venueID: UUID) {
        var counts: [String: Int] = decode(Keys.venueDismissals) ?? [:]
        counts.removeValue(forKey: venueID.uuidString)
        encode(counts, forKey: Keys.venueDismissals)
    }

    /// Forgets a spot's dismissals — used once it has been suppressed outright,
    /// so un-suppressing from Settings starts the count over.
    public func clearDismissals(near coordinate: CLLocationCoordinate2D, radiusMeters: CLLocationDistance = 75) {
        let records: [SpotDismissal] = decode(Keys.spotDismissals) ?? []
        let kept = records.filter { record in
            CLLocation(latitude: record.latitude, longitude: record.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
                > radiusMeters
        }
        encode(kept, forKey: Keys.spotDismissals)
    }

    // MARK: - Erase

    /// Settings → Erase all data (SPEC §9). Every rule above is about events
    /// that no longer exist.
    public func reset() {
        for key in Keys.all { write(nil, key) }
    }

    // MARK: - Coding

    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = read(key) as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        write(data, key)
    }
}
