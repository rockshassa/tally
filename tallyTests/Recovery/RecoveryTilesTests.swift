import Foundation
import Testing
import TallyKit
@testable import tally

/// The arithmetic behind SPEC §4's weekly tile — *"modeled suppression-hours,
/// this week vs last"* — asserted as pure math.
///
/// `TrendsMath.suppressionHours` is a value-in/value-out integral over
/// `FibrinolysisModel`'s curve, so everything worth promising about the tile can
/// be checked without a view, a store, or a clock: a week with nothing in it is
/// zero, one drink is an area that can be derived by hand from the model's
/// documented parameters, and the two weekly windows partition the timeline
/// without inventing or losing an hour.
///
/// **Target setup (integrator):** as with `tallyTests/Health/` and
/// `tallyTests/Sync/`, these files are written against the `tallyTests` bundle
/// and nothing in them changes when it is wired.
@Suite("Recovery — modeled suppression tile")
struct RecoveryTilesTests {

    // MARK: - Fixture scaffolding

    private let model = FibrinolysisModel()

    /// A fixed instant, so nothing here depends on when the suite runs.
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 86_400
    private static let week: TimeInterval = 7 * 86_400

    private func drink(at date: Date, type: DrinkType = .alcoholic) -> DrinkEventSnapshot {
        DrinkEventSnapshot(type: type, timestamp: date)
    }

    // MARK: - The known area

    /// Hours a single paced drink spends above baseline, derived from the model's
    /// own configuration rather than from the model's output.
    ///
    /// The pulse rises as a smoothstep from `onsetDelay` to `peakDelay` and then
    /// decays exponentially, so the two baseline crossings are:
    ///
    /// * **rising** — `unitPulse · (3s² − 2s³) = baselineThreshold`, solved for
    ///   the smoothstep parameter `s`, then mapped back onto the onset→peak span;
    /// * **falling** — `unitPulse · 2^(−x / halfLife) = baselineThreshold`, i.e.
    ///   `x = halfLife · log₂(unitPulse / baselineThreshold)` after the peak.
    ///
    /// With the shipping parameters that is 1.93 h to 17.90 h after the drink —
    /// call it sixteen hours above baseline for one drink, which is the whole
    /// reason SPEC §4 talks about the morning after.
    private var singleDrinkHours: Double {
        let configuration = model.configuration
        let target = configuration.baselineThreshold / configuration.unitPulse

        // Bisection on the smoothstep, which is monotonic on 0…1.
        var low = 0.0
        var high = 1.0
        for _ in 0..<80 {
            let mid = (low + high) / 2
            if 3 * mid * mid - 2 * mid * mid * mid < target { low = mid } else { high = mid }
        }
        let rising = configuration.onsetDelay
            + (low + high) / 2 * (configuration.peakDelay - configuration.onsetDelay)

        let falling = configuration.peakDelay
            + configuration.decayHalfLife * log2(configuration.unitPulse / configuration.baselineThreshold)

        return (falling - rising) / Self.hour
    }

    // MARK: - Nothing in, nothing out

