import Foundation
import TallyKit
import Testing
@testable import tally

/// The drawing arithmetic behind the suppression chart, and Session detail's
/// door into the same episode.
///
/// `SuppressionChartGeometry` and `SessionRecoveryTimeline` are pure for the
/// same reason the copy is: the promises worth keeping — a vertical scale that
/// does not move when the clock does, ticks that merge instead of piling up,
/// and an episode that outlives the Session that opened it — are all value-in,
/// value-out, and none of them needs a view to be checked.

// MARK: - Fixtures

private enum Fixture {

    static let model = FibrinolysisModel()

    /// A fixed instant, so nothing here depends on when the suite runs.
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func at(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }

    static func drink(_ hours: Double, id: UUID = UUID(), type: DrinkType = .alcoholic) -> DrinkEventSnapshot {
        DrinkEventSnapshot(id: id, type: type, timestamp: at(hours), source: .app)
    }

    static func marker(_ hours: Double, id: UUID = UUID()) -> SuppressionTimeline.DrinkMarker {
        SuppressionTimeline.DrinkMarker(id: id, date: at(hours), weight: 1)
    }

    static func sample(_ hours: Double, _ display: Double) -> SuppressionTimeline.Sample {
        SuppressionTimeline.Sample(date: at(hours), raw: display + 3, display: display)
    }

    static func timeline(_ events: [DrinkEventSnapshot], now: Date) -> SuppressionTimeline? {
        SuppressionTimeline.make(now: now, events: events, model: model)
    }

    /// A timeline assembled by hand, for the cases the model cannot be coaxed
    /// into producing — a peak small enough to need the domain's floor, above
    /// all.
    static func synthetic(peakDisplay: Double) -> SuppressionTimeline {
        let episode = SuppressionEpisode(
            start: at(0),
            drinks: [WeightedDrink(id: UUID(), timestamp: at(0), weight: 1)],
            lastDrink: at(0),
            baselineReturn: .projected(at(10))
        )
        return SuppressionTimeline(
            episode: episode,
            now: at(2),
            range: at(0)...at(10),
            samples: [sample(0, 0), sample(4, peakDisplay), sample(10, 0)],
            drinkMarkers: [marker(0)],
            peak: SuppressionTimeline.Peak(date: at(4), raw: peakDisplay + 3, display: peakDisplay),
            nowValue: sample(2, peakDisplay / 2),
            state: .rising,
            isComplete: false,
            isHistoryComplete: true,
            retainedUntil: at(34)
        )
    }
}

// MARK: - Vertical scale

@Suite("Suppression chart scale")
struct SuppressionChartScaleTests {

    @Test("The domain starts at zero and clears the episode's peak")
    func domain() {
        let domain = SuppressionChartGeometry.yDomain(for: Fixture.synthetic(peakDisplay: 40))

        #expect(domain.lowerBound == 0)
        #expect(domain.upperBound == 40 * SuppressionChartGeometry.headroom)
    }

    @Test("A very small episode is not magnified to fill the frame")
    func floor() {
        let domain = SuppressionChartGeometry.yDomain(for: Fixture.synthetic(peakDisplay: 1))

        #expect(domain.upperBound == SuppressionChartGeometry.minimumTop)
    }

    @Test("The clock advancing does not rescale the chart")
    func fixedAcrossTheClock() throws {
        // The same episode, seen from the middle of the night and from the next
        // afternoon. The peak is the episode's own, so the scale cannot move.
        let events = [Fixture.drink(0), Fixture.drink(1), Fixture.drink(2)]
        let early = try #require(Fixture.timeline(events, now: Fixture.at(2.5)))
        let later = try #require(Fixture.timeline(events, now: Fixture.at(14)))

        let a = SuppressionChartGeometry.yDomain(for: early).upperBound
        let b = SuppressionChartGeometry.yDomain(for: later).upperBound

        #expect(abs(a - b) < 1e-9)
        #expect(early.range == later.range)
    }
}

// MARK: - Solid past, dashed future

@Suite("Suppression chart split")
struct SuppressionChartSplitTests {

    private let samples = (0...10).map { Fixture.sample(Double($0), Double($0)) }

    @Test("The two halves meet at now instead of leaving a gap")
    func meetsAtNow() {
        let (past, future) = SuppressionChartGeometry.split(samples, at: Fixture.at(4))

        #expect(past.last?.date == Fixture.at(4))
        #expect(future.first?.date == Fixture.at(4))
        #expect(past.count + future.count == samples.count + 1)
    }

