import Foundation
import TallyKit

/// SPEC §2's Session true-up, as arithmetic.
///
/// > **Session true-up:** when a Session with ≥1 drink closes, one reconciliation
/// > prompt: *"Session at The Anchor ended — 4 drinks, 1 water. Look right?"* with
/// > actions **Looks right** (dismisses), **+1 drink** (retro-logs, venue-tagged,
/// > timestamped at close), and tap-through to the Session's editable timeline in
/// > History. Fires on every close, one per Session: a geofence exit delivers
/// > immediately (quiet-hours exempt — the user is demonstrably out and awake); a
/// > timeout close (home, or no geofence) delivers with quiet-hours *postpone*
/// > semantics, so a Session that expires at 2 a.m. reconciles in the morning
/// > instead of waking anyone.
///
/// Four decisions live here, and all four are pure functions of a
/// `DerivedSession` and the user's settings, so `RadarService` performs them
/// rather than deciding them — the same seam `RadarVisitMachine` sits behind:
/// * **what the prompt says** — the counts, straight off the closed Session;
/// * **when a timeout close should fire** — `closesAt`, shifted out of quiet hours;
/// * **where a retro "+1 drink" lands** — inside the Session, not after it;
/// * **whether SPEC §4's rebound line rides along** — decided here, where the
///   closed `DerivedSession` still exists, rather than in the notification
///   builder, which sees only two counts.
nonisolated public enum SessionTrueUp {

    // MARK: - The prompt

    /// The true-up a closed Session deserves, or `nil` when it has nothing in it.
    ///
    /// SPEC §2 says "a Session with ≥1 drink"; a Session with no events at all is
    /// a materialized record whose contents were deleted, and there is nothing to
    /// reconcile.
    public static func trueUp(for session: DerivedSession) -> RadarTrueUp? {
        guard !session.events.isEmpty else { return nil }
        return RadarTrueUp(
            sessionID: session.id,
            alcoholicCount: session.alcoholicCount,
            nonAlcoholicCount: session.nonAlcoholicCount,
            logAt: logTimestamp(for: session)
        )
    }

    /// - Parameter placeName: the venue's name, or `""` for an untagged Session —
    ///   `RadarCopy.TrueUp` says "Session ended" rather than naming a place it
    ///   does not know.
    /// - Parameter recoveryEnabled: SPEC §4's opt-in recovery context. When it is
    ///   on, the true-up gains one factual line about the modeled next-morning
    ///   rebound —
    ///
    ///   > **Session rebound classification** on Session detail *and the
    ///   > true-up*.
    ///
    ///   — and when it is off the prompt carries no class, so the delivered body
    ///   is byte-identical to the one this app sent before the recovery layer
    ///   existed. A parameter rather than a read inside the copy: the flag is
    ///   defaulted to the stored toggle so `RadarService` needs to know nothing
    ///   about it, and injectable so either state can be exercised without
    ///   writing to global defaults.
    /// - Parameter model: the classifier, injectable for the same reason.
    public static func prompt(
        for session: DerivedSession,
        placeName: String,
        recoveryEnabled: Bool = RecoveryContext.isEnabled(),
        model: FibrinolysisModel = FibrinolysisModel()
    ) -> RadarPrompt? {
        guard let trueUp = trueUp(for: session) else { return nil }
        return RadarPrompt(
            kind: .trueUp,
            placeName: placeName,
            venueID: session.venueID,
            trueUp: trueUp,
            // The same rule the Session detail row uses, so the two surfaces SPEC
            // §4 names cannot disagree about a night — including its "nothing
            // alcoholic logged, so say nothing" half.
            reboundClass: session.reboundClass(recoveryEnabled: recoveryEnabled, model: model)
        )
    }

    // MARK: - The retro log

    /// How far inside the close moment a retro "+1 drink" is stamped.
    public static let logInset: TimeInterval = 1

    /// Where SPEC §2's "timestamped at close" actually puts the drink.
    ///
    /// One second *inside* `closesAt`, never on it, because `SessionDeriver`'s two
    /// closing rules both exclude the boundary:
    /// * the 3 h gap is `gap < inactivityWindow`, so a drink stamped exactly at
    ///   `lastDrink + 3 h` opens the **next** Session rather than joining this one;
    /// * a Bar Radar exit splits any pair of drinks it falls between, and an
    ///   exit-closed Session has `closesAt` equal to the exit's own timestamp.
    ///
    /// Either way, stamping on the boundary would file the correction against a
    /// Session that does not exist yet — the exact opposite of a true-up. Floored
    /// at the last drink's own timestamp for the degenerate case where the exit
    /// landed on it, so the correction can never be dated before the Session it
    /// corrects.
    public static func logTimestamp(for session: DerivedSession) -> Date {
        max(session.endedAt, session.closesAt.addingTimeInterval(-logInset))
    }

    // MARK: - The timeout close

    /// When a timeout-close true-up should actually fire.
    ///
    /// SPEC §2 asks for *postpone* semantics here, and
    /// `TallyNotificationCategory.sessionTrueUp` declares `.postpone` to match.
    /// The shift is computed now, at scheduling time, because that is the only
    /// moment anything can be applied to a `UNNotificationRequest`: it carries a
    /// fixed fire date, nothing wakes the app at 02:00 to move it, and
    /// `NotificationService.deliveryDate(for:category:)` — the app's one
    /// implementation of this policy — resolves its own categories the same way,
    /// at the point of scheduling. This is that same call, spelled out for a
    /// request that goes down the Bar Radar delivery path instead.
    ///
    /// A close that lands outside the window keeps its own time.
    public static func fireDate(
        closesAt: Date,
        quietHours: QuietHours,
        calendar: Calendar = .current
    ) -> Date {
        quietHours.deliveryDate(for: closesAt, calendar: calendar)
    }
}
