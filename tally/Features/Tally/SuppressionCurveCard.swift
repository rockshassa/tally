import Charts
import SwiftUI
import TallyKit

// The suppression curve card (SPEC §4 "Recovery context · Suppression curve
// card"): the modeled fibrinolytic curve from ~6 h behind to ~18 h ahead, a
// now-marker, and one caption that says *how much* and *until when*.
//
// Three rules from the SPEC's honesty section govern everything below:
// * every caption carries the word **"modeled"** — this is a rendering of
//   published population dose-response, never a measurement;
// * **amber intensity only, never green** — no colour in this file can be read
//   as permission, and a curve sitting at baseline drops to neutral ink rather
//   than gaining a "you're fine" hue;
// * the y-axis shows the model's **own dimensionless index** (SPEC §4's 0–100
//   scale) as quiet reference values — the model's unit is not a risk score.
//   What stays forbidden: graded judgment words, thresholds framed as safe, and
//   any color that reads as permission.

// MARK: - Accessibility

/// The card's identifier.
///
/// It belongs next to `A11y.Tally.sessionCard`, but `tally/Shared/` is outside
/// this workstream's write scope; the *string* is the contract either way, so
/// folding this into `A11y.Tally` later is a pure move.
enum SuppressionCardA11y {
    static let card = "tally.suppressionCard"
}

// MARK: - Summary (pure, view-free, tested)

/// Everything the card says, derived from the frozen `FibrinolysisModel`.
///
/// Deliberately free of SwiftUI so `tallyTests/Recovery/SuppressionCardTests`
/// can pin the copy without a host view: the caption *is* the feature's promise
/// to the user, and it is the part most likely to drift.
struct SuppressionSummary: Equatable {

    /// Where the modeled curve is, relative to its own shape — not a severity
    /// scale. `rising` means a peak is still ahead; `falling` means the last
    /// peak is behind and the curve is decaying toward baseline.
    enum Phase: String, Equatable, CaseIterable {
        case baseline
        case rising
        case falling
    }

    struct Peak: Equatable {
        var date: Date
        var index: Double
    }

    /// The modeled index right now. Kept for ordering/plotting decisions only;
    /// it is never rendered as a figure.
    var index: Double

    /// Whether `index` clears the model's own baseline threshold.
    var isAboveBaseline: Bool

    var phase: Phase

    /// The modeled maximum still ahead, when there is one.
    var peak: Peak?

    /// When the modeled curve returns to baseline, when that is knowable.
    var baselineReturn: Date?

    /// An alcoholic drink inside the trailing 24 h (SPEC §4: the card has zero
    /// footprint on a day with neither recent intake nor a raised curve).
    var hasRecentIntake: Bool

    // MARK: Derivation

    /// Alcoholic pulses decay with an 8 h half-life, so a drink more than two
    /// days behind the *earliest* plotted sample contributes nothing readable.
    /// Trimming here is not cosmetic: `FibrinolysisModel` weighs every drink
    /// against every other one, so handing it the whole log would make the card
    /// quadratic in the size of the event store.
    static let relevanceWindow: TimeInterval = 60 * 3600

    /// The trailing window the "no drinks, no card" rule looks at.
    static let recentIntakeWindow: TimeInterval = 24 * 3600

    /// How far behind and ahead of now the card plots (SPEC §4).
    static let lookBack: TimeInterval = 6 * 3600
    static let lookAhead: TimeInterval = 18 * 3600

    /// A peak has to beat the current index by this much to count as "ahead of
    /// us" — otherwise a plateau reads as rising forever.
    private static let risingEpsilon = 0.5

    /// The only events any recovery surface needs to see.
    static func relevantEvents(_ events: [DrinkEventSnapshot], now: Date) -> [DrinkEventSnapshot] {
        let cutoff = now.addingTimeInterval(-(lookBack + relevanceWindow))
        return events.filter { $0.type == .alcoholic && $0.timestamp >= cutoff }
    }

    static func make(
        now: Date,
        events: [DrinkEventSnapshot],
        model: FibrinolysisModel = FibrinolysisModel()
    ) -> SuppressionSummary {
        let relevant = relevantEvents(events, now: now)

        let index = model.suppressionIndex(at: now, events: relevant)
        let isAboveBaseline = index > model.configuration.baselineThreshold
        let projected = model.projectedPeak(after: now, events: relevant)
        let peak = projected.map { Peak(date: $0.date, index: $0.index) }

        // `projectedPeak` reports the maximum over the horizon, which for a
        // decaying curve is simply *now* — so "rising" needs the peak to be
        // both later and higher than where we are standing.
        let phase: Phase
        if let peak, peak.date > now, peak.index > index + risingEpsilon {
            phase = .rising
        } else if isAboveBaseline {
            phase = .falling
        } else {
            phase = .baseline
        }

        let intakeCutoff = now.addingTimeInterval(-recentIntakeWindow)

        return SuppressionSummary(
            index: index,
            isAboveBaseline: isAboveBaseline,
            phase: phase,
            peak: peak,
            baselineReturn: model.baselineReturn(after: now, events: relevant),
            hasRecentIntake: relevant.contains { $0.timestamp >= intakeCutoff }
        )
    }

