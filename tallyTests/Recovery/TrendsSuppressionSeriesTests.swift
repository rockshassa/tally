import Foundation
import TallyKit
import Testing
@testable import tally

/// SPEC §4's suppression curve on every Trends timeframe, and the Tally card
/// that no longer retires between nights.
@Suite("Suppression on every timeframe")
struct TrendsSuppressionSeriesTests {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 86_400

    private func night(endingAt end: Date, drinks: Int = 4) -> [DrinkEventSnapshot] {
        (0..<drinks).map {
            DrinkEventSnapshot(type: .alcoholic, timestamp: end.addingTimeInterval(TimeInterval(-3600 * $0)))
        }
    }

    // MARK: - Trends series

    @Test("A night inside the window shows up above baseline, at its own time")
    func nightShowsUp() throws {
        let night = night(endingAt: now.addingTimeInterval(-5 * day))
        let series = TrendsMath.suppressionSeries(
            events: night,
            range: now.addingTimeInterval(-14 * day)...now,
            now: now
        )
        #expect(series.peak > 0)
        let top = try #require(series.points.max { $0.display < $1.display })
        #expect(top.date > now.addingTimeInterval(-6 * day))
        #expect(top.date < now.addingTimeInterval(-4 * day))
    }

    @Test("A dry window is flat at baseline")
    func dryWindow() {
        let series = TrendsMath.suppressionSeries(
            events: [DrinkEventSnapshot(type: .nonAlcoholic, timestamp: now.addingTimeInterval(-day))],
            range: now.addingTimeInterval(-14 * day)...now,
            now: now
        )
        #expect(series.peak == 0)
    }

    @Test("A year stays within the point budget and keeps every night's peak height")
    func yearKeepsPeaks() {
        let nights = (1...12).flatMap { night(endingAt: now.addingTimeInterval(-Double($0) * 30 * day)) }
        let range = now.addingTimeInterval(-365 * day)...now

        let thinned = TrendsMath.suppressionSeries(events: nights, range: range, now: now)
        let full = TrendsMath.suppressionSeries(events: nights, range: range, now: now, limit: .max)

        #expect(thinned.points.count <= TrendsMath.suppressionSeriesLimit)
        // Max-thinning, not stride-thinning: the tallest point survives exactly.
        #expect(abs(thinned.peak - full.peak) < 0.000_1)
    }

    @Test("A drink just before the window still lifts the start of it")
    func leadIn() {
        let lateNight = night(endingAt: now.addingTimeInterval(-14 * day - 3600), drinks: 6)
        let series = TrendsMath.suppressionSeries(
            events: lateNight,
            range: now.addingTimeInterval(-14 * day)...now,
            now: now
        )
        #expect((series.points.first?.display ?? 0) > 0 || series.peak > 0)
    }

    @Test("Future-dated drinks are not modeled")
    func futureIgnored() {
        let series = TrendsMath.suppressionSeries(
            events: night(endingAt: now.addingTimeInterval(2 * day)),
            range: now.addingTimeInterval(-14 * day)...now.addingTimeInterval(3 * day),
            now: now
        )
        #expect(series.peak == 0)
    }

    @Test("Off means not computed")
    func offIsNil() {
        let data = TrendsModel.assemble(
            events: night(endingAt: now.addingTimeInterval(-day)),
            sessions: [],
            venues: [:],
            granularity: .week,
            recoveryEnabled: false,
            now: now
        )
        #expect(data.suppressionSeries == nil)
    }

    @Test("Every timeframe gets a series spanning the drinks chart", arguments: TrendsGranularity.allCases)
    func everyTimeframe(granularity: TrendsGranularity) throws {
        let data = TrendsModel.assemble(
            events: night(endingAt: now.addingTimeInterval(-day)),
            sessions: [],
            venues: [:],
            granularity: granularity,
            recoveryEnabled: true,
            now: now
        )
        let series = try #require(data.suppressionSeries)
        let first = try #require(data.buckets.first)
        #expect(series.range.lowerBound == first.start)
        #expect(series.range.contains(now))
        #expect(series.peak > 0)
    }

    // MARK: - Tally card

    @Test("The card's timeline outlives retention; the widget's does not")
    func latestOutlivesRetention() throws {
        let events = night(endingAt: now.addingTimeInterval(-10 * day))

        #expect(SuppressionTimeline.make(now: now, events: events) == nil)

        let latest = try #require(SuppressionTimeline.makeLatest(now: now, events: events))
        #expect(latest.isComplete)
        #expect(latest.start < now.addingTimeInterval(-10 * day))
    }

    @Test("Nothing alcoholic ever logged: no card")
    func noHistoryNoCard() {
        #expect(SuppressionTimeline.makeLatest(now: now, events: []) == nil)
    }
}
