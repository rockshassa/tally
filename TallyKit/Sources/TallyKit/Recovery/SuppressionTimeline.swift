import Foundation

/// The complete modeled progression of one episode — first drink, rise, peak,
/// decline, and the return to modeled baseline — in the single value the Tally
/// card, the expanded chart, Session detail, and the widget all draw.
///
/// Pure and view-free on purpose: every string, every locale decision, and
/// every drawing decision belongs to the view. What lives here is the shape and
/// the milestones, so the app and the widget can never disagree about them for
/// the same events and the same clock.
///
/// The display scale is baseline-relative: `display = max(0, raw − baselineThreshold)`.
/// Zero on it means "the model is inside its baseline band", which gives the
/// curve an honest endpoint without touching the raw model. With the default
/// configuration the raw ceiling of 100 reads as 97 above baseline.
public struct SuppressionTimeline: Hashable, Sendable {

    // MARK: Parts

    /// One plotted instant. `raw` is the untouched model index; `display` is
    /// the baseline-relative value the chart shows.
    public struct Sample: Hashable, Sendable {

        public let date: Date
        public let raw: Double
        public let display: Double

        public init(date: Date, raw: Double, display: Double) {
            self.date = date
            self.raw = raw
            self.display = display
        }
    }

    /// One contributing drink, for the ticks along the bottom of the chart.
    public struct DrinkMarker: Identifiable, Hashable, Sendable {

        public let id: UUID
        public let date: Date

        /// The drink's compression weight — 1 when paced, higher inside a
        /// compressed stretch. Views may use it to weight a tick.
        public let weight: Double

        public init(id: UUID, date: Date, weight: Double) {
            self.id = id
            self.date = date
            self.weight = weight
        }
    }

    /// The episode's overall maximum, past or future.
    public struct Peak: Hashable, Sendable {

        public let date: Date
        public let raw: Double
        public let display: Double

        /// When the curve is pinned at the model's ceiling for more than one
        /// sample, the last instant of that capped stretch; `date` is its first
        /// occurrence. `nil` for an ordinary, single-instant peak.
        public let plateauEnd: Date?

        public init(date: Date, raw: Double, display: Double, plateauEnd: Date? = nil) {
            self.date = date
            self.raw = raw
            self.display = display
            self.plateauEnd = plateauEnd
        }

        public var isPlateau: Bool { plateauEnd != nil }
    }

    /// Where the curve is going *right now*, read from its local slope — not
    /// from the episode's overall peak, because a multi-drink episode has
    /// several rises.
    public enum State: String, Hashable, Sendable, CaseIterable {

        /// At baseline with a rise still to come — the model's absorption
        /// delay, which must never read as completed recovery.
        case riseAhead

        /// Above baseline and climbing.
        case rising

        /// Above baseline and decaying.
        case easing

        /// At or below the model's baseline threshold, with nothing pending.
        case atBaseline
    }

    // MARK: Fields

    public let episode: SuppressionEpisode

    /// The clock this timeline was built for.
    public let now: Date

    /// The full plotted range: the first drink to the modeled return, with a
    /// little padding on each side so both endpoints are legible.
    public let range: ClosedRange<Date>

    /// Oldest first, spanning `range`, with every milestone present exactly.
    /// Decimation for drawing is the view's job, never this type's.
    public let samples: [Sample]

    public let drinkMarkers: [DrinkMarker]

    public let peak: Peak

    /// The sample at `now`, or `nil` when the clock has moved past the plotted
    /// range (a completed episode still inside its retention window).
    public let nowValue: Sample?

    public let state: State

    /// The modeled return is known and already behind `now`.
    public let isComplete: Bool

    /// False when the caller's fetched history may not reach far enough back to
    /// prove this episode's first drink really is its first — the view should
    /// then say "Available history" instead of claiming a first drink.
    public let isHistoryComplete: Bool

    /// When a completed episode stops being shown: the later of 24 h after its
    /// last drink and 24 h after its modeled return.
    public let retainedUntil: Date

