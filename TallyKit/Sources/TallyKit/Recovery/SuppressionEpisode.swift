import Foundation

// MARK: - Endpoint

/// When a drinking-and-recovery episode reaches the model's baseline.
///
/// `.unavailable` is deliberate and load-bearing: a defensive computation limit
/// must produce an explicit "we don't know", never a fabricated zero or an
/// implied claim that the whole timeline is on screen.
public enum SuppressionEndpoint: Hashable, Sendable {

    /// The crossing is still ahead of the clock the episode was built for.
    case projected(Date)

    /// The crossing is already behind that clock.
    case returned(Date)

    /// The search hit `SuppressionEpisodes.walkCap` without bracketing a
    /// downward crossing.
    case unavailable

    /// The crossing instant, when there is one.
    public var date: Date? {
        switch self {
        case .projected(let date), .returned(let date): date
        case .unavailable: nil
        }
    }

    public var isKnown: Bool { date != nil }

    /// True only for a crossing that has already happened.
    public var hasReturned: Bool {
        if case .returned = self { return true }
        return false
    }
}

// MARK: - Episode

/// One drinking-and-recovery interval: the first drink after the previous
/// return to modeled baseline, every drink logged before this episode's own
/// return, and that return.
///
/// An episode is *not* a `DerivedSession`. Drinks on consecutive days belong to
/// one episode whenever the previous one has not returned to baseline, and one
/// episode can span several Sessions (or none of them completely).
public struct SuppressionEpisode: Hashable, Sendable {

    /// The first included drink — the episode's displayed origin.
    public let start: Date

    /// Every included drink, oldest first, with its compression weight.
    public let drinks: [WeightedDrink]

    /// The last included drink.
    public let lastDrink: Date

    /// When the combined raw curve falls to `baselineThreshold` after the last
    /// included drink has passed its pulse peak.
    public let baselineReturn: SuppressionEndpoint

    public init(
        start: Date,
        drinks: [WeightedDrink],
        lastDrink: Date,
        baselineReturn: SuppressionEndpoint
    ) {
        self.start = start
        self.drinks = drinks
        self.lastDrink = lastDrink
        self.baselineReturn = baselineReturn
    }

    /// Complete when the modeled return is known and already behind `now`.
    /// An unavailable endpoint is never complete — not knowing is not finishing.
    public func isComplete(asOf now: Date) -> Bool {
        guard let date = baselineReturn.date else { return false }
        return date <= now
    }

    /// How long a completed episode stays on screen: the later of 24 h after
    /// its last drink and 24 h after its modeled return, so a long recovery can
    /// actually be seen reaching baseline.
    public var retainedUntil: Date {
        let afterLastDrink = lastDrink.addingTimeInterval(SuppressionEpisodes.retention)
        guard let date = baselineReturn.date else { return afterLastDrink }
        return max(afterLastDrink, date.addingTimeInterval(SuppressionEpisodes.retention))
    }

    public func contains(_ eventID: UUID) -> Bool {
        drinks.contains { $0.id == eventID }
    }
}

// MARK: - Partitioning

/// Splits a log into episodes (design: "Choose the full episode").
public enum SuppressionEpisodes {

    // MARK: Tuning constants

    /// How far an episode's curve keeps looking behind itself, with the
    /// default configuration.
    ///
    /// A drink is dropped from the curve context only once its *maximum
    /// possible* contribution — a full-ceiling pulse — has decayed below
    /// `pruneTolerance`. With the default configuration that is
    /// `100 × 0.5^(t / 8 h) < 0.05`, i.e. `t > 4 h + 8 h × log₂(2000) ≈ 91.7 h`;
    /// the horizon rounds that up to a flat 96 h. A configuration that decays
    /// more slowly gets a proportionally longer horizon — see
    /// `pruneHorizon(for:)`, which is what the code actually prunes by.
    ///
    /// The bound is per drink, but the tail is geometric in the decay
    /// half-life, so it stays bounded in aggregate: ten drinks a night, every
    /// night, contribute about 0.03 points in total from beyond the horizon.
    ///
    /// Pruning only ever removes drinks from the *summation*, never from an
    /// episode's `drinks` — the displayed origin cannot be pruned away.
    public static let pruneHorizon: TimeInterval = 96 * 3600

