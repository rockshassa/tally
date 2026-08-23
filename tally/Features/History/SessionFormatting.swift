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

// MARK: - Accessibility

/// The identifiers History's own rows carry.
///
/// `A11y.History` (in `tally/Shared`) names the screen the shell hosts; anything
/// drawn *inside* a History view is named here, the same split `SettingsA11y`
/// uses for Settings. Renaming one breaks the XCUITest suite, so these strings
/// are API.
enum HistoryA11y {

    /// SPEC §4's Session rebound classification line, on Session detail.
    static let reboundClass = "history.reboundClass"
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

    // MARK: Recovery context (SPEC §4)

    /// SPEC §4's *Session rebound classification*: "peak drinking density per
    /// 90 min classifies the Session paced / elevated / compressed, with one
    /// factual line about the modeled next-morning rebound."
    ///
    /// `nil` — draw nothing at all — is the honest answer in two cases, and both
    /// are load-bearing:
    /// * **recovery context off**, which SPEC §4 promises is "zero footprint";
    /// * **nothing alcoholic logged**, where the model has no pulse to model and
    ///   "Paced — modeled next-morning rebound low." would be a sentence about
    ///   nothing. `FibrinolysisModel.classify` answers `.paced` for an empty
    ///   night by construction, so the caller — not the model — owns the
    ///   decision to stay quiet.
    ///
    /// One pure function rather than two, because the Session detail row and the
    /// Session true-up (SPEC §2) must agree about when the line appears. The
    /// toggle is a parameter defaulted to the stored one, so either state can be
    /// rendered — or tested — without writing to global defaults.
    nonisolated func reboundClass(
        recoveryEnabled: Bool = RecoveryContext.isEnabled(),
        model: FibrinolysisModel = FibrinolysisModel()
    ) -> FibrinolysisModel.ReboundClass? {
        guard recoveryEnabled, alcoholicCount > 0 else { return nil }
        return model.classify(self)
    }
}
