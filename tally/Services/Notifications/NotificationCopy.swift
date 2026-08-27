import Foundation
import UserNotifications

// MARK: - The three fields a banner has

/// One notification's words, split across the three fields iOS actually renders.
///
/// **Why this type exists.** A collapsed banner is clamped to roughly one title
/// line and two body lines, and everything past that is cut — so what a
/// notification *says* is decided by which field each sentence lands in, not by
/// how well the sentence is written. SPEC §2 spells the rule out for Bar Radar
/// and it applies to every category in SPEC §5:
///
/// > **Notification copy** must survive the banner's two-line clamp: the venue
/// > name goes in the **title**, the question in the **body**, and any secondary
/// > line (e.g. the recovery rebound class, §4) in a **subtitle** — never
/// > appended to the body, where it is the first thing truncated. Titles stay
/// > under ~40 characters; long venue names truncate in the middle, keeping the
/// > distinguishing tail.
///
/// So: `title` names the subject, `body` asks the question, and `subtitle` holds
/// the one supporting line. Three fields rather than three strings joined with
/// newlines, because a joined string is exactly what gets truncated.
nonisolated public struct NotificationText: Hashable, Sendable {

    /// Who or what this is about — the venue, the week, the streak. One line.
    public var title: String

    /// The one supporting line, or `""` for none. iOS draws no subtitle row for
    /// an empty string, which is why this is not an `Optional`: the field on
    /// `UNMutableNotificationContent` is a plain `String` and "" is its absence.
    public var subtitle: String

    /// The question, or the headline fact. This is what the user is being asked.
    public var body: String

    public init(title: String, subtitle: String = "", body: String) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }

    public var hasSubtitle: Bool { !subtitle.isEmpty }
}

// MARK: - Venue names in titles

nonisolated public extension NotificationText {

    /// SPEC §2: "Titles stay under ~40 characters."
    static let titleLimit = 40

    /// However long the fixed words around it are, the venue never gets less of
    /// the title than this — a title that has shortened the name to nothing has
    /// lost the only part the user needed.
    static let venueFloor = 12

    /// A venue name that fits `limit`, middle-truncated if it has to be.
    ///
    /// SPEC §2 asks for the *middle* to go, "keeping the distinguishing tail":
    /// bar names share their openings far more often than their endings ("The
    /// Old …", "Ye Olde …"), so a head-truncated list of long names reads as the
    /// same place repeated. Whole words are dropped where the name has three or
    /// more of them —
    ///
    /// ```
    /// "The Very Long Tavern And Grill" (limit 25) → "The Very Long…And Grill"
    /// ```
    ///
    /// — and only a name that cannot be folded on a space (one long word, or a
    /// budget too small for two of them) falls back to cutting mid-word.
    ///
    /// The result is never longer than `limit`, counted in characters — which is
    /// grapheme clusters, so an emoji in a bar's name costs one, as it does on
    /// screen.
    static func shortVenue(_ name: String, limit: Int = titleLimit) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 1 else { return String(trimmed.prefix(max(0, limit))) }
        guard trimmed.count > limit else { return trimmed }

        // One character of the budget is the ellipsis itself.
        let available = limit - 1
        let words = trimmed.split(separator: " ").map(String.init)

        if words.count >= 3, let folded = foldedWords(words, available: available) {
            return folded
        }

        let tail = available / 2
        let head = available - tail
        return String(trimmed.prefix(head)) + "…" + String(trimmed.suffix(tail))
    }

    /// A title of the form `prefix` + venue + `suffix`, with the venue shortened
    /// so the *whole* title fits `limit`.
    ///
    /// The fixed words are charged to the same budget as the name, because the
    /// clamp does not care which part of the line came from a constant: "Looks
    /// like you're at " is 21 of the 40 characters before the venue has said
    /// anything.
    static func venueTitle(
        prefix: String = "",
        venue: String,
        suffix: String = "",
        limit: Int = titleLimit
    ) -> String {
        let budget = max(venueFloor, limit - prefix.count - suffix.count)
        return prefix + shortVenue(venue, limit: budget) + suffix
    }

    /// Drops whole words from the middle until what is left fits.
    ///
    /// The tail is filled first, from the budget's back half, and the head gets
    /// whatever the tail did not spend — which is what keeps the distinguishing
    /// end of the name and lets the front give way. `nil` when the name cannot be
    /// folded this way at all: no tail word fits, no head word fits, or nothing
    /// would actually be dropped, in which case an ellipsis would be a lie.
    private static func foldedWords(_ words: [String], available: Int) -> String? {

        var tail: [String] = []
        var tailCount = 0
        // `dropLast` on the reversed words is the *first* word of the name: the
        // head must keep at least one, or this is not a middle truncation.
        for word in words.reversed().dropLast() {
            let addition = tail.isEmpty ? word.count : word.count + 1
            guard tailCount + addition <= available / 2 else { break }
            tail.insert(word, at: 0)
            tailCount += addition
        }
        guard !tail.isEmpty else { return nil }

        var head: [String] = []
        var headCount = 0
        for word in words.dropLast(tail.count) {
            let addition = head.isEmpty ? word.count : word.count + 1
            guard headCount + addition <= available - tailCount else { break }
            head.append(word)
            headCount += addition
        }
        guard !head.isEmpty, head.count + tail.count < words.count else { return nil }

        return head.joined(separator: " ") + "…" + tail.joined(separator: " ")
    }
}