    @Test("A finished episode is all past; nothing is drawn dashed")
    func completedCurve() {
        let (past, future) = SuppressionChartGeometry.split(samples, at: Fixture.at(40))

        #expect(past.count == samples.count)
        #expect(future.isEmpty)
    }
}

// MARK: - Drink ticks

@Suite("Suppression drink ticks")
struct SuppressionTickTests {

    private let range = Fixture.at(0)...Fixture.at(24)

    @Test("Drinks closer than 3 % of the range become one counted tick")
    func merges() {
        // 3 % of 24 h is ~43 min, so the first three merge and the fourth does not.
        let markers = [
            Fixture.marker(0),
            Fixture.marker(1.0 / 6),   // +10 min
            Fixture.marker(1.0 / 3),   // +20 min
            Fixture.marker(3)
        ]
        let ticks = SuppressionChartGeometry.ticks(for: markers, in: range)

        #expect(ticks.map(\.count) == [3, 1])
        #expect(ticks[0].date == Fixture.at(1.0 / 6))    // the cluster's midpoint
        #expect(ticks[1].date == Fixture.at(3))
    }

    @Test("An even cadence does not chain itself into one tick for the night")
    func doesNotChain() {
        // Every 30 min for four hours: each gap is under the window, but the
        // cluster is measured from its own first drink, so they do not all
        // collapse into one.
        let markers = (0..<8).map { Fixture.marker(Double($0) * 0.5) }
        let ticks = SuppressionChartGeometry.ticks(for: markers, in: range)

        #expect(ticks.count > 1)
        #expect(ticks.reduce(0) { $0 + $1.count } == markers.count)
    }

    @Test("Every drink is accounted for exactly once")
    func conserved() {
        let markers = (0..<20).map { Fixture.marker(Double($0) * 0.1) }
        let ticks = SuppressionChartGeometry.ticks(for: markers, in: range)

        #expect(ticks.reduce(0) { $0 + $1.count } == 20)
        #expect(ticks.allSatisfy { range.contains($0.date) })
    }

    @Test("The Session that opened the chart gets the brighter ticks")
    func highlighting() {
        let mine = UUID()
        let markers = [Fixture.marker(0), Fixture.marker(6, id: mine), Fixture.marker(12)]
        let ticks = SuppressionChartGeometry.ticks(for: markers, in: range, highlighting: [mine])

        #expect(ticks.map(\.isHighlighted) == [false, true, false])
    }

    @Test("Nothing logged, nothing drawn")
    func empty() {
        #expect(SuppressionChartGeometry.ticks(for: [], in: range).isEmpty)
    }
}

// MARK: - Anchors and inspection

@Suite("Suppression chart anchors")
struct SuppressionAnchorTests {

    @Test("The accessible stepper walks the episode's milestones, in order")
    func anchors() throws {
        let events = [Fixture.drink(0), Fixture.drink(1), Fixture.drink(8)]
        let timeline = try #require(Fixture.timeline(events, now: Fixture.at(10)))
        let anchors = SuppressionChartGeometry.anchors(for: timeline)

        #expect(anchors.count >= 4)
        #expect(anchors.map(\.date) == anchors.map(\.date).sorted())
        #expect(Set(anchors.map(\.date)).count == anchors.count)
        // Every anchor is a sample the curve actually contains.
        #expect(anchors.allSatisfy { anchor in timeline.samples.contains { $0.date == anchor.date } })

        // The start, the peak, now, and the modeled return are all reachable.
        func reachable(_ date: Date) -> Bool {
            anchors.contains { abs($0.date.timeIntervalSince(date)) <= 15 * 60 }
        }
        let crossing = try #require(timeline.baselineReturn.date)
        #expect(reachable(timeline.start))
        #expect(reachable(timeline.peak.date))
        #expect(reachable(timeline.now))
        #expect(reachable(crossing))
    }

    @Test("An inspected instant reads a value the curve really has")
    func nearestSample() throws {
        let timeline = try #require(Fixture.timeline([Fixture.drink(0)], now: Fixture.at(2)))
        let found = try #require(SuppressionChartGeometry.sample(at: Fixture.at(4), in: timeline))

        #expect(abs(found.date.timeIntervalSince(Fixture.at(4))) <= 15 * 60)
        #expect(found.display == max(0, found.raw - Fixture.model.configuration.baselineThreshold))
    }

