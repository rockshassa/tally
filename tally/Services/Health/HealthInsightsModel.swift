import Foundation
import Observation
import SwiftData
import TallyKit

/// What the Trends insights slot should be showing right now.
///
/// The four states of SPEC §4, and no fifth one. There is deliberately no
/// "loading" case: a refresh that has not finished yet keeps the previous state
/// on screen, because the slot sits at the top of Trends and a spinner appearing
/// and vanishing on every foreground would be worse than a card that updates a
/// beat late.
nonisolated public enum HealthInsightsState: Hashable, Sendable {

    /// No HealthKit on this device. Not even the offer makes sense.
    case unavailable

    /// The "Connect Health" card (SPEC §9's just-in-time ask).
    ///
    /// `hasAsked` is `true` when the read sheet has already been shown and
    /// HealthKit is still returning nothing — the revoked case, and also the "no
    /// activity data on this device" case, which are indistinguishable by design
    /// and want the same offer.
    case connect(hasAsked: Bool)

    /// Connected and readable, but nothing cleared SPEC §4's guardrails. Renders
    /// as `EmptyView`: *"Absence is fine."*
    case silent

    case insights([HealthInsight])
}

/// Drives `HealthInsightsSection`: reads the log, reads HealthKit on demand, runs
/// the pure engine, and hands the result to the weekly notification.
///
/// **Nothing here is stored.** The samples live inside `refresh(...)` and are
/// gone when it returns; the `HealthInsight` values live in memory for as long as
/// the view does. No SwiftData model, no CloudKit record, no file (SPEC §10).
@MainActor
@Observable
public final class HealthInsightsModel {

    // MARK: Dependencies

    private let provider: any HealthDataProviding
    private let permissions: any PermissionsService
    private let settings: TallySettings
    private let scheduler: ActivityInsightScheduler?
    private let calendar: Calendar

    // MARK: State

    public private(set) var state: HealthInsightsState = .unavailable

    /// The last report, kept for the notification path and for debugging why the
    /// section is silent.
    public private(set) var report: HealthInsightReport = .empty

    private var isRefreshing = false
    private var isObserving = false

    // MARK: Init

    /// - Parameters:
    ///   - provider: `HealthKitDataProvider()` in the app,
    ///     `FixtureHealthDataProvider` in tests and previews.
    ///   - schedulesNotifications: `false` computes insights without ever
    ///     notifying — what previews and the fixture tests want.
    ///
    /// Every dependency defaults to `nil` and is resolved in the body rather
    /// than in the parameter list: a default argument is evaluated in the
    /// *caller's* isolation, and these singletons are main-actor bound.
    public init(
        provider: (any HealthDataProviding)? = nil,
        permissions: (any PermissionsService)? = nil,
        settings: TallySettings? = nil,
        scheduler: ActivityInsightScheduler? = nil,
        schedulesNotifications: Bool = true,
        calendar: Calendar = .current
    ) {
        self.provider = provider ?? HealthKitDataProvider()
        self.permissions = permissions ?? LivePermissionsService()
        self.settings = settings ?? .shared
        self.scheduler = schedulesNotifications ? (scheduler ?? .shared) : nil
        self.calendar = calendar
        self.state = self.provider.isHealthDataAvailable ? .connect(hasAsked: false) : .unavailable
    }

    // MARK: - Configuration

    /// The engine configuration implied by Settings — the one conversion point
    /// between SPEC §9's threshold row and SPEC §4's analysis.
    public var engineConfiguration: CorrelationEngine.Configuration {
        var configuration = CorrelationEngine.Configuration.default
        configuration.morningAfterThreshold = settings.morningAfterThreshold
        configuration.calendar = calendar
        return configuration
    }

    // MARK: - Refresh

    /// Recomputes everything: log → Sessions, HealthKit → daily samples, both →
    /// insights. Called on appear, on foreground, and whenever `HKObserverQuery`
    /// says new data arrived.
    ///
    /// Re-entrant-safe and cheap to over-call; overlapping calls collapse to one.
    public func refresh(context: ModelContext, now: Date = Date()) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard provider.isHealthDataAvailable else {
            state = .unavailable
            report = .empty
            return
        }

        let hasAsked = permissions.healthAuthorization().readRequested

        guard
            let events = try? EventStore.snapshots(in: context),
            let materialized = try? EventStore.materializedSessions(in: context)
        else {
            state = .connect(hasAsked: hasAsked)
            return
        }

        let configuration = engineConfiguration
        let windowStart = calendar.date(
            byAdding: .day,
            value: -(configuration.windowDays + 1),
            to: calendar.startOfDay(for: now)
        ) ?? calendar.startOfDay(for: now)

        let activity = await provider.dailyActivity(from: windowStart, to: now, calendar: calendar)

        let sessions = SessionDeriver().derive(events: events, materialized: materialized)
        let engine = CorrelationEngine(configuration: configuration)
        let report = engine.report(sessions: sessions, events: events, activity: activity, asOf: now)

        self.report = report
        self.state = Self.state(for: report, hasAsked: hasAsked)

        // SPEC §5: at most one Activity insight a week. The scheduler owns every
        // other gate — toggle, authorization, quiet hours, and the cap itself.
        if case .insights = state {
            await scheduler?.submit(report, now: now)
        }
    }

    /// The state mapping, pulled out as a pure function so PLAN Gate 3's
    /// revocation case is assertable without a view.
    ///
    /// The revocation rule: HealthKit answers a denied read with an empty result
    /// and never says why, so "we asked, and there is nothing readable" is the
    /// only signal there is. It maps back to the Connect card — every insight
    /// surface disappears, and nothing else in the app changes (SPEC §4, §10).
    public static func state(for report: HealthInsightReport, hasAsked: Bool) -> HealthInsightsState {
        guard report.evidence.hasReadableActivity else { return .connect(hasAsked: hasAsked) }
        return report.isEmpty ? .silent : .insights(report.insights)
    }

    // MARK: - Permission

    /// The "Connect Health" tap (SPEC §9: HealthKit read, primed just in time).
    ///
    /// Returns after the sheet closes; the caller refreshes, and whether the user
    /// granted anything shows up as data appearing or not — HealthKit will not
    /// answer the question directly.
    public func connectHealth() async {
        await permissions.requestHealthActivityRead()
    }

    /// What the card offers once the sheet has already been shown. iOS presents
    /// each read sheet once, so re-asking would do nothing visible; Settings is
    /// the only place a revoked read can come back.
    public func openSystemSettings() {
        permissions.openSystemSettings()
    }

    // MARK: - Freshness

    /// Starts `HKObserverQuery` + background delivery (SPEC §4 "Refresh").
    ///
    /// Idempotent, and deliberately deferred until a refresh has proved there is
    /// something readable: registering background delivery for a store that
    /// answers with nothing would ask iOS to wake the app for data it is not
    /// allowed to see. The section calls this after every refresh, so it starts
    /// the moment the user connects Health and never before.
    public func startObserving(onChange: @escaping @MainActor () -> Void) {
        guard !isObserving,
              provider.isHealthDataAvailable,
              report.evidence.hasReadableActivity
        else { return }
        isObserving = true
        provider.startObserving(onChange: onChange)
    }

    public func stopObserving() {
        guard isObserving else { return }
        isObserving = false
        provider.stopObserving()
    }
}
