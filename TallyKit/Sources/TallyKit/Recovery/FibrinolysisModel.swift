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

    // MARK: Index

    /// The modeled suppression index at `date`: the sum of every alcoholic
    /// drink's pulse, compression-weighted, capped at the ceiling.
    /// 0 = baseline. NA drinks contribute nothing (SPEC §4).
    public func suppressionIndex(at date: Date, events: [DrinkEventSnapshot]) -> Double {
        let drinks = alcoholic(events)
        let total = drinks.reduce(0.0) { sum, drink in
            sum + pulse(at: date, drink: drink, among: drinks)
        }
        return min(configuration.ceiling, total)
    }

    /// Samples the curve over a range — the Tally-screen and widget cards
    /// render exactly this.
    public func curve(
        from start: Date,
        to end: Date,
        step: TimeInterval = 15 * 60,
        events: [DrinkEventSnapshot]
    ) -> [(date: Date, index: Double)] {
        guard end > start, step > 0 else { return [] }
        let drinks = alcoholic(events)
        var samples: [(Date, Double)] = []
        var t = start
        while t <= end {
            let value = min(
                configuration.ceiling,
                drinks.reduce(0.0) { $0 + pulse(at: t, drink: $1, among: drinks) }
            )
            samples.append((t, value))
            t = t.addingTimeInterval(step)
        }
        return samples
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
        guard suppressionIndex(at: date, events: events) > configuration.baselineThreshold else { return nil }
        let samples = curve(from: date, to: date.addingTimeInterval(horizon), events: events)
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
    private func pulse(
        at date: Date,
        drink: DrinkEventSnapshot,
        among drinks: [DrinkEventSnapshot]
    ) -> Double {
        let elapsed = date.timeIntervalSince(drink.timestamp)
        guard elapsed > configuration.onsetDelay else { return 0 }

        let magnitude = configuration.unitPulse * compressionWeight(for: drink, among: drinks)

        if elapsed < configuration.peakDelay {
            // Smoothstep from onset to peak: no artificial cliffs in the card.
            let t = (elapsed - configuration.onsetDelay) / (configuration.peakDelay - configuration.onsetDelay)
            return magnitude * t * t * (3 - 2 * t)
        }

        let sincePeak = elapsed - configuration.peakDelay
        return magnitude * pow(0.5, sincePeak / configuration.decayHalfLife)
    }

    /// `n^(exponent − 1)` where `n` counts alcoholic drinks in the trailing
    /// compression window ending at this drink (itself included). Paced drinks
    /// get weight 1; a fourth drink inside two hours gets `4^0.3 ≈ 1.5`.
    private func compressionWeight(
        for drink: DrinkEventSnapshot,
        among drinks: [DrinkEventSnapshot]
    ) -> Double {
        let windowStart = drink.timestamp.addingTimeInterval(-configuration.compressionWindow)
        let n = drinks.count { $0.timestamp > windowStart && $0.timestamp <= drink.timestamp }
        return pow(Double(max(1, n)), configuration.compressionExponent - 1)
    }
}