// MARK: - Onto the request

public extension UNMutableNotificationContent {

    /// Writes all three fields, always.
    ///
    /// All three, including an empty subtitle: content objects are built fresh
    /// today, but a field that is only *sometimes* assigned is how a rebound line
    /// from one Session ends up over the top of another.
    func apply(_ text: NotificationText) {
        title = text.title
        subtitle = text.subtitle
        body = text.body
    }
}

/// **Every word Tally puts on a lock screen, in one file.**
///
/// Collected here so the tone rule from SPEC §5 can be reviewed in a single
/// sitting rather than hunted through a scheduler:
///
/// > Tone throughout: neutral-to-encouraging, never shaming. Upward-trend alerts
/// > state facts ("up 20% vs last month") without judgment.
///
/// The rules this copy follows, in order of how easy they are to break:
/// 1. **Report the user's own numbers.** Never an average, a guideline, or a
///    comparison with anyone else.
/// 2. **No adjectives about the user.** "12 drinks this week" — never "only",
///    "already", "still", or "just".
/// 3. **Praise is allowed, blame is not.** A downward trend may say "nice"; an
///    upward one says the number and stops. This asymmetry is the whole point of
///    SPEC §5's rule, and it is load-bearing: the app rewards moderation and NA
///    drinks (SPEC §3) and never comments on alcohol.
/// 4. **Suggestions are offers.** "Time for a spacer?" with a question mark; the
///    user is allowed to say no by ignoring it.
///
/// Every category answers with a `NotificationText` — see that type for why the
/// split into title / subtitle / body is the copy rather than a detail of it.
enum NotificationCopy {

    // MARK: - Weekly digest (Sunday evening)

    enum Digest {

        static let title = "Your week"

        /// SPEC §5's example, split: "12 drinks this week, down 3 from last." is
        /// the news and gets the body; the average and the spacer count are the
        /// supporting numbers and ride in the subtitle, where two more sentences
        /// of body would have been cut.
        static func text(_ facts: NotificationTriggers.DigestFacts) -> NotificationText {
            NotificationText(title: title, subtitle: context(facts), body: headline(facts))
        }

        /// "12 drinks this week, down 3 from last."
        static func headline(_ facts: NotificationTriggers.DigestFacts) -> String {
            let drinks = facts.alcoholicThisWeek
            let noun = drinks == 1 ? "drink" : "drinks"
            let change = facts.change

            guard change != 0 else { return "\(drinks) \(noun) this week, same as last." }
            let word = change < 0 ? "down" : "up"
            return "\(drinks) \(noun) this week, \(word) \(abs(change)) from last."
        }

        /// "7-day avg: 1.7/day. 3 spacers."
        static func context(_ facts: NotificationTriggers.DigestFacts) -> String {
            var sentences = ["7-day avg: \(average(facts.sevenDayAverage))/day."]

            if facts.spacersThisWeek > 0 {
                let spacers = facts.spacersThisWeek
                sentences.append("\(spacers) \(spacers == 1 ? "spacer" : "spacers").")
            } else if facts.nonAlcoholicThisWeek > 0 {
                let na = facts.nonAlcoholicThisWeek
                sentences.append("\(na) NA \(na == 1 ? "drink" : "drinks").")
            }

            return sentences.joined(separator: " ")
        }

        private static func average(_ value: Double) -> String {
            value.formatted(.number.precision(.fractionLength(1)))
        }
    }

    // MARK: - Trend alerts

    enum Trend {

        static let title = "7-day average"