    // MARK: Presentation

    /// SPEC §4: zero footprint. Nothing to say and nothing recent to say it
    /// about means no card at all — not an empty one.
    var shouldRender: Bool {
        hasRecentIntake || phase != .baseline
    }

    /// The level word. `rising` while the index is still at baseline is the
    /// first 45 minutes after a drink — the model's absorption delay — where
    /// "elevated" would be a lie and "at baseline" would be misleading.
    var level: String {
        switch phase {
        case .baseline: "at baseline"
        case .rising: isAboveBaseline ? "elevated" : "rising"
        case .falling: "elevated"
        }
    }

    /// *"Modeled fibrinolytic suppression: elevated · peaks ~2 a.m. · baseline
    /// ~1 p.m."* — the SPEC's line, assembled from whichever clauses are true.
    func caption(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var parts = ["Modeled fibrinolytic suppression: \(level)"]

        if phase == .rising, let peak {
            parts.append("peaks \(SuppressionTime.approximate(peak.date, relativeTo: now, calendar: calendar, locale: locale))")
        }
        if phase == .falling {
            parts.append("easing")
        }
        if let baselineReturn {
            parts.append("baseline \(SuppressionTime.approximate(baselineReturn, relativeTo: now, calendar: calendar, locale: locale))")
        }

        return parts.joined(separator: " · ")
    }

    /// The same sentence with the interpuncts spoken as pauses.
    func spokenCaption(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        caption(now: now, calendar: calendar, locale: locale).replacingOccurrences(of: " · ", with: ", ")
    }
}

// MARK: - Time formatting

/// Approximate clock times for the caption.
///
/// Everything here rounds to the hour and wears a tilde, because the model is
/// an order-of-magnitude fit to population data — minute precision would be a
/// claim it cannot support.
enum SuppressionTime {

    /// Past this far ahead, a bare hour is ambiguous, so it gets a day word.
    static let tomorrowThreshold: TimeInterval = 18 * 3600

    /// *"~2 a.m."*, *"~1 p.m. tomorrow"*, or *"~13:00"* where the locale keeps
    /// a 24-hour clock.
    static func approximate(
        _ date: Date,
        relativeTo now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let rounded = roundedToHour(date, calendar: calendar)
        let hour = calendar.component(.hour, from: rounded)

        var text: String
        if uses12HourClock(locale) {
            let hour12 = hour % 12 == 0 ? 12 : hour % 12
            text = "~\(hour12) \(hour < 12 ? "a.m." : "p.m.")"
        } else {
            text = "~\(hour):00"
        }

        if rounded.timeIntervalSince(now) > tomorrowThreshold {
            text += " tomorrow"
        }
        return text
    }

    /// Hour-only label for the chart's x-axis, in the reader's clock.
    static func axisLabel(_ date: Date, locale: Locale = .current) -> String {
        date.formatted(.dateTime.hour().locale(locale))
    }

    /// Rounds through `Calendar` rather than by dividing the epoch, so a
    /// half-hour time zone lands on the wall-clock hour and not on :30.
    static func roundedToHour(_ date: Date, calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute], from: date)
        let minute = components.minute ?? 0
        components.minute = 0
        guard let floored = calendar.date(from: components) else { return date }
        guard minute >= 30 else { return floored }
        return calendar.date(byAdding: .hour, value: 1, to: floored) ?? floored
    }

    static func uses12HourClock(_ locale: Locale = .current) -> Bool {
        // "j" is the skeleton for "whatever hour field this locale prefers";
        // it resolves to an "h" family for 12-hour clocks and "H"/"k" for 24.
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "h"
        return template.contains("h") || template.contains("K")
    }
}

// MARK: - Card

/// The Tally screen's recovery card (SPEC §4).
///
/// Mounted unconditionally below the live Session card; it decides for itself
/// whether it exists. The hidden branch is a bare `EmptyView` with no modifiers
/// attached, which is what keeps the promise of *zero footprint* literal — a
/// zero-height-but-present view would still earn the enclosing `VStack`'s
/// spacing on both sides.
struct SuppressionCurveCard: View {

    /// The full log; the card trims it to the window the model needs.
    let events: [DrinkEventSnapshot]

    var model: FibrinolysisModel = FibrinolysisModel()

    /// Mirrored into `.standard` by `RecoveryContext.setEnabled`, so flipping
    /// the Settings toggle repaints this card without a relaunch.
    @AppStorage(RecoveryContext.enabledKey) private var isRecoveryEnabled = false

    /// The clock. `LiveSessionCard` gets this from a `TimelineView`, which is
    /// the better tool when the view is already on screen for good — here the
    /// card has to be able to *retire itself*, and a `TimelineView` cannot do
    /// that without leaving its slot (and its stack spacing) behind.
    @State private var now = Date()

