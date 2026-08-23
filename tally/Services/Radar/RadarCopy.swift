import Foundation
import TallyKit

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

    /// SPEC §2's Session true-up, and the only prompt in this file that speaks
    /// *after* the outing is over.
    ///
    /// It is pure rule 1 — report the user's own numbers — and the question mark
    /// is doing real work: "Look right?" invites a correction, where "You had 4
    /// drinks" would be a verdict. Nothing here counts anything the user did not
    /// log, and no clause is added for a count of zero.
    enum TrueUp {

        /// SPEC §5's example: "Session at The Anchor ended — 4 drinks, 1 water."
        ///
        /// An untagged Session (home, or anywhere the check-in was skipped) has
        /// no venue to name, and inventing one would be worse than saying less.
        static func title(_ place: String) -> String {
            place.isEmpty ? "Session ended" : "Session at \(place) ended"
        }

        /// "4 drinks, 1 water. Look right?", and — with SPEC §4's recovery
        /// context on — a second line: "Compressed — this pattern models the
        /// strongest next-morning suppression."
        ///
        /// A zero is omitted rather than printed: "0 waters" reads as a comment on
        /// the user, which SPEC §5 rules out.
        ///
        /// - Parameter rebound: the Session's modeled rebound class, already
        ///   decided by `SessionTrueUp` from the closed `DerivedSession`. This
        ///   type never works out whether the line belongs — it only places it,
        ///   in the model's own words, because `ReboundClass.summary` is the
        ///   sentence that says "modeled" and paraphrasing it here would turn a
        ///   model into a claim. `nil` — recovery context off, which is the
        ///   default — returns the body byte-identical to the version that
        ///   predates the recovery layer (SPEC §4: "zero footprint when off").
        static func body(
            alcoholic: Int,
            nonAlcoholic: Int,
            rebound: FibrinolysisModel.ReboundClass? = nil
        ) -> String {
            var clauses: [String] = []
            if alcoholic > 0 {
                clauses.append("\(alcoholic) \(alcoholic == 1 ? "drink" : "drinks")")
            }
            if nonAlcoholic > 0 {
                clauses.append("\(nonAlcoholic) \(nonAlcoholic == 1 ? "water" : "waters")")
            }
            let counts = clauses.isEmpty ? "Look right?" : clauses.joined(separator: ", ") + ". Look right?"
            guard let rebound else { return counts }
            return counts + "\n" + rebound.summary
        }
    }

    // MARK: - Actions (SPEC §2)

    enum Action {
        static let logDrink = "+1 drink"
        static let notDrinking = "Not drinking tonight"
        static let notABar = "Not a bar"

        /// SPEC §2's true-up: "**Looks right** (dismisses)". A button that does
        /// nothing is the point — it lets someone answer the question instead of
        /// leaving the app to read silence as agreement.
        static let looksRight = "Looks right"

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