    public init(
        episode: SuppressionEpisode,
        now: Date,
        range: ClosedRange<Date>,
        samples: [Sample],
        drinkMarkers: [DrinkMarker],
        peak: Peak,
        nowValue: Sample?,
        state: State,
        isComplete: Bool,
        isHistoryComplete: Bool,
        retainedUntil: Date
    ) {
        self.episode = episode
        self.now = now
        self.range = range
        self.samples = samples
        self.drinkMarkers = drinkMarkers
        self.peak = peak
        self.nowValue = nowValue
        self.state = state
        self.isComplete = isComplete
        self.isHistoryComplete = isHistoryComplete
        self.retainedUntil = retainedUntil
    }

    /// The modeled return, as the episode reported it.
    public var baselineReturn: SuppressionEndpoint { episode.baselineReturn }

    /// The first drink of the displayed episode.
    public var start: Date { episode.start }

    // MARK: Tuning constants

    /// Padding at each end of the range: a proportion of the episode's span,
    /// bounded so a short episode still shows its endpoints and a week-long one
    /// does not grow half a day of empty chart.
    public static let paddingFraction = 0.05
    public static let minimumPadding: TimeInterval = 15 * 60
    public static let maximumPadding: TimeInterval = 60 * 60

    /// Sampling resolution by plotted span.
    public static let fineStep: TimeInterval = 15 * 60
    public static let mediumStep: TimeInterval = 30 * 60
    public static let coarseStep: TimeInterval = 60 * 60
    public static let fineSpan: TimeInterval = 48 * 3600
    public static let mediumSpan: TimeInterval = 5 * 86_400

    /// How close to the ceiling counts as capped.
    public static let plateauTolerance = 0.01

    /// The half-window the current state's slope is read over.
    public static let slopeWindow: TimeInterval = 5 * 60

    // MARK: Builders

    /// The timeline to show on the Tally screen: the active episode, else the
    /// most recently completed one while it is still retained, else `nil`.
    ///
    /// - Parameter historyStart: the earliest timestamp the caller actually
    ///   fetched; `nil` means the whole log. Drives `isHistoryComplete`.
    ///
    /// Empty logs, non-alcoholic-only logs, and logs whose only alcoholic
    /// entries are future-dated all return `nil`.
    public static func make(
        now: Date,
        events: [DrinkEventSnapshot],
        model: FibrinolysisModel = FibrinolysisModel(),
        historyStart: Date? = nil
    ) -> SuppressionTimeline? {
        let drinks = SuppressionEpisodes.contributingDrinks(events, now: now, model: model)
        let episodes = SuppressionEpisodes.partition(drinks: drinks, now: now, model: model)
        guard let episode = episodes.last else { return nil }
        guard !episode.isComplete(asOf: now) || now < episode.retainedUntil else { return nil }
        return build(episode: episode, drinks: drinks, now: now, model: model, historyStart: historyStart)
    }

    /// The episode containing a specific logged drink, regardless of retention
    /// — Session detail opening a recovery episode that finished long ago.
    public static func make(
        now: Date,
        events: [DrinkEventSnapshot],
        model: FibrinolysisModel = FibrinolysisModel(),
        containing eventID: UUID,
        historyStart: Date? = nil
    ) -> SuppressionTimeline? {
        let drinks = SuppressionEpisodes.contributingDrinks(events, now: now, model: model)
        let episodes = SuppressionEpisodes.partition(drinks: drinks, now: now, model: model)
        guard let episode = episodes.first(where: { $0.contains(eventID) }) else { return nil }
        return build(episode: episode, drinks: drinks, now: now, model: model, historyStart: historyStart)
    }

    // MARK: Derivation

