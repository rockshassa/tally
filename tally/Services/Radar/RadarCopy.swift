import Foundation

/// **Every word Bar Radar puts on a lock screen or in a primer.**
///
/// Same rules as `NotificationCopy` (SPEC §5): report the user's own facts, no
/// adjectives about the user, suggestions are offers with a question mark. Bar
/// Radar has one extra obligation — it speaks *before* anything is logged, so it
/// must never assume the user is drinking. "Start a Session?" is an offer;
/// "Another one?" would not be.
enum RadarCopy {

    // MARK: - Notifications (SPEC §5)

    enum Arrival {
        /// SPEC §5's example: "Looks like you're at The Anchor — start a Session?"
        static func title(_ place: String) -> String { "Looks like you're at \(place)" }
        static let body = "Start a Session?"
    }

    enum Dwell {
        /// SPEC §5's example: "Still at The Anchor — start a Session?"
        static func title(_ place: String) -> String { "Still at \(place)" }
        static let body = "Nothing logged yet — start a Session?"
    }

    /// SPEC §2's mid-Session reminder. The one Bar Radar prompt that speaks
    /// *after* something has been logged, which is why it may ask about "more":
    /// the Session is a fact by the time this fires, so the offer is to top it up,
    /// not to start it.
    enum SessionReminder {
        /// SPEC §5's example: "Still at The Anchor — anything to add?"
        static func title(_ place: String) -> String { "Still at \(place)" }
        static let body = "Anything to add?"
    }

    enum Discovery {
        /// SPEC §5's example: "Looks like you're at The Salty Dog — start a Session?"
        static func title(_ place: String) -> String { "Looks like you're at \(place)" }
        static let body = "Start a Session?"
    }

    // MARK: - Actions (SPEC §2)

    enum Action {
        static let logDrink = "+1 drink"
        static let notDrinking = "Not drinking tonight"
        static let notABar = "Not a bar"

        /// SPEC §2: "Per-venue mute (also offered on the arrival notification
        /// after repeated dismissals)".
        static let muteVenue = "Stop asking here"
    }

    // MARK: - The Always-location explainer (SPEC §2, §9)

    /// SPEC §9: "The two-tier explainer (§2) before the system upgrade prompt."
    ///
    /// Both tiers are named before the permission is requested, because the
    /// permission buys both and a user who only wanted one should be able to see
    /// that before deciding.
    enum Explainer {

        static let identifierPrefix = "radar.always"

        static let symbolName = "dot.radiowaves.left.and.right"

        static let title = "Bar Radar needs Always location"

        static let message =
            "Bar Radar notices you're somewhere worth tracking and offers to start a Session. "
            + "It works in two tiers, and both need iOS to be allowed to tell Tally when you arrive."

        static let bullets = [
            "Bars you go to often: a precise geofence, so the prompt lands as you walk in.",
            "New bars: iOS already notices when you linger somewhere — Tally checks that spot against nearby bars, during your chosen hours only.",
            "iOS does the watching. Tally receives arrivals and departures, never a location stream.",
            "Non-matches are discarded on the spot, and Home is never a Bar Radar target."
        ]

        static let grantTitle = "Allow Always location"

        static let notNowTitle = "Not now"

        static let footnote =
            "\"Not now\" leaves Bar Radar off and changes nothing else. Turning it off later drops straight back to When-In-Use."
    }
}
