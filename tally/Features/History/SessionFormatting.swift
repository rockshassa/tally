import Foundation
import TallyKit

/// Every string History puts on screen, in one place so the Sessions list, the
/// detail header, and the reconciliation prompt never drift apart.
nonisolated public enum SessionFormatting {

    // MARK: Dates

    /// "Fri Aug 8" — the Sessions list row.
    public static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// "Friday, Aug 8" — the detail header.
    public static func longDate(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// "9:05" — timeline rail.
    public static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "9:05 – 11:15 pm" — detail subtitle.
    public static func timeRange(from start: Date, to end: Date) -> String {
        "\(time(start)) – \(time(end))"
    }

    // MARK: Duration

    /// "2 h 10 m", "45 m", "—" for an instant.
    public static func duration(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        guard total > 0 else { return "—" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours == 0 { return "\(minutes) m" }
        return String(format: "%d h %02d m", hours, minutes)
    }

    // MARK: Counts

    /// "4 · 2 spacers · 2 h 10 m" for a Session with alcohol; a zero-alcohol
    /// night says so in its own words, since spacers are meaningless there.
    public static func statsLine(for session: DerivedSession) -> String {
        var parts: [String] = []
        if session.alcoholicCount == 0 {
            parts.append("\(session.nonAlcoholicCount) non-alc")
        } else {
            parts.append("\(session.alcoholicCount)")
            parts.append(session.spacerCount == 1 ? "1 spacer" : "\(session.spacerCount) spacers")
        }
        parts.append(duration(session.duration))
        return parts.joined(separator: " · ")
    }

    /// The venue name, or the honest absence of one.
    public static func venueName(for session: DerivedSession, venues: [UUID: VenueSnapshot]) -> String {
        guard let id = session.venueID, let venue = venues[id] else { return "No venue" }
        return venue.name.isEmpty ? "No venue" : venue.name
    }
}

// MARK: - Session presentation

public extension DerivedSession {

    /// SPEC §3's *Designated Legend* territory, and the mockups' aqua-tinted
    /// card: a night out with nothing alcoholic in it.
    nonisolated var isZeroAlcohol: Bool {
        alcoholicCount == 0 && nonAlcoholicCount > 0
    }

    nonisolated var hasNote: Bool {
        guard let note else { return false }
        return !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Ordering for History: pinned Sessions surface, then newest first
    /// (SPEC §2 — pins are how you keep a night at the top).
    nonisolated static func isOrderedForHistory(_ lhs: DerivedSession, _ rhs: DerivedSession) -> Bool {
        if lhs.pinned != rhs.pinned { return lhs.pinned }
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
