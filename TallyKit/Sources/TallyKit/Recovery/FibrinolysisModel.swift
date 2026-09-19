import Foundation

// MARK: - Recovery context (SPEC §4)

/// The opt-in switch for the recovery layer. Off by default; when off, every
/// recovery surface has zero footprint (SPEC §4 honesty rules).
public enum RecoveryContext {

    /// Stored in the App Group so the widget sees the same answer, mirrored to
    /// `.standard` so `@AppStorage` observers repaint live — the same pattern
    /// `TallyDefaults` uses on the app side.
    public static let enabledKey = "tally.recovery.enabled"

    /// Whether the user has been shown the one-time explainer (SPEC §4).
    public static let explainerSeenKey = "tally.recovery.explainerSeen"

    public static func isEnabled(
        appGroup: UserDefaults? = UserDefaults(suiteName: TallyStore.appGroupIdentifier)
    ) -> Bool {
        (appGroup ?? .standard).bool(forKey: enabledKey)
    }

    public static func setEnabled(
        _ enabled: Bool,
        appGroup: UserDefaults? = UserDefaults(suiteName: TallyStore.appGroupIdentifier)
    ) {
        (appGroup ?? .standard).set(enabled, forKey: enabledKey)
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
}

// MARK: - The model

/// A deterministic, pure model of acute alcohol's transient suppression of the
/// fibrinolytic system (SPEC §4 "Recovery context").
///
/// **What this is:** an educational rendering of published population
/// dose-response — acute intake raises PAI-1, inhibiting t-PA-driven clot
/// breakdown, with the suppression peaking *hours after* blood alcohol falls
/// and binge patterns suppressing disproportionately.
///
/// **What this is not:** a measurement, a clot-risk score, or anything that can
/// say "safe." Callers render burden and duration only, per the SPEC's honesty
/// rules. Parameter choices are order-of-magnitude fits to acute-PAI-1 studies
/// (evening intake roughly doubling next-morning PAI-1 activity, normalizing
/// over the following day), not a calibration to any individual.
public struct FibrinolysisModel: Sendable {

    public struct Configuration: Hashable, Sendable {

        /// Absorption: no modeled response before this much time has passed
        /// since the drink.
        public var onsetDelay: TimeInterval

        /// Time from drink to the pulse's maximum — the "morning after" lag
        /// that makes this model worth showing at all.
        public var peakDelay: TimeInterval

        /// Exponential decay half-life after the peak.
        public var decayHalfLife: TimeInterval

        /// Drinks landing within this window of each other compound.
        public var compressionWindow: TimeInterval

        /// Superlinearity of compounding: a drink's pulse is scaled by
        /// `n^(exponent − 1)` where `n` counts alcoholic drinks inside the
        /// trailing compression window (itself included). 1.0 = linear.
        public var compressionExponent: Double

        /// Peak contribution of one paced drink, in index points.
        public var unitPulse: Double

        /// Index ceiling — the scale is dimensionless and saturating.
        public var ceiling: Double

        /// Below this the index reads as "baseline."
        public var baselineThreshold: Double

