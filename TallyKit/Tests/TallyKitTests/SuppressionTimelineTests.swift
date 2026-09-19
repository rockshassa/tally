import Foundation
import Testing
@testable import TallyKit

/// The shared timeline (design: "Fibrinolytic suppression: first drink to
/// baseline"). Everything here is pure, so every promise the chart makes —
/// episode boundaries, the endpoint, the display scale — is directly testable
/// without a view or a clock.
@Suite("Suppression timeline")
struct SuppressionTimelineTests {

    private let model = FibrinolysisModel()
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ hours: Double) -> Date { t0.addingTimeInterval(hours * 3600) }

    private func drink(_ index: Int, _ hours: Double, _ type: DrinkType = .alcoholic) -> DrinkEventSnapshot {
        DrinkEventSnapshot(id: Fixture.uuid(index), type: type, timestamp: at(hours), source: .app)
    }

    // MARK: Nothing to show

    @Test("Empty, non-alcoholic, and future-only logs produce no timeline")
    func nothingToShow() {
        #expect(SuppressionTimeline.make(now: at(1), events: [], model: model) == nil)
        #expect(SuppressionTimeline.make(now: at(1), events: [drink(1, 0, .nonAlcoholic)], model: model) == nil)
        #expect(SuppressionTimeline.make(now: at(1), events: [drink(1, 5)], model: model) == nil)
    }

    @Test("Future-dated drinks neither start nor extend an episode")
    func futureDrinksIgnored() throws {
        let events = [drink(1, 0), drink(2, 100)]
        let timeline = try #require(SuppressionTimeline.make(now: at(1), events: events, model: model))
        #expect(timeline.drinkMarkers.map(\.id) == [Fixture.uuid(1)])
        #expect(timeline.episode.lastDrink == at(0))
    }

    // MARK: The first drink

    @Test("Immediately after the first drink: delay, rise, peak, and a projected return to zero")
    func firstDrink() throws {
        let events = [drink(1, 0)]
        let now = at(0.1)
        let timeline = try #require(SuppressionTimeline.make(now: now, events: events, model: model))

        #expect(timeline.episode.start == at(0))
        #expect(timeline.state == .riseAhead)
        #expect(timeline.isComplete == false)

        // The pulse peaks at the configured delay, and the display value is the
        // raw index minus the baseline band.
        #expect(abs(timeline.peak.date.timeIntervalSince(at(4))) < 60)
        #expect(abs(timeline.peak.raw - model.configuration.unitPulse) < 0.01)
        #expect(abs(timeline.peak.display - (model.configuration.unitPulse - 3)) < 0.01)
        #expect(timeline.peak.plateauEnd == nil)

        // The return is ahead of the clock, and it is a plotted sample that
        // actually reads zero — endpoint text and curve agree.
        guard case .projected(let crossing) = timeline.baselineReturn else {
            Issue.record("expected a projected return, got \(timeline.baselineReturn)")
            return
        }
        #expect(crossing > now)
        #expect(abs(crossing.timeIntervalSince(at(17.9))) < 20 * 60)
        let atCrossing = try #require(timeline.samples.first { abs($0.date.timeIntervalSince(crossing)) < 1 })
        #expect(atCrossing.display == 0)
        #expect(atCrossing.raw <= model.configuration.baselineThreshold)

        // The range runs from the first drink to a little past the return, and
        // the last sample is exactly its end, resting on zero.
        #expect(timeline.range.lowerBound < at(0))
        #expect(timeline.range.upperBound > crossing)
        #expect(timeline.samples.last?.date == timeline.range.upperBound)
        #expect(timeline.samples.last?.display == 0)
        #expect(timeline.samples.first?.date == timeline.range.lowerBound)

        // Now is in range and is its own sample.
        let nowValue = try #require(timeline.nowValue)
        #expect(abs(nowValue.date.timeIntervalSince(now)) < 1)
        #expect(nowValue.raw == 0)
    }

    @Test("Padding stays inside the 15–60 minute bounds")
    func padding() throws {
        let timeline = try #require(SuppressionTimeline.make(now: at(0.1), events: [drink(1, 0)], model: model))
        let pad = at(0).timeIntervalSince(timeline.range.lowerBound)
        #expect(pad >= SuppressionTimeline.minimumPadding)
        #expect(pad <= SuppressionTimeline.maximumPadding)
        let crossing = try #require(timeline.baselineReturn.date)
        #expect(abs(timeline.range.upperBound.timeIntervalSince(crossing) - pad) < 1)
    }

    @Test("The display scale is the raw index minus the baseline band, floored at zero")
    func displayScale() throws {
        let events = (0..<4).map { drink($0, Double($0) * 0.5) }
        let timeline = try #require(SuppressionTimeline.make(now: at(2), events: events, model: model))
        for sample in timeline.samples {
            #expect(sample.display == max(0, sample.raw - model.configuration.baselineThreshold))
        }
    }

    // MARK: The next morning

    @Test("The next morning still shows the same first drink and the peak already passed")
    func nextMorning() throws {
        let events = [drink(1, 0), drink(2, 1), drink(3, 2)]
        let timeline = try #require(SuppressionTimeline.make(now: at(10), events: events, model: model))

        #expect(timeline.episode.start == at(0))
        #expect(timeline.drinkMarkers.count == 3)
        #expect(timeline.peak.date < at(10))
        #expect(timeline.state == .easing)

        let nowValue = try #require(timeline.nowValue)
        #expect(abs(nowValue.raw - model.suppressionIndex(at: at(10), events: events)) < 1e-9)
        #expect(nowValue.raw > model.configuration.baselineThreshold)
    }

    // MARK: Episode boundaries

    @Test("A drink before the return extends the same episode")
    func drinkBeforeReturnExtends() {
        let events = [drink(1, 0), drink(2, 10)]
        let episodes = SuppressionEpisodes.partition(events: events, now: at(11), model: model)
        #expect(episodes.count == 1)
        #expect(episodes[0].start == at(0))
        #expect(episodes[0].lastDrink == at(10))
    }

    @Test("A drink after the return starts a new episode")
    func drinkAfterReturnStartsNewEpisode() throws {
        let events = [drink(1, 0), drink(2, 24)]
        let episodes = SuppressionEpisodes.partition(events: events, now: at(25), model: model)
        #expect(episodes.count == 2)
        #expect(episodes[0].start == at(0))
        #expect(episodes[1].start == at(24))

        // The first episode's return really is behind the second's first drink.
        let first = try #require(episodes[0].baselineReturn.date)
        #expect(first <= at(24))
        #expect(episodes[0].baselineReturn.hasReturned)

        // And the card shows the new episode, not the old one.
        let timeline = try #require(SuppressionTimeline.make(now: at(25), events: events, model: model))
        #expect(timeline.episode.start == at(24))
    }

    @Test("Continuous drinking across days stays one episode past 66 hours")
    func longEpisode() throws {
        let events = (0...6).map { drink($0, Double($0) * 12) }
        let episodes = SuppressionEpisodes.partition(events: events, now: at(72.5), model: model)
        #expect(episodes.count == 1)

        let timeline = try #require(SuppressionTimeline.make(now: at(72.5), events: events, model: model))
        #expect(timeline.episode.start == at(0))
        #expect(timeline.drinkMarkers.count == 7)
        #expect(timeline.range.upperBound.timeIntervalSince(timeline.range.lowerBound) > 66 * 3600)
        // Coarser sampling for a long episode, milestones still exact.
        for marker in timeline.drinkMarkers {
            let peakInstant = marker.date.addingTimeInterval(model.configuration.peakDelay)
            #expect(timeline.samples.contains { abs($0.date.timeIntervalSince(peakInstant)) < 1 })
        }
        #expect(timeline.samples.contains { abs($0.date.timeIntervalSince(at(0))) < 1 })
    }

    @Test("A temporary dip before a pending rise does not complete the episode")
    func temporaryDip() throws {
        // The second drink lands while the first pulse is barely above the
        // threshold, so the curve dips under it during the absorption delay and
        // climbs back out.
        let events = [drink(1, 0), drink(2, 17.5)]
        #expect(model.suppressionIndex(at: at(17.5), events: events) > model.configuration.baselineThreshold)
        #expect(model.suppressionIndex(at: at(18.2), events: events) < model.configuration.baselineThreshold)

        let episodes = SuppressionEpisodes.partition(events: events, now: at(18.2), model: model)
        #expect(episodes.count == 1)

        let timeline = try #require(SuppressionTimeline.make(now: at(18.2), events: events, model: model))
        #expect(timeline.isComplete == false)
        #expect(timeline.state == .riseAhead)
        // The return is found after the *last* drink's pulse peak, never in the dip.
        let crossing = try #require(timeline.baselineReturn.date)
        #expect(crossing > at(21.5))
    }

    // MARK: Peaks

    @Test("A capped episode reports the first ceiling instant and the plateau's end")
    func cappedPlateau() throws {
        let events = (0..<20).map { drink($0, Double($0) * 0.2) }
        let timeline = try #require(SuppressionTimeline.make(now: at(4), events: events, model: model))

        #expect(abs(timeline.peak.raw - model.configuration.ceiling) < 0.01)
        #expect(abs(timeline.peak.display - 97) < 0.01)
        let plateauEnd = try #require(timeline.peak.plateauEnd)
        #expect(plateauEnd > timeline.peak.date)
        #expect(timeline.peak.isPlateau)
        // The first occurrence, not the middle of the capped stretch.
        let earlier = timeline.samples.filter { $0.date < timeline.peak.date }
        #expect(earlier.allSatisfy { $0.raw < model.configuration.ceiling - 0.01 })
    }

    @Test("Several local peaks, one overall peak — kept even after it passes")
    func multipleLocalPeaks() throws {
        // A compressed cluster, then one paced drink half a day later.
        let cluster = (0..<4).map { drink($0, Double($0) * 0.3) }
        let events = cluster + [drink(10, 14)]
        let timeline = try #require(SuppressionTimeline.make(now: at(20), events: events, model: model))

        // The overall peak belongs to the cluster and is already behind us.
        #expect(timeline.peak.date < at(6))
        #expect(timeline.peak.date > at(3))
        #expect(timeline.state == .easing)

        // The second rise is a genuine local maximum, and lower.
        let second = try #require(
            timeline.samples
                .filter { $0.date > at(16) && $0.date < at(20) }
                .max { $0.raw < $1.raw }
        )
        #expect(second.raw < timeline.peak.raw)
        #expect(second.raw > model.suppressionIndex(at: at(14), events: events))
    }

    // MARK: History and endpoints

    @Test("History completeness follows the prune horizon")
    func historyCompleteness() throws {
        let events = [drink(1, 0)]
        let complete = try #require(
            SuppressionTimeline.make(now: at(1), events: events, model: model, historyStart: at(-200))
        )
        #expect(complete.isHistoryComplete)

        let partial = try #require(
            SuppressionTimeline.make(now: at(1), events: events, model: model, historyStart: at(-10))
        )
        #expect(partial.isHistoryComplete == false)

        let unbounded = try #require(SuppressionTimeline.make(now: at(1), events: events, model: model))
        #expect(unbounded.isHistoryComplete)
    }

    @Test("A curve that never crosses reports an unavailable endpoint, never a fabricated zero")
    func unavailableEndpoint() throws {
        // An absurd half-life: the pulse is still above baseline two weeks out.
        let slow = FibrinolysisModel(configuration: .init(decayHalfLife: 100 * 86_400))
        let events = [drink(1, 0)]
        let episodes = SuppressionEpisodes.partition(events: events, now: at(1), model: slow)
        #expect(episodes.count == 1)
        #expect(episodes[0].baselineReturn == .unavailable)
        #expect(episodes[0].isComplete(asOf: at(10_000)) == false)

        let timeline = try #require(SuppressionTimeline.make(now: at(1), events: events, model: slow))
        #expect(timeline.baselineReturn == .unavailable)
        #expect(timeline.isComplete == false)
        // Honest tail: the curve does not pretend to reach zero.
        #expect((timeline.samples.last?.display ?? 0) > 0)
        #expect(timeline.range.upperBound > at(14 * 24))
    }

    // MARK: Retention

    @Test("A completed episode is retained for 24 h past the later of its last drink and its return")
    func retention() throws {
        let events = [drink(1, 0)]
        let episode = try #require(SuppressionEpisodes.partition(events: events, now: at(20), model: model).last)
        let crossing = try #require(episode.baselineReturn.date)
        #expect(episode.isComplete(asOf: at(20)))
        #expect(episode.retainedUntil == crossing.addingTimeInterval(24 * 3600))

        let retained = try #require(SuppressionTimeline.make(now: at(40), events: events, model: model))
        #expect(retained.isComplete)
        #expect(retained.nowValue == nil)          // the clock has left the plotted range
        #expect(retained.state == .atBaseline)
        #expect(retained.retainedUntil == episode.retainedUntil)

        #expect(SuppressionTimeline.make(now: at(43), events: events, model: model) == nil)
    }

    @Test("A new episode replaces a retained one immediately")
    func newEpisodeReplacesRetained() throws {
        let events = [drink(1, 0), drink(2, 30)]
        let timeline = try #require(SuppressionTimeline.make(now: at(30.1), events: events, model: model))
        #expect(timeline.episode.start == at(30))
        #expect(timeline.drinkMarkers.count == 1)
    }

    // MARK: Session detail

    @Test("containing: opens the episode that holds a given drink, retention or not")
    func containingEpisode() throws {
        let events = [drink(1, 0), drink(2, 0.5), drink(3, 120)]
        let now = at(130)

        let current = try #require(SuppressionTimeline.make(now: now, events: events, model: model))
        #expect(current.episode.start == at(120))

        let old = try #require(
            SuppressionTimeline.make(now: now, events: events, model: model, containing: Fixture.uuid(2))
        )
        #expect(old.episode.start == at(0))
        #expect(old.drinkMarkers.map(\.id) == [Fixture.uuid(1), Fixture.uuid(2)])
        #expect(old.isComplete)
        #expect(old.nowValue == nil)
        // A display boundary: the later episode's drink is not in this curve.
        #expect(old.range.upperBound < at(120))

        #expect(
            SuppressionTimeline.make(now: now, events: events, model: model, containing: Fixture.uuid(99)) == nil
        )
    }

    // MARK: Raw model preservation

    @Test("Precomputed weights reproduce the original quadratic model to 1e-9")
    func weightedMatchesReference() {
        // Forty drinks over eighteen hours, deterministic but irregular.
        var offsets: [Double] = []
        var x = 0.0
        for index in 0..<40 {
            x += 0.1 + Double((index * 37) % 11) / 20
            offsets.append(x)
        }
        let events = offsets.enumerated().map { drink($0.offset, $0.element) }
        let weighted = model.weightedDrinks(events)
        #expect(weighted.count == 40)

        for step in 0...400 {
            let date = at(Double(step) * 0.15)
            let reference = Self.referenceIndex(at: date, events: events, model: model)
            #expect(abs(model.suppressionIndex(at: date, events: events) - reference) < 1e-9)
            #expect(abs(model.suppressionIndex(at: date, weighted: weighted) - reference) < 1e-9)
        }

        let byEvents = model.curve(from: at(0), to: at(30), events: events)
        let byWeights = model.curve(from: at(0), to: at(30), weighted: weighted)
        #expect(byEvents.count == byWeights.count)
        for (lhs, rhs) in zip(byEvents, byWeights) {
            #expect(lhs.date == rhs.date)
            #expect(abs(lhs.index - rhs.index) < 1e-9)
        }
    }

    @Test("Compression weights match the trailing-window count, ties included")
    func weights() {
        let events = [drink(1, 0), drink(2, 0), drink(3, 1), drink(4, 2.5)]
        let weighted = model.weightedDrinks(events)
        let exponent = model.configuration.compressionExponent - 1
        #expect(weighted.map(\.timestamp) == [at(0), at(0), at(1), at(2.5)])
        #expect(abs(weighted[0].weight - pow(2, exponent)) < 1e-12)   // the tie counts both
        #expect(abs(weighted[1].weight - pow(2, exponent)) < 1e-12)
        #expect(abs(weighted[2].weight - pow(3, exponent)) < 1e-12)
        #expect(abs(weighted[3].weight - pow(2, exponent)) < 1e-12)   // only the 1 h drink is inside 2 h
    }

    /// The pre-refactor formula, transcribed: every weight recomputed against
    /// every other drink at every instant.
    private static func referenceIndex(
        at date: Date,
        events: [DrinkEventSnapshot],
        model: FibrinolysisModel
    ) -> Double {
        let configuration = model.configuration
        let drinks = events.filter { $0.type == .alcoholic }
        let total = drinks.reduce(0.0) { sum, drink in
            let elapsed = date.timeIntervalSince(drink.timestamp)
            guard elapsed > configuration.onsetDelay else { return sum }
            let windowStart = drink.timestamp.addingTimeInterval(-configuration.compressionWindow)
            let n = drinks.count { $0.timestamp > windowStart && $0.timestamp <= drink.timestamp }
            let weight = pow(Double(max(1, n)), configuration.compressionExponent - 1)
            let magnitude = configuration.unitPulse * weight
            if elapsed < configuration.peakDelay {
                let t = (elapsed - configuration.onsetDelay) / (configuration.peakDelay - configuration.onsetDelay)
                return sum + magnitude * t * t * (3 - 2 * t)
            }
            return sum + magnitude * pow(0.5, (elapsed - configuration.peakDelay) / configuration.decayHalfLife)
        }
        return min(configuration.ceiling, total)
    }

    // MARK: Editing the log

    @Test("Deleting and re-timing drinks re-derives the boundaries")
    func edits() throws {
        let events = [drink(1, 0), drink(2, 10), drink(3, 20)]
        #expect(SuppressionEpisodes.partition(events: events, now: at(21), model: model).count == 1)

        // Remove the bridge and the single episode splits in two.
        let split = [events[0], events[2]]
        #expect(SuppressionEpisodes.partition(events: split, now: at(21), model: model).count == 2)

        // Move the last drink earlier and they merge again — same event count.
        let merged = [events[0], events[1], drink(3, 15)]
        #expect(SuppressionEpisodes.partition(events: merged, now: at(21), model: model).count == 1)

        // Correcting the bridge to a non-alcoholic drink splits them too.
        let corrected = [events[0], drink(2, 10, .nonAlcoholic), events[2]]
        #expect(SuppressionEpisodes.partition(events: corrected, now: at(21), model: model).count == 2)

        // Undo back to one drink.
        let undone = [events[0]]
        let timeline = try #require(SuppressionTimeline.make(now: at(1), events: undone, model: model))
        #expect(timeline.drinkMarkers.count == 1)
    }

    // MARK: Cost

    @Test("A log of a few thousand events builds in one pass")
    func largeLog() throws {
        // Ten drinks a night, every third night, two hundred nights: 2000
        // events, and a two-night gap is long enough to return to baseline.
        var events: [DrinkEventSnapshot] = []
        var index = 0
        for night in 0..<200 {
            for pour in 0..<10 {
                events.append(drink(index, Double(night) * 72 + Double(pour) * 0.4))
                index += 1
            }
        }
        #expect(events.count == 2000)

        let now = at(199 * 72 + 5)
        let episodes = SuppressionEpisodes.partition(events: events, now: now, model: model)
        #expect(episodes.count == 200)
        let timeline = try #require(SuppressionTimeline.make(now: now, events: events, model: model))
        #expect(timeline.episode.start == at(199 * 72))
        #expect(timeline.drinkMarkers.count == 10)
        #expect(timeline.samples.count < 400)
    }

    @Test("Nightly drinking never returns to baseline, so it is one long episode")
    func continuousDrinking() throws {
        // Three drinks a night for a fortnight: the curve never comes back
        // down, so this is one episode that outruns the prune horizon.
        var events: [DrinkEventSnapshot] = []
        var index = 0
        for night in 0..<14 {
            for pour in 0..<3 {
                events.append(drink(index, Double(night) * 24 + Double(pour) * 0.5))
                index += 1
            }
        }
        let now = at(13 * 24 + 2)
        let episodes = SuppressionEpisodes.partition(events: events, now: now, model: model)
        #expect(episodes.count == 1)

        let timeline = try #require(SuppressionTimeline.make(now: now, events: events, model: model))
        // The origin survives a prune horizon four times shorter than the episode.
        #expect(timeline.episode.start == at(0))
        #expect(timeline.drinkMarkers.count == 42)
        #expect(timeline.samples.first?.raw == 0)
        #expect(timeline.samples.contains { abs($0.date.timeIntervalSince(at(0))) < 1 })
        #expect(timeline.samples.last?.display == 0)
    }
}
