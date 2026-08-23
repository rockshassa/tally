import Foundation
import Observation
import SwiftData
import TallyKit

/// Reads the event log, derives the Sessions, and hands the Trends tab one
/// immutable `TrendsData` (SPEC §4).
///
/// Nothing here is persisted and nothing is cached across reloads — SPEC §1's
/// "derive, don't store" applies to charts exactly as it does to points and
/// streaks, so switching the segmented control just recomputes.
@MainActor
@Observable
public final class TrendsModel {

    // MARK: State

    public private(set) var data: TrendsData = .empty()

    /// Rises after the first load, so the empty state does not flash on launch.
    public private(set) var hasLoaded = false

    public var granularity: TrendsGranularity {
        didSet {
            guard granularity != oldValue else { return }
            reload(asOf: lastLoadedAt)
        }
    }

    // MARK: Dependencies

    private let modelContext: ModelContext
    private let deriver: SessionDeriver
    private let scoring: ScoringEngine
    private let calendar: Calendar
    private var lastLoadedAt: Date

    /// The trailing window the venue breakdown, heatmap, and Session stats read.
    /// 90 days is the same horizon SPEC §2 uses for "frequented" venues.
    private let windowDays = 90

    public init(
        modelContext: ModelContext,
        granularity: TrendsGranularity = .day,
        deriver: SessionDeriver = SessionDeriver(),
        scoring: ScoringEngine = ScoringEngine(),
        calendar: Calendar = .current,
        now: Date = Date()
    ) {
        self.modelContext = modelContext
        self.granularity = granularity
        self.deriver = deriver
        self.scoring = scoring
        self.calendar = calendar
        self.lastLoadedAt = now
    }

    // MARK: Loading

    public func reload(asOf now: Date = Date()) {
        lastLoadedAt = now

        let events = (try? EventStore.snapshots(in: modelContext)) ?? []
        let venues = ((try? EventStore.venues(in: modelContext)) ?? []).byID
        let sessions = (try? deriver.derive(in: modelContext, venueExits: RadarService.shared.venueExits())) ?? []

        data = Self.assemble(
            events: events,
            sessions: sessions,
            venues: venues,
            granularity: granularity,
            scoring: scoring,
            calendar: calendar,
            windowDays: windowDays,
            // SPEC §4: off means the layer is never computed, not merely hidden.
            recoveryEnabled: RecoveryContext.isEnabled(),
            now: now
        )
        hasLoaded = true
    }

    // MARK: Assembly

    /// Pure, so a fixture can drive the whole screen without a `ModelContext`
    /// (PLAN Gate 2: "renders on an empty store, a single event, and a 90-day
    /// fixture; the 7-day average matches fixture math exactly").
    nonisolated public static func assemble(
        events: [DrinkEventSnapshot],
        sessions: [DerivedSession],
        venues: [UUID: VenueSnapshot],
        granularity: TrendsGranularity,
        scoring: ScoringEngine = ScoringEngine(),
        calendar: Calendar = .current,
        windowDays: Int = 90,
        recoveryEnabled: Bool = false,
        now: Date = Date()
    ) -> TrendsData {

        guard !events.isEmpty else { return .empty(granularity: granularity) }

        let days = scoring.dailyStats(for: events, asOf: now)
        let maps = TrendsMath.dailyMaps(days: days, calendar: calendar)
        let today = calendar.startOfDay(for: now)

        // The trailing window every "where and when" chart reads.
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: today) ?? today
        let windowEvents = events.filter { $0.timestamp >= windowStart }
        let windowSessions = sessions.filter { $0.endedAt >= windowStart }

        let streaks = scoring.streaks(days: days)

        let weekAlcoholic = TrendsMath.trailingSum(
            endingOn: today, days: 7, dailyCounts: maps.alcoholic, calendar: calendar
        )
        let weekNonAlcoholic = TrendsMath.trailingSum(
            endingOn: today, days: 7, dailyCounts: maps.nonAlcoholic, calendar: calendar
        )
        let priorWeekEnd = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        let lastWeekAlcoholic = TrendsMath.trailingSum(
            endingOn: priorWeekEnd, days: 7, dailyCounts: maps.alcoholic, calendar: calendar
        )

        let venueRows = TrendsMath.venueRows(
            events: windowEvents,
            sessions: windowSessions,
            venues: venues
        )

        // Counted over every venue, not just the five the breakdown had room
        // for — "most frequent venue" (SPEC §4) is about Sessions, and a quiet
        // regular can out-Session a loud one-nighter.
        var sessionsPerVenue: [UUID: Int] = [:]
        for session in windowSessions {
            guard let id = session.venueID, venues[id] != nil else { continue }
            sessionsPerVenue[id, default: 0] += 1
        }
        let topVenue = sessionsPerVenue
            .max { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value < rhs.value }
                return lhs.key.uuidString > rhs.key.uuidString
            }
            .flatMap { venues[$0.key] }

        let tiles = TrendsTileSet(
            thisWeekAlcoholic: weekAlcoholic,
            lastWeekAlcoholic: lastWeekAlcoholic,
            sevenDayAverage: Double(weekAlcoholic) / 7.0,
            previousSevenDayAverage: Double(lastWeekAlcoholic) / 7.0,
            weekRatio: TrendsMath.ratio(alcoholic: weekAlcoholic, nonAlcoholic: weekNonAlcoholic),
            ratioGoal: scoring.configuration.ratioGoal,
            currentStreak: streaks.current,
            currentDryStreak: streaks.currentDry,
            longestDryStreak: streaks.longestDry,
            topVenueName: topVenue.map { $0.name.isEmpty ? "Unnamed place" : $0.name },
            topVenueSessionCount: topVenue.map { sessionsPerVenue[$0.id] ?? 0 } ?? 0
        )

        return TrendsData(
            granularity: granularity,
            buckets: TrendsMath.buckets(
                granularity: granularity,
                dailyAlcoholic: maps.alcoholic,
                dailyNonAlcoholic: maps.nonAlcoholic,
                now: now,
                calendar: calendar
            ),
            ratioPoints: TrendsMath.ratioPoints(
                weeks: 12,
                dailyAlcoholic: maps.alcoholic,
                dailyNonAlcoholic: maps.nonAlcoholic,
                now: now,
                calendar: calendar
            ),
            venueRows: venueRows,
            heatmap: TrendsMath.heatmap(events: windowEvents, calendar: calendar),
            sessionStats: TrendsMath.sessionStats(
                sessions: windowSessions,
                venues: venues,
                windowDays: windowDays
            ),
            tiles: tiles,
            suppression: recoveryEnabled
                ? TrendsMath.suppression(events: events, now: now)
                : nil,
            eventCount: events.count
        )
    }
}