        /// The sentence in the body, the number in the subtitle. Splitting them
        /// costs nothing here — each half is a whole sentence already — and it is
        /// the half with the praise or the plain fact that has to survive.
        static func text(_ finding: NotificationTriggers.TrendFinding) -> NotificationText {
            NotificationText(title: title, subtitle: magnitude(finding), body: headline(finding))
        }

        /// Down: "Third week trending down — nice." Up: the same sentence with
        /// the praise removed and the number kept. Nothing else changes, which is
        /// exactly SPEC §5's asymmetry.
        static func headline(_ finding: NotificationTriggers.TrendFinding) -> String {
            let ordinal = ordinalWord(finding.weeks)
            switch finding.direction {
            case .down: return "\(ordinal) week trending down — nice."
            case .up: return "\(ordinal) week trending up."
            }
        }

        /// "Down 20% over the run." — SPEC §5's "up 20% vs last month … without
        /// judgment", which is why this line is the same shape in both
        /// directions.
        static func magnitude(_ finding: NotificationTriggers.TrendFinding) -> String {
            let word = finding.direction == .down ? "Down" : "Up"
            return "\(word) \(finding.percentChange)% over the run."
        }

        private static func ordinalWord(_ weeks: Int) -> String {
            switch weeks {
            case ...2: "Second"
            case 3: "Third"
            case 4: "Fourth"
            case 5: "Fifth"
            default: "\(weeks)th"
            }
        }
    }

    // MARK: - Pacing nudge (in-Session)

    enum Pacing {

        static let title = "Time for a spacer?"

        /// The offer in the body, the user's own count above it. The count is
        /// context for a question the title already asked, so it is the line that
        /// can afford to be clipped — and the offer, which names the reward, is
        /// the line that cannot.
        static func text(_ finding: NotificationTriggers.PacingFinding) -> NotificationText {
            NotificationText(title: title, subtitle: count(finding), body: offer)
        }

        /// "3 in the last 90 minutes." Rule 1, and nothing else: a number the
        /// user logged, with no adjective attached to it.
        static func count(_ finding: NotificationTriggers.PacingFinding) -> String {
            "\(finding.alcoholicCount) in the last \(finding.windowMinutes) minutes."
        }

        /// The "+25 pts" is the spacer bonus from SPEC §3 — the offer is a
        /// reward, not a warning.
        static let offer = "A non-alcoholic one now counts as a spacer: +25 pts."
    }

    // MARK: - Streak protection (evening)

    enum Streak {

        /// Short and safe already: a title of at most "999-day streak on the
        /// line" and a one-sentence body. There is no second line to move, so
        /// this category's strings are exactly what they were.
        static func text(_ risk: NotificationTriggers.StreakRisk) -> NotificationText {
            NotificationText(title: title(risk), body: body(risk))
        }

        static func title(_ risk: NotificationTriggers.StreakRisk) -> String {
            "\(risk.streakDays)-day streak on the line"
        }

        static func body(_ risk: NotificationTriggers.StreakRisk) -> String {
            let count = risk.nonAlcoholicNeeded
            return count == 1
                ? "One non-alcoholic drink keeps it going."
                : "\(count) non-alcoholic drinks keep it going."
        }
    }

    // MARK: - The primer (SPEC §9)

    /// Shown after the first Session closes — "a success moment, not a cold
    /// start". The copy leads with what the user just did.
    enum Primer {

        static let title = "That's your first Session"

        static let message =
            "Tally can follow up with a Sunday digest, a nudge if drinks are stacking up, "
            + "and a heads-up when a streak is on the line. Pick what you want — all of it is optional."

        static let bullets = [
            "Everything is computed on your device.",
            "Quiet hours are on by default, and adjustable in Settings.",
            "Turn any of it off later, or all of it."
        ]

        static let grantTitle = "Turn on notifications"
        static let notNowTitle = "Not now"
        static let footnote = "Nothing leaves your device. \"Not now\" keeps every category off."
    }

    // MARK: - Settings explainers (SPEC §9)

    enum Settings {

        static let quietHoursFootnote =
            "Quiet hours hold everything back until the window ends — except Bar Radar, "
            + "because bar hours are exactly when those prompts are useful."

        static let deniedStatus =
            "Notifications are off at the system level. iOS only asks once, so this has to be changed in Settings."

        static let provisionalStatus =
            "Delivering quietly — notifications arrive in Notification Centre without a sound. "
            + "Turn them on fully to get the pacing nudge and streak alerts."
    }
}