    static func build(
        episode: SuppressionEpisode,
        drinks: [WeightedDrink],
        now: Date,
        model: FibrinolysisModel,
        historyStart: Date?
    ) -> SuppressionTimeline {
        let configuration = model.configuration
        let threshold = configuration.baselineThreshold
        let context = SuppressionEpisodes.context(for: episode, in: drinks, model: model)
        let pruneHorizon = SuppressionEpisodes.pruneHorizon(for: model)

        // The plotted end: the modeled crossing, or — when the endpoint is
        // unavailable — the far edge of what the walk was allowed to compute,
        // so the chart never implies an endpoint it could not find.
        let lastWalked = episode.lastDrink
            .addingTimeInterval(configuration.peakDelay + SuppressionEpisodes.walkCap)
        let endAnchor = episode.baselineReturn.date ?? lastWalked

        let span = max(endAnchor.timeIntervalSince(episode.start), 0)
        let pad = min(max(span * paddingFraction, minimumPadding), maximumPadding)
        let range = episode.start.addingTimeInterval(-pad)...endAnchor.addingTimeInterval(pad)

        let width = range.upperBound.timeIntervalSince(range.lowerBound)
        let step = width <= fineSpan ? fineStep : (width <= mediumSpan ? mediumStep : coarseStep)

        // Anchors first, so a milestone always wins the second it shares with a
        // grid point: the start, every pulse transition, now, the crossing, and
        // both ends of the range.
        var anchors: [Date] = [range.lowerBound, range.upperBound, episode.start]
        for drink in episode.drinks {
            anchors.append(drink.timestamp)
            anchors.append(drink.timestamp.addingTimeInterval(configuration.onsetDelay))
            anchors.append(drink.timestamp.addingTimeInterval(configuration.peakDelay))
        }
        if let crossing = episode.baselineReturn.date { anchors.append(crossing) }
        if range.contains(now) { anchors.append(now) }

        var seen = Set<Int>()
        var dates: [Date] = []
        func add(_ date: Date) {
            guard range.contains(date) else { return }
            guard seen.insert(secondKey(date)).inserted else { return }
            dates.append(date)
        }
        anchors.forEach(add)
        var cursor = range.lowerBound
        while cursor <= range.upperBound {
            add(cursor)
            cursor = cursor.addingTimeInterval(step)
        }
        dates.sort()

        // Sampling sweeps the window forward instead of summing the whole
        // retained context at every instant: only drinks inside `pruneHorizon`
        // behind a sample can move it by more than the tolerance, and drinks
        // after it contribute nothing at all. A months-long episode therefore
        // costs its sample count times a few dozen drinks, not times the log.
        func window(upTo date: Date) -> ArraySlice<WeightedDrink> {
            let horizon = date.addingTimeInterval(-pruneHorizon)
            let low = context.firstIndex { $0.timestamp >= horizon } ?? context.endIndex
            let high = context.firstIndex { $0.timestamp > date } ?? context.endIndex
            return context[low..<max(low, high)]
        }
        func sample(_ date: Date) -> Sample {
            let raw = model.index(at: date, weighted: window(upTo: date))
            return Sample(date: date, raw: raw, display: max(0, raw - threshold))
        }

        var samples: [Sample] = []
        samples.reserveCapacity(dates.count)
        var low = context.startIndex
        var high = context.startIndex
        for date in dates {
            let horizon = date.addingTimeInterval(-pruneHorizon)
            while low < context.endIndex, context[low].timestamp < horizon { low += 1 }
            while high < context.endIndex, context[high].timestamp <= date { high += 1 }
            let raw = model.index(at: date, weighted: context[low..<high])
            samples.append(Sample(date: date, raw: raw, display: max(0, raw - threshold)))
        }

        // The overall peak, past or future. A capped stretch reports its first
        // occurrence and its extent; anything else is refined off the grid and
        // then inserted, so the marked peak is a real sample.
        let plateauFloor = configuration.ceiling - plateauTolerance
        let capped = samples.indices.filter { samples[$0].raw >= plateauFloor }
        let peak: Peak
        if capped.count > 1, let first = capped.first, let last = capped.last {
            peak = Peak(
                date: samples[first].date,
                raw: samples[first].raw,
                display: samples[first].display,
                plateauEnd: samples[last].date
            )
        } else {
            let top = samples.indices.max { samples[$0].raw < samples[$1].raw }
            let refined = top.map {
                refinedPeak(
                    around: $0,
                    in: samples,
                    // The search never leaves the highest sample's neighbours,
                    // so the window of its upper neighbour covers it.
                    context: window(upTo: samples[min($0 + 1, samples.endIndex - 1)].date),
                    model: model
                )
            } ?? sample(range.lowerBound)
            if seen.insert(secondKey(refined.date)).inserted {
                let slot = samples.firstIndex { $0.date > refined.date } ?? samples.endIndex
                samples.insert(refined, at: slot)
            }
            peak = Peak(date: refined.date, raw: refined.raw, display: refined.display, plateauEnd: nil)
        }

        // `now` is an anchor whenever it is in range, so this finds it exactly;
        // the fallback only guards a pathological range.
        let nowValue: Sample? = range.contains(now)
            ? (samples.first { abs($0.date.timeIntervalSince(now)) < 1 } ?? sample(now))
            : nil

        return SuppressionTimeline(
            episode: episode,
            now: now,
            range: range,
            samples: samples,
            drinkMarkers: episode.drinks.map {
                DrinkMarker(id: $0.id, date: $0.timestamp, weight: $0.weight)
            },
            peak: peak,
            nowValue: nowValue,
            state: state(
                at: now,
                samples: samples,
                context: window(upTo: now.addingTimeInterval(slopeWindow)),
                model: model
            ),
            isComplete: episode.isComplete(asOf: now),
            isHistoryComplete: historyStart.map {
                episode.start.timeIntervalSince($0) >= pruneHorizon
            } ?? true,
            retainedUntil: episode.retainedUntil
        )
    }

