import Foundation
import TallyKit

#if canImport(HealthKit)
import HealthKit
#endif

/// The real reader: `HKStatisticsCollectionQuery` for the three daily quantities,
/// a sample query for workouts, and `HKObserverQuery` + background delivery so
/// new data re-runs the engine (SPEC §4 "Refresh").
///
/// **Read-only, on demand, nothing kept.** Every call queries the local
/// HealthKit store for the window it was asked about and returns values. There is
/// no import step, no mirror table, and nothing written to SwiftData or CloudKit
/// — SPEC §10 is explicit that HealthKit data never enters the app's own store,
/// and the way to guarantee that is to have no code that could.
///
/// **Read authorization is never checked**, because HealthKit does not disclose
/// it: `authorizationStatus(for:)` reports sharing (write) state only, and
/// answering "are you allowed to read this?" would itself leak whether the user
/// has the data. A denied read returns an empty result, exactly like a user with
/// no watch — and both mean the same thing to this feature (SPEC §4: "Absence is
/// fine").
@MainActor
public final class HealthKitDataProvider: HealthDataProviding {

    #if canImport(HealthKit)
    private let healthStore = HKHealthStore()
    private var observerQueries: [HKObserverQuery] = []
    #endif

    private var isObserving = false

    public init() {}

    // MARK: - Availability

    public var isHealthDataAvailable: Bool {
        #if canImport(HealthKit)
        return HKHealthStore.isHealthDataAvailable()
        #else
        return false
        #endif
    }

    // MARK: - Reads

    public func dailyActivity(from start: Date, to end: Date, calendar: Calendar) async -> [HealthDaySample] {
        #if canImport(HealthKit)
        guard isHealthDataAvailable, start < end else { return [] }

        let windowStart = calendar.startOfDay(for: start)
        let windowEnd = calendar.startOfDay(for: end)

        async let exercise = dailySums(
            identifier: .appleExerciseTime,
            unit: .minute(),
            from: windowStart,
            to: windowEnd,
            calendar: calendar
        )
        async let energy = dailySums(
            identifier: .activeEnergyBurned,
            unit: .kilocalorie(),
            from: windowStart,
            to: windowEnd,
            calendar: calendar
        )
        async let steps = dailySums(
            identifier: .stepCount,
            unit: .count(),
            from: windowStart,
            to: windowEnd,
            calendar: calendar
        )
        async let workouts = dailyWorkoutCounts(from: windowStart, to: windowEnd, calendar: calendar)

        let (exerciseByDay, energyByDay, stepsByDay, workoutsByDay) = await (exercise, energy, steps, workouts)

        var result: [HealthDaySample] = []
        var cursor = windowStart
        while cursor < windowEnd {
            result.append(
                HealthDaySample(
                    day: cursor,
                    exerciseMinutes: exerciseByDay[cursor] ?? 0,
                    activeEnergyKilocalories: energyByDay[cursor] ?? 0,
                    stepCount: stepsByDay[cursor] ?? 0,
                    workoutCount: workoutsByDay[cursor] ?? 0
                )
            )
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return result
        #else
        return []
        #endif
    }

    #if canImport(HealthKit)

    /// One `HKStatisticsCollectionQuery` bucketed by day.
    ///
    /// Resolves to zeros rather than throwing on every failure path — a missing
    /// type, a denied read, and a device with no data are all "nothing to
    /// compare", and none of them is worth an error the UI would have to explain.
    private func dailySums(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date,
        calendar: Calendar
    ) async -> [Date: Double] {

        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return [:] }

        return await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
            let query = HKStatisticsCollectionQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum,
                anchorDate: start,
                intervalComponents: DateComponents(day: 1)
            )

            // Resumed exactly once: `initialResultsHandler` fires a single time
            // and no update handler is installed on this query.
            query.initialResultsHandler = { _, collection, _ in
                guard let collection else {
                    continuation.resume(returning: [:])
                    return
                }
                var sums: [Date: Double] = [:]
                collection.enumerateStatistics(from: start, to: end) { statistics, _ in
                    let value = statistics.sumQuantity()?.doubleValue(for: unit) ?? 0
                    sums[calendar.startOfDay(for: statistics.startDate)] = value
                }
                continuation.resume(returning: sums)
            }

            healthStore.execute(query)
        }
    }

    /// Workouts per day. `HKWorkout` has no cumulative statistic, so this counts
    /// samples — the count is all SPEC §4's displacement analysis needs.
    private func dailyWorkoutCounts(from start: Date, to end: Date, calendar: Calendar) async -> [Date: Int] {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate])
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                var counts: [Date: Int] = [:]
                for sample in samples ?? [] {
                    counts[calendar.startOfDay(for: sample.startDate), default: 0] += 1
                }
                continuation.resume(returning: counts)
            }
            healthStore.execute(query)
        }
    }

    #endif

    // MARK: - Freshness

    /// SPEC §4: *"HealthKit background delivery (`HKObserverQuery`) re-runs the
    /// engine as new activity data arrives."*
    ///
    /// The observer carries no data — it is a "something changed" ping, and the
    /// response is a fresh on-demand read. Background delivery is requested at
    /// hourly frequency, which is the finest HealthKit grants for these types and
    /// far finer than a weekly insight needs; if the entitlement is missing the
    /// call fails silently and the feature degrades to foreground-only refresh,
    /// which is the same behaviour with a longer latency.
    public func startObserving(onChange: @escaping @MainActor () -> Void) {
        #if canImport(HealthKit)
        guard isHealthDataAvailable, !isObserving else { return }
        isObserving = true

        for objectType in LivePermissionsService.activityReadTypes {
            guard let sampleType = objectType as? HKSampleType else { continue }

            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, _ in
                // Hop to the main actor before touching anything of ours; the
                // completion handler must be called either way or HealthKit
                // backs off from this app.
                Task { @MainActor in
                    onChange()
                    completionHandler()
                }
            }

            healthStore.execute(query)
            observerQueries.append(query)

            healthStore.enableBackgroundDelivery(for: sampleType, frequency: .hourly) { _, _ in
                // Failure here means no wake-ups, not a broken feature.
            }
        }
        #endif
    }

    /// Tears the observers down and hands back the background-delivery
    /// registration.
    ///
    /// Not called when the Trends tab goes away — background delivery is the
    /// whole point of SPEC §4's refresh story and re-registering it on every tab
    /// switch would be worse than useless. This is for the paths that mean it:
    /// Settings → Erase all data, and disconnecting Health.
    ///
    /// Deregistration is per type rather than `disableAllBackgroundDelivery()`,
    /// which would also revoke registrations this class never made.
    public func stopObserving() {
        #if canImport(HealthKit)
        for query in observerQueries {
            healthStore.stop(query)
        }
        observerQueries.removeAll()

        for objectType in LivePermissionsService.activityReadTypes {
            guard let sampleType = objectType as? HKSampleType else { continue }
            healthStore.disableBackgroundDelivery(for: sampleType) { _, _ in }
        }
        #endif
        isObserving = false
    }
}
