import Foundation

// The seam between HealthKit and everything that reasons about activity
// (SPEC §4, §10).
//
// Two rules this file exists to enforce:
//
// * **Nothing read from HealthKit is ever persisted.** No SwiftData model, no
//   CloudKit record, no cache on disk. `HealthDaySample` is a value that lives
//   for the length of one recomputation and then goes away (SPEC §10: "the
//   insights engine reads each device's local HealthKit store at computation
//   time and persists nothing").
// * **The correlation engine never imports HealthKit.** It takes `[HealthDaySample]`
//   and returns insights, which is what makes the SPEC §4 guardrails testable
//   against synthetic fixtures with no device, no entitlement, and no dialog.

// MARK: - Metric

/// Which activity number an insight is about.
///
/// SPEC §4's four reads, minus the ones that would need a different framing:
/// sleep and resting heart rate are deliberately out of scope for v1.
nonisolated public enum HealthMetric: String, CaseIterable, Hashable, Sendable, Codable {

    case exerciseMinutes
    case activeEnergy
    case steps
    case workouts

    /// Reads as the subject of a sentence: "your next-day *exercise*…".
    public var subject: String {
        switch self {
        case .exerciseMinutes: "exercise"
        case .activeEnergy: "active energy"
        case .steps: "step count"
        case .workouts: "workouts"
        }
    }

    /// Axis and legend label — short enough for a 44 pt chart.
    public var axisLabel: String {
        switch self {
        case .exerciseMinutes: "min/day"
        case .activeEnergy: "kcal/day"
        case .steps: "steps/day"
        case .workouts: "workouts/week"
        }
    }

    /// The user's own number, in their own units. Never rounded to a headline
    /// figure — SPEC §4 insights are made of the actual values.
    public func formatted(_ value: Double) -> String {
        switch self {
        case .exerciseMinutes:
            return "\(formattedValue(value)) min"
        case .activeEnergy:
            return "\(formattedValue(value)) kcal"
        case .steps:
            return "\(formattedValue(value)) steps"
        case .workouts:
            return "\(formattedValue(value)) workout\(abs(value - 1) < 0.05 ? "" : "s")"
        }
    }

    /// The number alone.
    ///
    /// SPEC §4's own example sentence names the unit once and then drops it —
    /// *"averages 12 min vs your usual 34"* — which is how a person says it, and
    /// how the copy in `HealthInsightCopy` says it too.
    public func formattedValue(_ value: Double) -> String {
        switch self {
        case .exerciseMinutes, .activeEnergy:
            return "\(Int(value.rounded()))"
        case .steps:
            return Int(value.rounded()).formatted(.number.grouping(.automatic))
        case .workouts:
            return value.formatted(.number.precision(.fractionLength(0...1)))
        }
    }

    /// Order the morning-after analysis tries metrics in.
    ///
    /// Exercise minutes first because that is SPEC §4's own example, and because
    /// it is the number that answers the question the feature asks. Steps next —
    /// the phone records them without a watch, so it is the metric most users
    /// actually have. Active energy last: it needs a watch too and moves with
    /// exercise minutes anyway. Workouts are not in the list; their comparison is
    /// the displacement analysis, which counts weeks rather than days.
    public static let morningAfterPreference: [HealthMetric] = [.exerciseMinutes, .steps, .activeEnergy]
}

// MARK: - Day sample

/// One calendar day of activity, as read from HealthKit at computation time.
///
/// Deliberately a plain value with no HealthKit types in it: it crosses into the
/// pure engine, into fixtures, and into previews, none of which should need a
/// `HKHealthStore`.
nonisolated public struct HealthDaySample: Identifiable, Hashable, Sendable {

    /// Start of day in the reader's calendar.
    public let day: Date

    public let exerciseMinutes: Double
    public let activeEnergyKilocalories: Double
    public let stepCount: Double
    public let workoutCount: Int

    public var id: Date { day }

    public init(
        day: Date,
        exerciseMinutes: Double = 0,
        activeEnergyKilocalories: Double = 0,
        stepCount: Double = 0,
        workoutCount: Int = 0
    ) {
        self.day = day
        self.exerciseMinutes = exerciseMinutes
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.stepCount = stepCount
        self.workoutCount = workoutCount
    }

    public func value(for metric: HealthMetric) -> Double {
        switch metric {
        case .exerciseMinutes: exerciseMinutes
        case .activeEnergy: activeEnergyKilocalories
        case .steps: stepCount
        case .workouts: Double(workoutCount)
        }
    }

    /// Whether this day is *data* rather than a hole.
    ///
    /// A day with literally nothing — no steps, no energy, no exercise — is a day
    /// the phone spent on a table, not a rest day. Counting those as zeros would
    /// manufacture effects out of holidays and dead batteries, so they are
    /// excluded from every comparison instead.
    public var hasSignal: Bool {
        stepCount > 0 || exerciseMinutes > 0 || activeEnergyKilocalories > 0 || workoutCount > 0
    }
}

