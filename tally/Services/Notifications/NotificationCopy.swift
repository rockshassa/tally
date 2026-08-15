import Foundation

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
enum NotificationCopy {

    // MARK: - Weekly digest (Sunday evening)

    enum Digest {

        static let title = "Your week"

        /// "12 drinks this week, down 3 from last. 7-day avg: 1.7/day."
        static func body(_ facts: NotificationTriggers.DigestFacts) -> String {
            var sentences: [String] = []

            let drinks = facts.alcoholicThisWeek
            let noun = drinks == 1 ? "drink" : "drinks"
            let change = facts.change

            if change == 0 {
                sentences.append("\(drinks) \(noun) this week, same as last.")
            } else {
                let word = change < 0 ? "down" : "up"
                sentences.append("\(drinks) \(noun) this week, \(word) \(abs(change)) from last.")
            }

            sentences.append("7-day avg: \(average(facts.sevenDayAverage))/day.")

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

        /// Down: "Third week trending down — nice." Up: the same sentence with
        /// the praise removed and the number kept. Nothing else changes, which is
        /// exactly SPEC §5's asymmetry.
        static func body(_ finding: NotificationTriggers.TrendFinding) -> String {
            let ordinal = ordinalWord(finding.weeks)
            switch finding.direction {
            case .down:
                return "\(ordinal) week trending down — nice. Down \(finding.percentChange)% over the run."
            case .up:
                return "\(ordinal) week trending up. Up \(finding.percentChange)% over the run."
            }
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

        /// SPEC §5's example body, plus the user's own count. The "+25 pts" is
        /// the spacer bonus from SPEC §3 — the offer is a reward, not a warning.
        static func body(_ finding: NotificationTriggers.PacingFinding) -> String {
            "\(finding.alcoholicCount) in the last \(finding.windowMinutes) minutes. "
                + "A non-alcoholic one now counts as a spacer: +25 pts."
        }
    }

    // MARK: - Streak protection (evening)

    enum Streak {

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