    @Test("Decimation thins the drawing without dropping a milestone")
    func decimation() {
        let samples = (0..<400).map { Fixture.sample(Double($0) * 0.25, Double($0 % 7)) }
        let anchors: Set<Date> = [Fixture.at(13.25), Fixture.at(77.75)]
        let drawn = SuppressionChartGeometry.decimated(samples, keeping: anchors, limit: 100)

        #expect(drawn.count <= 110)
        #expect(drawn.first?.date == samples.first?.date)
        #expect(drawn.last?.date == samples.last?.date)
        for anchor in anchors {
            #expect(drawn.contains { $0.date == anchor })
        }
    }

    @Test("A curve that already fits is left exactly as it is")
    func noDecimationNeeded() {
        let samples = (0..<40).map { Fixture.sample(Double($0), Double($0)) }
        #expect(SuppressionChartGeometry.decimated(samples, keeping: []) == samples)
    }
}

// MARK: - Session detail

@Suite("Session recovery timeline")
struct SessionRecoveryTimelineTests {

    private func session(_ events: [DrinkEventSnapshot]) -> DerivedSession {
        let ordered = events.sorted(by: DrinkEventSnapshot.isOrderedBefore)
        return DerivedSession(
            id: ordered.first?.id ?? UUID(),
            startedAt: ordered.first?.timestamp ?? Fixture.at(0),
            endedAt: ordered.last?.timestamp ?? Fixture.at(0),
            closesAt: (ordered.last?.timestamp ?? Fixture.at(0)).addingTimeInterval(3 * 3600),
            venueID: nil,
            events: ordered,
            isMaterialized: false
        )
    }

    @Test("The row appears only with recovery on and something alcoholic logged")
    func availability() {
        let night = session([Fixture.drink(0), Fixture.drink(1)])
        let dry = session([Fixture.drink(0, type: .nonAlcoholic)])

        #expect(SessionRecoveryTimeline.isAvailable(for: night, recoveryEnabled: true))
        #expect(!SessionRecoveryTimeline.isAvailable(for: night, recoveryEnabled: false))
        #expect(!SessionRecoveryTimeline.isAvailable(for: dry, recoveryEnabled: true))
    }

    @Test("The anchor is the Session's earliest alcoholic drink, not its earliest event")
    func anchor() {
        let water = Fixture.drink(-0.5, type: .nonAlcoholic)
        let first = Fixture.drink(0)
        let night = session([water, first, Fixture.drink(1)])

        #expect(SessionRecoveryTimeline.anchorEventID(for: night) == first.id)
        #expect(SessionRecoveryTimeline.highlightedEventIDs(for: night).count == 2)
        #expect(!SessionRecoveryTimeline.highlightedEventIDs(for: night).contains(water.id))
    }

    @Test("Two Sessions inside one episode open the same complete episode")
    func sharedEpisode() throws {
        // Friday night and Saturday night, with Saturday's first drink landing
        // before Friday's modeled return: one episode, two Sessions.
        let friday = [Fixture.drink(0), Fixture.drink(1)]
        let saturday = [Fixture.drink(20), Fixture.drink(21)]
        let events = friday + saturday
        let now = Fixture.at(24)

        let fromFriday = try #require(
            SessionRecoveryTimeline.make(session: session(friday), events: events, now: now)
        )
        let fromSaturday = try #require(
            SessionRecoveryTimeline.make(session: session(saturday), events: events, now: now)
        )

        #expect(fromFriday == fromSaturday)
        #expect(fromFriday.start == Fixture.at(0))
        #expect(fromFriday.drinkMarkers.count == 4)

        // Each screen highlights its own drinks inside that shared episode.
        let highlighted = SessionRecoveryTimeline.highlightedEventIDs(for: session(saturday))
        let ticks = SuppressionChartGeometry.ticks(
            for: fromFriday.drinkMarkers,
            in: fromFriday.range,
            highlighting: highlighted
        )
        #expect(ticks.contains { $0.isHighlighted })
        #expect(ticks.contains { !$0.isHighlighted })
    }

    @Test("A long-finished episode is still openable from History")
    func outlivesRetention() throws {
        let events = [Fixture.drink(0)]
        let now = Fixture.at(24 * 30)

        // The Tally card has long since retired it…
        #expect(Fixture.timeline(events, now: now) == nil)
        // …and Session detail can still open it.
        let timeline = try #require(
            SessionRecoveryTimeline.make(session: session(events), events: events, now: now)
        )
        #expect(timeline.isComplete)
        #expect(timeline.start == Fixture.at(0))
    }

    @Test("A Session with nothing the model can place has no episode to open")
    func noEpisode() {
        let dry = session([Fixture.drink(0, type: .nonAlcoholic)])
        #expect(SessionRecoveryTimeline.make(session: dry, events: dry.events, now: Fixture.at(2)) == nil)
    }
}