    private static let tick: TimeInterval = 60

    var body: some View {
        // Nothing below this line runs while the toggle is off — the model is
        // not even asked (SPEC §4: zero footprint when off).
        if isRecoveryEnabled {
            let summary = SuppressionSummary.make(now: now, events: events, model: model)

            if summary.shouldRender {
                card(summary)
                    .task(id: refreshKey) {
                        // Keeps the now-marker, the caption's clock times, and
                        // the card's own existence honest between logged events.
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(Self.tick))
                            guard !Task.isCancelled else { return }
                            now = Date()
                        }
                    }
            }
        }
    }

    /// Restarts the ticker when the log changes, so a drink logged at 11:59
    /// doesn't wait out the rest of a stale minute.
    private var refreshKey: Int { events.count }

    private func card(_ summary: SuppressionSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.caption(now: now))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(TallyColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            curve(summary)
                .frame(height: 84)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyGlassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(SuppressionCardA11y.card)
        .accessibilityLabel(summary.spokenCaption(now: now))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Chart

    private struct CurvePoint: Identifiable {
        let id: Date
        let index: Double
        var date: Date { id }
    }

    private func points() -> [CurvePoint] {
        model.curve(
            from: window.lowerBound,
            to: window.upperBound,
            events: SuppressionSummary.relevantEvents(events, now: now)
        )
        .map { CurvePoint(id: $0.date, index: $0.index) }
    }

    private var window: ClosedRange<Date> {
        now.addingTimeInterval(-SuppressionSummary.lookBack)...now.addingTimeInterval(SuppressionSummary.lookAhead)
    }

    private func curve(_ summary: SuppressionSummary) -> some View {
        let samples = points()
        let peak = samples.map(\.index).max() ?? 0
        // A floor on the domain so a flat baseline day plots as a line resting
        // on the floor rather than as noise magnified to fill the frame.
        let yMax = max(model.configuration.baselineThreshold * 4, (peak * 1.2).rounded(.up))
        let stroke = summary.isAboveBaseline ? TallyColor.amberBright : TallyColor.inkTertiary

        return Chart {
            ForEach(samples) { sample in
                AreaMark(
                    x: .value("Time", sample.date),
                    y: .value("Modeled suppression", sample.index)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(fill(isAboveBaseline: summary.isAboveBaseline))

                LineMark(
                    x: .value("Time", sample.date),
                    y: .value("Modeled suppression", sample.index)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .foregroundStyle(stroke)
            }

            RuleMark(x: .value("Now", now))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(TallyColor.inkSecondary.opacity(0.7))

            PointMark(
                x: .value("Now", now),
                y: .value("Modeled suppression", summary.index)
            )
            .symbolSize(28)
            .foregroundStyle(stroke)
        }
        .chartXScale(domain: window)
        .chartYScale(domain: 0...yMax)
        // The y-axis shows the model's own dimensionless index (0–100, defined
        // in SPEC §4) so the curve has reference values for calibration. That is
        // the model's unit, not a risk score — the honesty line SPEC draws is at
        // graded judgment words and safety colors, not at the index itself.
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(TallyColor.line)
                AxisValueLabel {
                    if let index = value.as(Double.self) {
                        Text("\(Int(index))")
                            .font(.system(size: 8.5).monospacedDigit())
                            .foregroundStyle(TallyColor.inkTertiary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                AxisGridLine().foregroundStyle(TallyColor.line)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(SuppressionTime.axisLabel(date))
                            .font(.system(size: 8.5).monospacedDigit())
                            .foregroundStyle(TallyColor.inkTertiary)
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }

    /// Amber intensity — never green, never a second hue (SPEC §4). At baseline
    /// the fill drains to neutral ink so a flat curve reads as *nothing to
    /// report* rather than as an all-clear.
    private func fill(isAboveBaseline: Bool) -> LinearGradient {
        let top = isAboveBaseline ? TallyColor.amber.opacity(0.55) : TallyColor.inkTertiary.opacity(0.25)
        let bottom = isAboveBaseline ? TallyColor.amber.opacity(0.04) : TallyColor.inkTertiary.opacity(0.02)
        return LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        TallyColor.pageGradient.ignoresSafeArea()
        VStack {
            SuppressionCurveCard(events: SuppressionCurvePreview.events)
            Spacer()
        }
        .padding(TallyMetrics.screenPadding)
    }
    .preferredColorScheme(.dark)
    .onAppear { RecoveryContext.setEnabled(true) }
}

private enum SuppressionCurvePreview {
    /// Five drinks over the last five hours — a compressed evening, which is
    /// the shape the card exists to show.
    static var events: [DrinkEventSnapshot] {
        let now = Date()
        return (0..<5).map { index in
            DrinkEventSnapshot(
                type: .alcoholic,
                timestamp: now.addingTimeInterval(TimeInterval(-3600 * (1 + index)))
            )
        }
    }
}