    /// The index-point error the prune horizon is allowed to introduce.
    /// 0.05 points on a 0–100 scale whose baseline band is 3 points wide.
    public static let pruneTolerance: Double = 0.05

    /// `pruneHorizon` for a specific configuration: the age at which a pulse of
    /// the largest possible magnitude has decayed below `pruneTolerance`.
    ///
    /// The default configuration lands under the flat 96 h constant, which then
    /// wins; a slower decay stretches the horizon instead of quietly deleting
    /// a curve that is still well above baseline.
    public static func pruneHorizon(for model: FibrinolysisModel) -> TimeInterval {
        let configuration = model.configuration
        guard configuration.decayHalfLife > 0, configuration.ceiling > pruneTolerance else {
            return pruneHorizon
        }
        let decay = configuration.decayHalfLife * log2(configuration.ceiling / pruneTolerance)
        return max(pruneHorizon, configuration.peakDelay + decay)
    }

    /// The defensive limit on the baseline-crossing walk. Fourteen days past
    /// the last drink's pulse peak without a downward crossing means the
    /// configuration cannot resolve an endpoint, and the caller is told
    /// `.unavailable` rather than handed a number.
    public static let walkCap: TimeInterval = 14 * 86_400

    /// Coarse forward step used to bracket the crossing.
    public static let returnStep: TimeInterval = 30 * 60

    /// The bracket is then bisected to this precision, so the endpoint text and
    /// the sample where the curve reaches zero display agree.
    public static let returnPrecision: TimeInterval = 60

    /// How long a completed episode is retained on screen (design:
    /// "Completion and updates").
    public static let retention: TimeInterval = 24 * 3600

    // MARK: Entry point

    /// The episodes in `events`, oldest first.
    ///
    /// Only alcoholic drinks at or before `now` start or extend an episode;
    /// non-alcoholic and future-dated entries are ignored entirely.
    public static func partition(
        events: [DrinkEventSnapshot],
        now: Date,
        model: FibrinolysisModel = FibrinolysisModel()
    ) -> [SuppressionEpisode] {
        partition(drinks: contributingDrinks(events, now: now, model: model), now: now, model: model)
    }

    /// The alcoholic, already-happened drinks of `events`, weighted once.
    static func contributingDrinks(
        _ events: [DrinkEventSnapshot],
        now: Date,
        model: FibrinolysisModel
    ) -> [WeightedDrink] {
        model.weightedDrinks(events.filter { $0.type == .alcoholic && $0.timestamp <= now })
    }

    /// The same partition over drinks whose weights are already resolved.
    static func partition(
        drinks: [WeightedDrink],
        now: Date,
        model: FibrinolysisModel
    ) -> [SuppressionEpisode] {
        guard !drinks.isEmpty else { return [] }

        let threshold = model.configuration.baselineThreshold
        let peakDelay = model.configuration.peakDelay
        let horizon = pruneHorizon(for: model)

        var episodes: [SuppressionEpisode] = []
        var openStart = 0

        for index in 1..<drinks.count {
            let drink = drinks[index]
            let lastPeak = drinks[index - 1].timestamp.addingTimeInterval(peakDelay)

            // "Joins the open episode if it lands before that episode's current
            // return time." After the last drink's pulse peak the combined
            // curve only decays, so the first instant at or below the threshold
            // is permanent — which makes "before the return" exactly "still
            // climbing, or still above the threshold", without paying for the
            // crossing walk at every drink.
            let joinContext = drinks[
                min(pruneStart(drinks, before: drink.timestamp, horizon: horizon), index - 1)..<index
            ]
            let joins = drink.timestamp < lastPeak
                || model.index(at: drink.timestamp, weighted: joinContext) > threshold
            guard !joins else { continue }

            // The closing episode's own crossing is walked from `lastPeak`, so
            // its context is pruned against that instant — never against the
            // drink that ended it, which may be arbitrarily far in the future.
            episodes.append(
                episode(
                    drinks[openStart..<index],
                    endpoint: crossing(
                        after: lastPeak,
                        context: drinks[
                            min(pruneStart(drinks, before: lastPeak, horizon: horizon), openStart)..<index
                        ],
                        model: model,
                        now: now
                    )
                )
            )
            openStart = index
        }

        let lastPeak = drinks[drinks.count - 1].timestamp.addingTimeInterval(peakDelay)
        episodes.append(
            episode(
                drinks[openStart...],
                endpoint: crossing(
                    after: lastPeak,
                    context: drinks[
                        min(pruneStart(drinks, before: lastPeak, horizon: horizon), openStart)...
                    ],
                    model: model,
                    now: now
                )
            )
        )
        return episodes
    }