        public init(
            onsetDelay: TimeInterval = 45 * 60,
            peakDelay: TimeInterval = 4 * 3600,
            decayHalfLife: TimeInterval = 8 * 3600,
            compressionWindow: TimeInterval = 2 * 3600,
            compressionExponent: Double = 1.3,
            unitPulse: Double = 10,
            ceiling: Double = 100,
            baselineThreshold: Double = 3
        ) {
            self.onsetDelay = onsetDelay
            self.peakDelay = peakDelay
            self.decayHalfLife = decayHalfLife
            self.compressionWindow = compressionWindow
            self.compressionExponent = compressionExponent
            self.unitPulse = unitPulse
            self.ceiling = ceiling
            self.baselineThreshold = baselineThreshold
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: Precomputed weights

    /// One alcoholic drink with its compression weight already resolved.
    ///
    /// A drink's weight depends only on how many drinks share its trailing
    /// compression window, so it is fixed for a given log. Resolving it once
    /// per drink is what keeps repeated sampling linear: the naive path
    /// recomputes every weight against every other drink at *every* sampled
    /// instant, which is what made the old cards quadratic in the log size.
    public struct WeightedDrink: Identifiable, Hashable, Sendable {

        public let id: UUID
        public let timestamp: Date

        /// `n^(exponent − 1)` for this drink — see `weightedDrinks(_:)`.
        public let weight: Double

        public init(id: UUID, timestamp: Date, weight: Double) {
            self.id = id
            self.timestamp = timestamp
            self.weight = weight
        }
    }

    /// The alcoholic drinks in `events`, in TallyKit's total order, each
    /// carrying its compression weight.
    ///
    /// The weight is `n^(exponent − 1)` where `n` counts alcoholic drinks in
    /// the trailing compression window ending at that drink (itself included)
    /// — identical to the per-sample computation it replaces, ties at either
    /// edge of the window included.
    public func weightedDrinks(_ events: [DrinkEventSnapshot]) -> [WeightedDrink] {
        let drinks = alcoholic(events).sorted(by: DrinkEventSnapshot.isOrderedBefore)
        let times = drinks.map(\.timestamp)
        return drinks.map { drink in
            let windowStart = drink.timestamp.addingTimeInterval(-configuration.compressionWindow)
            let lower = Self.countOfDates(in: times, notAfter: windowStart)
            let upper = Self.countOfDates(in: times, notAfter: drink.timestamp)
            let n = max(1, upper - lower)
            return WeightedDrink(
                id: drink.id,
                timestamp: drink.timestamp,
                weight: pow(Double(n), configuration.compressionExponent - 1)
            )
        }
    }

    /// How many entries of the sorted `dates` are at or before `bound`.
    private static func countOfDates(in dates: [Date], notAfter bound: Date) -> Int {
        var low = 0
        var high = dates.count
        while low < high {
            let mid = (low + high) / 2
            if dates[mid] <= bound { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: Index

    /// The modeled suppression index at `date`: the sum of every alcoholic
    /// drink's pulse, compression-weighted, capped at the ceiling.
    /// 0 = baseline. NA drinks contribute nothing (SPEC §4).
    public func suppressionIndex(at date: Date, events: [DrinkEventSnapshot]) -> Double {
        suppressionIndex(at: date, weighted: weightedDrinks(events))
    }

    /// The same index over drinks whose weights are already resolved.
    public func suppressionIndex(at date: Date, weighted drinks: [WeightedDrink]) -> Double {
        index(at: date, weighted: drinks)
    }

    /// Samples the curve over a range — the Tally-screen and widget cards
    /// render exactly this.
    public func curve(
        from start: Date,
        to end: Date,
        step: TimeInterval = 15 * 60,
        events: [DrinkEventSnapshot]
    ) -> [(date: Date, index: Double)] {
        curve(from: start, to: end, step: step, weighted: weightedDrinks(events))
    }

    /// The same sampler over drinks whose weights are already resolved.
    public func curve(
        from start: Date,
        to end: Date,
        step: TimeInterval = 15 * 60,
        weighted drinks: [WeightedDrink]
    ) -> [(date: Date, index: Double)] {
        guard end > start, step > 0 else { return [] }
        var samples: [(Date, Double)] = []
        var t = start
        while t <= end {
            samples.append((t, index(at: t, weighted: drinks)))
            t = t.addingTimeInterval(step)
        }
        return samples
    }

    /// The summed, capped index over any collection of weighted drinks — the
    /// one place the ceiling is applied, and the hot path for episode walks.
    func index(at date: Date, weighted drinks: some Sequence<WeightedDrink>) -> Double {
        min(configuration.ceiling, drinks.reduce(0.0) { $0 + pulse(at: date, drink: $1) })
    }

    /// The modeled peak still ahead of (or at) `date`, if the index is not
    /// already past its last maximum.
    public func projectedPeak(
        after date: Date,
        events: [DrinkEventSnapshot],
        horizon: TimeInterval = 24 * 3600
    ) -> (date: Date, index: Double)? {
        let samples = curve(from: date, to: date.addingTimeInterval(horizon), events: events)
        guard let top = samples.max(by: { $0.index < $1.index }), top.index > configuration.baselineThreshold
        else { return nil }
        return (top.date, top.index)
    }

    /// First moment at or after `date` when the modeled index falls to
    /// baseline and stays there. Nil when it already reads baseline.
    public func baselineReturn(
        after date: Date,
        events: [DrinkEventSnapshot],
        horizon: TimeInterval = 48 * 3600
    ) -> Date? {
        // Weights resolved once for both passes; the numbers are unchanged.
        let drinks = weightedDrinks(events)
        guard index(at: date, weighted: drinks) > configuration.baselineThreshold else { return nil }
        let samples = curve(from: date, to: date.addingTimeInterval(horizon), weighted: drinks)
        // Scan from the end so a later re-rise (another drink) is respected.
        var boundary: Date?
        for sample in samples.reversed() {
            if sample.index > configuration.baselineThreshold { break }
            boundary = sample.date
        }
        return boundary
    }

    // MARK: Session classification (SPEC §4 "Session rebound classification")

    public enum ReboundClass: String, Hashable, Sendable, CaseIterable {
        /// ≤ 1 alcoholic drink per any 90-minute stretch.
        case paced
        /// 2–3 in some 90-minute stretch.
        case elevated
        /// 4+ in some 90-minute stretch — the binge-pattern rebound.
        case compressed

        /// One factual line, tone per SPEC §5. No advice, no color words.
        public var summary: String {
            switch self {
            case .paced:
                "Paced — modeled next-morning rebound low."
            case .elevated:
                "Some compression — modeled next-morning rebound moderate."
            case .compressed:
                "Compressed — this pattern models the strongest next-morning suppression."
            }
        }
    }

    /// Classifies a Session by its densest 90-minute stretch of alcoholic
    /// drinks — density, not total, is what drives the modeled rebound.
    public func classify(_ session: DerivedSession) -> ReboundClass {
        let times = session.events
            .filter { $0.type == .alcoholic }
            .map(\.timestamp)
            .sorted()
        guard !times.isEmpty else { return .paced }

        let window: TimeInterval = 90 * 60
        var densest = 1
        for (i, start) in times.enumerated() {
            let inWindow = times[i...].prefix { $0.timeIntervalSince(start) <= window }.count
            densest = max(densest, inWindow)
        }
        switch densest {
        case ..<2: return .paced
        case 2...3: return .elevated
        default: return .compressed
        }
    }

    // MARK: - Pulse shape

    private func alcoholic(_ events: [DrinkEventSnapshot]) -> [DrinkEventSnapshot] {
        events.filter { $0.type == .alcoholic }
    }

    /// One drink's contribution at `date`: smooth rise from onset to the peak,
    /// exponential decay after, scaled by the compression weight.
    private func pulse(at date: Date, drink: WeightedDrink) -> Double {
        let elapsed = date.timeIntervalSince(drink.timestamp)
        guard elapsed > configuration.onsetDelay else { return 0 }

        let magnitude = configuration.unitPulse * drink.weight

        if elapsed < configuration.peakDelay {
            // Smoothstep from onset to peak: no artificial cliffs in the card.
            let t = (elapsed - configuration.onsetDelay) / (configuration.peakDelay - configuration.onsetDelay)
            return magnitude * t * t * (3 - 2 * t)
        }

        let sincePeak = elapsed - configuration.peakDelay
        return magnitude * pow(0.5, sincePeak / configuration.decayHalfLife)
    }
}

// MARK: - Convenience

/// Top-level spelling of `FibrinolysisModel.WeightedDrink`, so callers that
/// only ever touch the timeline don't have to name the model.
public typealias WeightedDrink = FibrinolysisModel.WeightedDrink
