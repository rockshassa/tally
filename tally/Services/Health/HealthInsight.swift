import Foundation

// The output vocabulary of SPEC §4's correlation engine.
//
// Every string in here is built from the user's own numbers and says only what
// happened alongside what. SPEC §4's framing rule is absolute: *"insights state
// correlations in your own numbers and never claim causation or prescribe."* So
// there is no "because", no "try", no "should", and no adjective that grades the
// user. The §5 tone rules do the rest — facts, no shame.

// MARK: - Comparison

/// The two numbers behind the morning-after chart.
nonisolated public struct HealthInsightComparison: Hashable, Sendable {

    public let metric: HealthMetric

    /// Mean on the days *after* a Session of ≥ `threshold` alcoholic drinks.
    public let afterDrinking: Double

    /// Mean on the days after a dry night — the user's own baseline.
    public let afterDry: Double

    public let drinkingDayCount: Int
    public let dryDayCount: Int

    /// SPEC §4's configurable Session threshold, carried along so the chart can
    /// label its own bar honestly ("after 3+ drinks").
    public let threshold: Int

    public init(
        metric: HealthMetric,
        afterDrinking: Double,
        afterDry: Double,
        drinkingDayCount: Int,
        dryDayCount: Int,
        threshold: Int
    ) {
        self.metric = metric
        self.afterDrinking = afterDrinking
        self.afterDry = afterDry
        self.drinkingDayCount = drinkingDayCount
        self.dryDayCount = dryDayCount
        self.threshold = threshold
    }

    /// Signed relative effect against the user's own baseline. Negative means
    /// less activity after drinking.
    public var relativeChange: Double {
        guard afterDry > 0 else { return 0 }
        return (afterDrinking - afterDry) / afterDry
    }
}

// MARK: - Insight

/// One qualifying correlation, ready to render.
///
/// Only the engine makes these, and only after both SPEC §4 guardrails have
/// passed — so the existence of a `HealthInsight` is itself the statement that
/// there were ≥ 8 comparisons on each side and a ≥ 20 % effect.
nonisolated public struct HealthInsight: Identifiable, Hashable, Sendable {

    public enum Kind: String, CaseIterable, Hashable, Sendable, Codable {

        /// Activity the day after a drinking night vs the day after a dry one.
        case morningAfter

        /// Trailing four weeks: drinks rising while activity falls.
        case weeklyDrift

        /// Workout frequency in heavier weeks vs lighter ones.
        case workoutDisplacement

        /// Card title. A noun phrase, never a verdict.
        public var title: String {
            switch self {
            case .morningAfter: "The morning after"
            case .weeklyDrift: "Four-week drift"
            case .workoutDisplacement: "Workouts by week"
            }
        }

        public var systemImageName: String {
            switch self {
            case .morningAfter: "sunrise"
            case .weeklyDrift: "chart.line.downtrend.xyaxis"
            case .workoutDisplacement: "figure.run"
            }
        }

        /// Render order on the Trends tab. The morning-after card carries the
        /// chart, so it leads.
        public var rank: Int {
            switch self {
            case .morningAfter: 0
            case .weeklyDrift: 1
            case .workoutDisplacement: 2
            }
        }
    }

    public let kind: Kind
    public let metric: HealthMetric

    /// One short line for the top of the card — the movement, in a percentage.
    public let headline: String

    /// The sentence SPEC §4 asks for, in the user's own numbers.
    public let detail: String

    /// Signed. Negative means less activity alongside more drinking.
    public let relativeChange: Double

    /// How many days (morning-after) or weeks (drift, displacement) the finding
    /// rests on. Shown in the card's footnote so the number is never mysterious.
    public let sampleCount: Int

    /// Present on `.morningAfter` — the chart's two bars.
    public let comparison: HealthInsightComparison?

    public var id: Kind { kind }

    public init(
        kind: Kind,
        metric: HealthMetric,
        headline: String,
        detail: String,
        relativeChange: Double,
        sampleCount: Int,
        comparison: HealthInsightComparison? = nil
    ) {
        self.kind = kind
        self.metric = metric
        self.headline = headline
        self.detail = detail
        self.relativeChange = relativeChange
        self.sampleCount = sampleCount
        self.comparison = comparison
    }

    /// Stable identity for "have we already told them this?" — the ≤ 1/week
    /// notification cap uses it so a re-derived, unchanged finding does not
    /// count as news.
    public var signature: String {
        "\(kind.rawValue).\(metric.rawValue).\(Int((relativeChange * 100).rounded()))"
    }

    /// SPEC §5's Activity insight category body.
    public var notificationBody: String { detail }

    public static func isOrderedBefore(_ lhs: HealthInsight, _ rhs: HealthInsight) -> Bool {
        if lhs.kind.rank != rhs.kind.rank { return lhs.kind.rank < rhs.kind.rank }
        return abs(lhs.relativeChange) > abs(rhs.relativeChange)
    }
}