    /// Ternary search between the grid neighbours of the highest sample: the
    /// sum of smooth pulses has no cliffs, so a local refine puts the marker on
    /// the actual maximum instead of on whichever grid tick came closest —
    /// which matters most for the long episodes that sample hourly.
    private static func refinedPeak(
        around index: Int,
        in samples: [Sample],
        context: ArraySlice<WeightedDrink>,
        model: FibrinolysisModel
    ) -> Sample {
        let threshold = model.configuration.baselineThreshold
        var low = samples[max(index - 1, samples.startIndex)].date
        var high = samples[min(index + 1, samples.endIndex - 1)].date
        while high.timeIntervalSince(low) > 30 {
            let third = high.timeIntervalSince(low) / 3
            let a = low.addingTimeInterval(third)
            let b = high.addingTimeInterval(-third)
            if model.index(at: a, weighted: context) < model.index(at: b, weighted: context) {
                low = a
            } else {
                high = b
            }
        }
        let candidate = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
        let raw = model.index(at: candidate, weighted: context)
        guard raw > samples[index].raw else { return samples[index] }
        return Sample(date: candidate, raw: raw, display: max(0, raw - threshold))
    }

    /// Rising or easing from the local slope; at baseline, `riseAhead` whenever
    /// anything is still coming — the opening absorption delay must not read as
    /// a finished recovery.
    private static func state(
        at now: Date,
        samples: [Sample],
        context: ArraySlice<WeightedDrink>,
        model: FibrinolysisModel
    ) -> State {
        let threshold = model.configuration.baselineThreshold
        let current = model.index(at: now, weighted: context)
        let slope = model.index(at: now.addingTimeInterval(slopeWindow), weighted: context)
            - model.index(at: now.addingTimeInterval(-slopeWindow), weighted: context)

        guard current <= threshold else { return slope > 0 ? .rising : .easing }
        let riseAhead = slope > 0 || samples.contains { $0.date > now && $0.raw > current }
        return riseAhead ? .riseAhead : .atBaseline
    }

    /// Whole-second identity for de-duplication: two plotted instants inside
    /// the same second are the same instant as far as a chart is concerned.
    private static func secondKey(_ date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate.rounded())
    }
}