    /// The first index whose drink is inside `pruneHorizon` of `date` — the
    /// oldest drink that can still move the curve by more than
    /// `pruneTolerance` at that instant.
    ///
    /// Callers clamp this to the episode's own first drink: an episode longer
    /// than the horizon still owns every drink it displays.
    static func pruneStart(_ drinks: [WeightedDrink], before date: Date, horizon: TimeInterval) -> Int {
        let cutoff = date.addingTimeInterval(-horizon)
        var low = 0
        var high = drinks.count
        while low < high {
            let mid = (low + high) / 2
            if drinks[mid].timestamp < cutoff { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The drinks that measurably shape `episode`'s displayed curve: its own,
    /// plus the retained tails of anything inside the prune horizon before it.
    /// Drinks belonging to *later* episodes are excluded — an episode boundary
    /// is a display boundary.
    static func context(
        for episode: SuppressionEpisode,
        in drinks: [WeightedDrink],
        model: FibrinolysisModel
    ) -> ArraySlice<WeightedDrink> {
        let first = drinks.firstIndex { $0.timestamp >= episode.start } ?? 0
        let start = min(
            pruneStart(drinks, before: episode.start, horizon: pruneHorizon(for: model)),
            first
        )
        let end = drinks.lastIndex { $0.timestamp <= episode.lastDrink }.map { $0 + 1 } ?? drinks.count
        guard start < end else { return drinks[drinks.startIndex..<drinks.startIndex] }
        return drinks[start..<end]
    }

    private static func episode(
        _ slice: ArraySlice<WeightedDrink>,
        endpoint: SuppressionEndpoint
    ) -> SuppressionEpisode {
        SuppressionEpisode(
            start: slice.first!.timestamp,
            drinks: Array(slice),
            lastDrink: slice.last!.timestamp,
            baselineReturn: endpoint
        )
    }

    // MARK: Baseline crossing

    /// The first instant at or after `date` where the combined raw curve sits
    /// at or below `baselineThreshold`.
    ///
    /// `date` must be at or after every included drink's pulse peak, so the
    /// curve is monotonically decaying and the first crossing is permanent — a
    /// temporary low point before a pending rise can never be mistaken for the
    /// end of the episode. The walk brackets the crossing in `returnStep`
    /// strides and then bisects to `returnPrecision`.
    static func crossing(
        after date: Date,
        context: ArraySlice<WeightedDrink>,
        model: FibrinolysisModel,
        now: Date
    ) -> SuppressionEndpoint {
        let threshold = model.configuration.baselineThreshold
        guard model.index(at: date, weighted: context) > threshold else {
            return endpoint(date, now: now)
        }

        let limit = date.addingTimeInterval(walkCap)
        var below: Date?
        var above = date
        while above < limit {
            let next = above.addingTimeInterval(returnStep)
            if model.index(at: next, weighted: context) <= threshold {
                below = next
                break
            }
            above = next
        }
        guard var high = below else { return .unavailable }

        var low = above
        while high.timeIntervalSince(low) > returnPrecision {
            let mid = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
            if model.index(at: mid, weighted: context) <= threshold {
                high = mid
            } else {
                low = mid
            }
        }
        // The upper end of the bracket is the one that is actually at or below
        // the threshold, so the endpoint the text quotes is a point where the
        // curve reads zero on the display scale.
        return endpoint(high, now: now)
    }

    private static func endpoint(_ date: Date, now: Date) -> SuppressionEndpoint {
        date <= now ? .returned(date) : .projected(date)
    }
}
