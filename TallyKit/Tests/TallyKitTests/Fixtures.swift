import Foundation
@testable import TallyKit

/// Deterministic fixtures. Every UUID and date here is fixed, so a failure is
/// always reproducible and never depends on the wall clock or the machine's
/// locale/time zone.
enum Fixture {

    /// UTC gregorian — day bucketing in tests must not drift with the runner's
    /// time zone.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// 2023-11-14 22:13:20 UTC. Arbitrary but fixed.
    static let origin = Date(timeIntervalSince1970: 1_700_000_000)

    /// Midnight UTC on a fixed day, so "days" in streak tests are unambiguous.
    static let midnight = Date(timeIntervalSince1970: 1_699_920_000)

    static let hour: TimeInterval = 3600
    static let day: TimeInterval = 86_400

    static func uuid(_ index: Int) -> UUID {
        let suffix = String(format: "%012llX", UInt64(index))
        return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }

    /// `origin` plus a number of hours.
    static func at(_ hours: Double, from base: Date = origin) -> Date {
        base.addingTimeInterval(hours * hour)
    }

    /// `midnight` plus a number of days.
    static func onDay(_ days: Int, hour hourOfDay: Double = 20) -> Date {
        midnight.addingTimeInterval(Double(days) * day + hourOfDay * hour)
    }

    static func event(
        _ index: Int,
        at date: Date,
        _ type: DrinkType = .alcoholic,
        venue: UUID? = nil,
        source: EventSource = .app
    ) -> DrinkEventSnapshot {
        DrinkEventSnapshot(
            id: uuid(index),
            type: type,
            timestamp: date,
            source: source,
            venueID: venue
        )
    }

    /// `event(_:at:)` with the timestamp expressed in hours from `origin`.
    static func event(
        _ index: Int,
        hours: Double,
        _ type: DrinkType = .alcoholic,
        venue: UUID? = nil,
        source: EventSource = .app
    ) -> DrinkEventSnapshot {
        event(index, at: at(hours), type, venue: venue, source: source)
    }

    static let anchorVenueID = uuid(9001)
    static let saltyDogVenueID = uuid(9002)
    static let homeVenueID = uuid(9003)

    static let anchor = VenueSnapshot(
        id: anchorVenueID,
        name: "The Anchor",
        category: .bar,
        latitude: 51.5,
        longitude: -0.1,
        radiusMeters: 75
    )

    static let saltyDog = VenueSnapshot(
        id: saltyDogVenueID,
        name: "The Salty Dog",
        category: .bar,
        latitude: 51.6,
        longitude: -0.2,
        radiusMeters: 75
    )

    static let home = VenueSnapshot(
        id: homeVenueID,
        name: "Home",
        category: .home,
        latitude: 51.4,
        longitude: -0.3,
        radiusMeters: 100
    )

    static let venuesByID: [UUID: VenueSnapshot] = [anchor, saltyDog, home].byID

    static let scoringConfiguration = ScoringEngine.Configuration(calendar: calendar)
    static let engine = ScoringEngine(configuration: scoringConfiguration)
    static let deriver = SessionDeriver()
}

extension Array where Element == DerivedSession {
    /// Compact, diff-friendly projection used by the determinism assertions.
    var signature: [String] {
        map { session in
            [
                session.id.uuidString,
                String(session.startedAt.timeIntervalSince1970),
                String(session.endedAt.timeIntervalSince1970),
                String(session.closesAt.timeIntervalSince1970),
                session.venueID?.uuidString ?? "-",
                session.eventIDs.map(\.uuidString).joined(separator: ",")
            ].joined(separator: "|")
        }
    }
}