    @Test("A window with no drinks in or before it is zero hours")
    func emptyWindowIsZero() {
        #expect(
            TrendsMath.suppressionHours(
                events: [],
                from: now.addingTimeInterval(-Self.week),
                to: now
            ) == 0
        )
    }

    @Test("Non-alcoholic drinks contribute no modeled suppression")
    func nonAlcoholicIsInert() {
        let events = [
            drink(at: now.addingTimeInterval(-6 * Self.hour), type: .nonAlcoholic),
            drink(at: now.addingTimeInterval(-4 * Self.hour), type: .nonAlcoholic)
        ]
        #expect(
            TrendsMath.suppressionHours(
                events: events,
                from: now.addingTimeInterval(-Self.week),
                to: now
            ) == 0
        )
    }

    @Test("An inverted or zero-length window is zero, not a negative area")
    func degenerateWindow() {
        let events = [drink(at: now.addingTimeInterval(-4 * Self.hour))]
        #expect(TrendsMath.suppressionHours(events: events, from: now, to: now) == 0)
        #expect(
            TrendsMath.suppressionHours(
                events: events,
                from: now,
                to: now.addingTimeInterval(-Self.day)
            ) == 0
        )
    }

    // MARK: - One drink, known area

    @Test("One drink inside a generous window integrates to the derived area")
    func singleDrinkArea() {
        let logged = now.addingTimeInterval(-30 * Self.hour)
        let hours = TrendsMath.suppressionHours(
            events: [drink(at: logged)],
            from: logged.addingTimeInterval(-Self.hour),
            to: logged.addingTimeInterval(30 * Self.hour)
        )

        #expect(abs(hours - singleDrinkHours) < 0.1)
        // The same number, written out — a regression on the shipping parameters
        // as well as on the integrator.
        #expect(abs(hours - 15.97) < 0.15)
    }

    @Test("A finer sampling step lands on the same area")
    func stepIndependence() {
        let logged = now.addingTimeInterval(-30 * Self.hour)
        let events = [drink(at: logged)]
        let start = logged.addingTimeInterval(-Self.hour)
        let end = logged.addingTimeInterval(30 * Self.hour)

        let coarse = TrendsMath.suppressionHours(events: events, from: start, to: end, step: 15 * 60)
        let fine = TrendsMath.suppressionHours(events: events, from: start, to: end, step: 60)
        #expect(abs(coarse - fine) < 0.05)
    }

    /// Duration, not peak height: the tile answers "until when", so a bigger
    /// night reads as a longer one. (It is deliberately *not* a compression
    /// ranking — spreading the same drinks out pushes the tail later, and this
    /// number is honest about that. The compression penalty shows up in the
    /// curve's height, which is the Tally screen's card, not this tile.)
    @Test("More drinks model more hours above baseline")
    func doseLengthensTheWindow() {
        let logged = now.addingTimeInterval(-3 * Self.day)
        let start = logged.addingTimeInterval(-Self.hour)
        let end = logged.addingTimeInterval(72 * Self.hour)

        let one = TrendsMath.suppressionHours(events: [drink(at: logged)], from: start, to: end)
        let three = TrendsMath.suppressionHours(
            events: (0..<3).map { drink(at: logged.addingTimeInterval(Double($0) * 40 * 60)) },
            from: start,
            to: end
        )

        #expect(three > one)
    }

    // MARK: - Week windowing

    @Test("A drink ten days back lands in last week's window, not this week's")
    func windowSeparation() {
        let suppression = TrendsMath.suppression(
            events: [drink(at: now.addingTimeInterval(-10 * Self.day))],
            now: now
        )

        #expect(suppression.thisWeekHours == 0)
        #expect(suppression.lastWeekHours > 0)
        #expect(suppression.deltaHours < 0)
    }

    @Test("A drink just before the window still suppresses inside it")
    func leadInCrossesTheBoundary() {
        // Two hours before this week's window opens: the pulse peaks four hours
        // after the drink, so almost all of its area belongs to *this* week.
        let logged = now.addingTimeInterval(-Self.week - 2 * Self.hour)
        let suppression = TrendsMath.suppression(events: [drink(at: logged)], now: now)

        #expect(suppression.thisWeekHours > 0)
        #expect(suppression.lastWeekHours > 0)
        #expect(suppression.thisWeekHours > suppression.lastWeekHours)

        // Nothing double-counted and nothing lost: consecutive windows partition
        // the drink's above-baseline stretch.
        let total = suppression.thisWeekHours + suppression.lastWeekHours
        #expect(abs(total - singleDrinkHours) < 0.1)
    }

    @Test("Drinks older than the lead-in are dropped from both windows")
    func staleDrinksAreDropped() {
        let suppression = TrendsMath.suppression(
            events: [drink(at: now.addingTimeInterval(-30 * Self.day))],
            now: now
        )

        #expect(suppression.thisWeekHours == 0)
        #expect(suppression.lastWeekHours == 0)
        #expect(suppression.deltaHours == 0)
    }

    @Test("A drink in each week reads as no change")
    func matchedWeeksAreFlat() {
        let events = [
            drink(at: now.addingTimeInterval(-2 * Self.day)),
            drink(at: now.addingTimeInterval(-9 * Self.day))
        ]
        let suppression = TrendsMath.suppression(events: events, now: now)

        #expect(abs(suppression.thisWeekHours - singleDrinkHours) < 0.1)
        #expect(abs(suppression.lastWeekHours - singleDrinkHours) < 0.1)
        #expect(abs(suppression.deltaHours) < 0.2)
    }

    // MARK: - Off means absent, not zero

    @Test("Assembly omits the tile's data entirely when recovery context is off")
    func offMeansNoData() {
        let events = [drink(at: now.addingTimeInterval(-2 * Self.day))]

        let off = TrendsModel.assemble(
            events: events,
            sessions: [],
            venues: [:],
            granularity: .day,
            recoveryEnabled: false,
            now: now
        )
        #expect(off.suppression == nil)

        let on = TrendsModel.assemble(
            events: events,
            sessions: [],
            venues: [:],
            granularity: .day,
            recoveryEnabled: true,
            now: now
        )
        #expect(on.suppression != nil)
        #expect((on.suppression?.thisWeekHours ?? 0) > 0)
    }
}