// MARK: - Report

/// Everything one run of the engine produced, including why it produced nothing.
///
/// The `evidence` half exists because "no insight" is the common, correct answer
/// (SPEC §4: *"Absence is fine"*) and a silent engine is otherwise impossible to
/// tell apart from a broken one — in tests or in a bug report.
nonisolated public struct HealthInsightReport: Hashable, Sendable {

    /// How much comparable data the trailing window actually held.
    public struct Evidence: Hashable, Sendable {

        /// Days following a Session of ≥ threshold alcoholic drinks, with
        /// readable activity.
        public let drinkingComparisons: Int

        /// Days following a night with no alcoholic drinks, with readable
        /// activity.
        public let dryComparisons: Int

        /// The metric the morning-after analysis settled on, if any had a
        /// non-zero baseline.
        public let metric: HealthMetric?

        /// Whether SPEC §4's "≥ 8 and ≥ 8 in the trailing 90 days" floor was met.
        public let meetsSampleFloor: Bool

        /// Whether HealthKit returned anything readable at all. `false` is the
        /// signal that reads are missing or revoked (SPEC §4, §10) — HealthKit
        /// never says so directly.
        public let hasReadableActivity: Bool

        public init(
            drinkingComparisons: Int,
            dryComparisons: Int,
            metric: HealthMetric?,
            meetsSampleFloor: Bool,
            hasReadableActivity: Bool
        ) {
            self.drinkingComparisons = drinkingComparisons
            self.dryComparisons = dryComparisons
            self.metric = metric
            self.meetsSampleFloor = meetsSampleFloor
            self.hasReadableActivity = hasReadableActivity
        }

        public static let none = Evidence(
            drinkingComparisons: 0,
            dryComparisons: 0,
            metric: nil,
            meetsSampleFloor: false,
            hasReadableActivity: false
        )
    }

    public let insights: [HealthInsight]
    public let evidence: Evidence

    public init(insights: [HealthInsight], evidence: Evidence) {
        self.insights = insights
        self.evidence = evidence
    }

    public var isEmpty: Bool { insights.isEmpty }

    public var morningAfter: HealthInsight? {
        insights.first { $0.kind == .morningAfter }
    }

    /// The one a notification would carry: the strongest effect, ties broken by
    /// render order.
    public var headlineInsight: HealthInsight? {
        insights.max { abs($0.relativeChange) < abs($1.relativeChange) }
    }

    public static let empty = HealthInsightReport(insights: [], evidence: .none)
}

// MARK: - Copy

/// The sentence builders, in one place so the tone is reviewed once.
nonisolated enum HealthInsightCopy {

    /// "38% lower" / "12% higher". Magnitude and direction, no adjective.
    static func change(_ relative: Double) -> String {
        let percent = Int((abs(relative) * 100).rounded())
        return "\(percent)% \(relative < 0 ? "lower" : "higher")"
    }

    /// SPEC §4's threshold phrasing: "3+ drink Sessions".
    static func sessionThreshold(_ threshold: Int) -> String {
        "\(threshold)+ drink Session"
    }

    /// The example sentence from SPEC §4, generated:
    /// *"After 3+ drink Sessions, your next-day exercise averages 12 min vs your
    /// usual 34."*
    static func morningAfter(_ comparison: HealthInsightComparison) -> String {
        let metric = comparison.metric
        return "After \(sessionThreshold(comparison.threshold))s, your next-day \(metric.subject) averages "
            + "\(metric.formatted(comparison.afterDrinking)) vs your usual \(metric.formattedValue(comparison.afterDry))."
    }

    static func weeklyDrift(metric: HealthMetric, drinkChange: Double, activityChange: Double) -> String {
        "Over the last four weeks your drinks are \(change(drinkChange)) while your \(metric.subject) is \(change(activityChange))."
    }

    static func workoutDisplacement(heavier: Double, lighter: Double) -> String {
        let metric = HealthMetric.workouts
        return "In your heavier weeks you average \(metric.formatted(heavier)) a week, against \(metric.formattedValue(lighter)) in lighter ones."
    }

    /// Footnote under a card: what the number is made of.
    static func basis(days: Int) -> String {
        "\(days) comparable days · last 90"
    }

    static func basis(weeks: Int) -> String {
        "\(weeks) comparable weeks · last 90 days"
    }
}