// MARK: - Provider

/// Everything the insights engine needs from HealthKit, and nothing else.
///
/// Main-actor bound to match `PermissionsService` and the section that drives it;
/// the queries themselves run on HealthKit's own queues and hop back.
///
/// Reads are **on demand**. There is no sync, no import, and no local copy — each
/// refresh asks HealthKit for the window it needs and throws the answer away when
/// the view goes (SPEC §1's derive-don't-store, SPEC §10's privacy line).
@MainActor
public protocol HealthDataProviding: AnyObject {

    /// `HKHealthStore.isHealthDataAvailable()`. False on devices without Health,
    /// which is the one case where even the "Connect Health" card is wrong.
    var isHealthDataAvailable: Bool { get }

    /// Daily activity for `[start, end)`.
    ///
    /// Returns one sample per day in range, zero-filled where HealthKit has
    /// nothing. Never throws: HealthKit refuses reads by returning empty results
    /// rather than errors — it does not disclose read authorization — so an empty
    /// answer and a denied answer are indistinguishable by design, and both mean
    /// the same thing here (no insights).
    func dailyActivity(from start: Date, to end: Date, calendar: Calendar) async -> [HealthDaySample]

    /// Starts `HKObserverQuery` + background delivery so new activity data
    /// re-runs the engine (SPEC §4 "Refresh"). A no-op for fixtures.
    func startObserving(onChange: @escaping @MainActor () -> Void)

    func stopObserving()
}

// MARK: - Fixture provider

/// The provider tests, previews, and Gate 3's synthetic fixtures use.
///
/// It is the reason `tallyTests/Health/` can assert on exact card numbers with no
/// HealthKit at all: the engine's input is a list of days, so a fixture *is* a
/// list of days.
@MainActor
public final class FixtureHealthDataProvider: HealthDataProviding {

    public var isHealthDataAvailable: Bool

    /// Keyed by start-of-day so overlapping windows cannot double-count.
    public private(set) var samplesByDay: [Date: HealthDaySample]

    /// Incremented by every `dailyActivity` call — lets a test assert that the
    /// section recomputes on foreground rather than caching.
    public private(set) var readCount = 0

    private var onChange: (@MainActor () -> Void)?

    public init(samples: [HealthDaySample] = [], isHealthDataAvailable: Bool = true, calendar: Calendar = .current) {
        self.isHealthDataAvailable = isHealthDataAvailable
        var byDay: [Date: HealthDaySample] = [:]
        for sample in samples {
            byDay[calendar.startOfDay(for: sample.day)] = sample
        }
        self.samplesByDay = byDay
    }

    public func replace(samples: [HealthDaySample], calendar: Calendar = .current) {
        var byDay: [Date: HealthDaySample] = [:]
        for sample in samples {
            byDay[calendar.startOfDay(for: sample.day)] = sample
        }
        samplesByDay = byDay
    }

    /// The revocation case (Gate 3): the store is still there, it just answers
    /// with nothing.
    public func revokeReads() {
        samplesByDay = [:]
        onChange?()
    }

    public func dailyActivity(from start: Date, to end: Date, calendar: Calendar) async -> [HealthDaySample] {
        readCount += 1
        var result: [HealthDaySample] = []
        var cursor = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while cursor < last {
            result.append(samplesByDay[cursor] ?? HealthDaySample(day: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return result
    }

    public func startObserving(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    public func stopObserving() {
        onChange = nil
    }

    /// Pretends HealthKit delivered new data.
    public func simulateHealthKitUpdate() {
        onChange?()
    }
}

// MARK: - Fixture builders

public extension FixtureHealthDataProvider {

    /// A run of days with the same numbers — the base every fixture starts from.
    static func days(
        endingAt end: Date,
        count: Int,
        exerciseMinutes: Double,
        stepCount: Double = 6_000,
        activeEnergyKilocalories: Double = 400,
        workoutCount: Int = 0,
        calendar: Calendar = .current
    ) -> [HealthDaySample] {
        let lastDay = calendar.startOfDay(for: end)
        return (0..<count).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: lastDay) else { return nil }
            return HealthDaySample(
                day: day,
                exerciseMinutes: exerciseMinutes,
                activeEnergyKilocalories: activeEnergyKilocalories,
                stepCount: stepCount,
                workoutCount: workoutCount
            )
        }
    }
}
