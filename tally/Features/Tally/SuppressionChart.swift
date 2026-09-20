import Charts
import SwiftUI
import TallyKit

// The episode chart — first drink → rise → peak → decline → 0 — drawn once and
// used twice: compact inside the Tally card, tall and inspectable inside
// `SuppressionDetailSheet`, and identical in every number it shows.
//
// Everything plotted is a *display* value (`max(0, raw − baselineThreshold)`),
// so the curve has an honest zero: the model's own baseline band, not a
// biological reading. Amber and neutral ink only — never green, never red, and
// never a curve drained to neutral just because the clock has moved past its
// peak (the design forbids erasing the history that way).

// MARK: - Geometry (pure, view-free, tested)

/// The arithmetic behind the drawing, kept out of the view so
/// `tallyTests/Recovery/` can pin the promises that matter: a y-scale that does
/// not move when the clock does, ticks that merge instead of overlapping, and a
/// set of anchors VoiceOver can step through.
enum SuppressionChartGeometry {

    // MARK: Vertical scale

    /// Headroom above the episode's peak, so the marker and its annotation are
    /// not pinned to the top edge.
    static let headroom = 1.15

    /// A floor under the domain, so a single-drink episode is not magnified to
    /// fill the frame and read like a heavy night.
    static let minimumTop: Double = 8

    /// Anchored at zero, sized to the whole episode, and — because `peak` is
    /// the episode's overall maximum rather than a windowed one — *fixed for
    /// the episode*. The clock advancing cannot rescale it, which is what keeps
    /// two glances an hour apart comparable.
    static func yDomain(for timeline: SuppressionTimeline) -> ClosedRange<Double> {
        0...max(timeline.peak.display * headroom, minimumTop)
    }

    // MARK: Solid past, dashed future

    /// Splits the curve at `now`, which is always an exact sample when it is in
    /// range, so the two halves meet at a point instead of leaving a gap.
    static func split(
        _ samples: [SuppressionTimeline.Sample],
        at now: Date
    ) -> (past: [SuppressionTimeline.Sample], future: [SuppressionTimeline.Sample]) {
        (samples.filter { $0.date <= now }, samples.filter { $0.date >= now })
    }

    // MARK: Drink ticks

    /// One tick along the bottom: a logged drink, or a cluster of them too
    /// close together to draw apart.
    struct Tick: Equatable, Identifiable {

        /// The middle of the cluster — one tick centred on what it represents.
        let date: Date

        /// How many drinks it stands for. 1 draws a bare tick; more draws a count.
        let count: Int

        /// Belongs to the Session that opened this chart (Session detail).
        let isHighlighted: Bool

        var id: Date { date }
    }

    /// Drinks closer together than this fraction of the plotted range collapse
    /// into one counted tick. Proportional rather than absolute, because the
    /// same evening is a third of an 18-hour episode and a rounding error in a
    /// week-long one.
    static let tickMergeFraction = 0.03

    static func ticks(
        for markers: [SuppressionTimeline.DrinkMarker],
        in range: ClosedRange<Date>,
        highlighting highlighted: Set<UUID> = [],
        mergeFraction: Double = tickMergeFraction
    ) -> [Tick] {
        let window = range.upperBound.timeIntervalSince(range.lowerBound) * mergeFraction
        let sorted = markers.sorted { $0.date < $1.date }

        var ticks: [Tick] = []
        var group: [SuppressionTimeline.DrinkMarker] = []

        func flush() {
            guard let first = group.first, let last = group.last else { return }
            ticks.append(
                Tick(
                    // The midpoint of the cluster's own span, so a tick never
                    // drifts outside the drinks it merged.
                    date: first.date.addingTimeInterval(last.date.timeIntervalSince(first.date) / 2),
                    count: group.count,
                    isHighlighted: group.contains { highlighted.contains($0.id) }
                )
            )
            group = []
        }

        for marker in sorted {
            // Measured from the cluster's first drink, not its last, so a long
            // even cadence cannot chain itself into one tick for the night.
            if let anchor = group.first, marker.date.timeIntervalSince(anchor.date) > window {
                flush()
            }
            group.append(marker)
        }
        flush()
        return ticks
    }

    // MARK: Anchors

    /// The milestones an inspection can land on: the first drink, each drawn
    /// tick, the peak, now, the modeled return, and the end of the plot.
    ///
    /// This is the non-drag path through the chart — VoiceOver's adjustable
    /// action steps through exactly these, so the accessible story is the same
    /// story the markers tell.
    static func anchors(for timeline: SuppressionTimeline) -> [SuppressionTimeline.Sample] {
        var dates: [Date] = [timeline.start, timeline.peak.date]
        dates += ticks(for: timeline.drinkMarkers, in: timeline.range).map(\.date)
        if let end = timeline.peak.plateauEnd { dates.append(end) }
        if timeline.nowValue != nil { dates.append(timeline.now) }
        if let crossing = timeline.baselineReturn.date { dates.append(crossing) }
        dates.append(timeline.range.upperBound)

        var seen = Set<Int>()
        return dates
            .sorted()
            .compactMap { sample(at: $0, in: timeline) }
            .filter { seen.insert(Int($0.date.timeIntervalSinceReferenceDate.rounded())).inserted }
    }

    /// The plotted sample nearest an instant — what an inspection reads out, so
    /// the number under the finger is one the curve actually contains.
    static func sample(at date: Date, in timeline: SuppressionTimeline) -> SuppressionTimeline.Sample? {
        timeline.samples.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    // MARK: Decimation

    /// Points drawn per curve before thinning. Well above what a phone-width
    /// chart can resolve, and far below what a fortnight-long episode samples.
    static let drawingLimit = 180

    /// Thins a curve for drawing while keeping every milestone exactly.
    ///
    /// Decimation is a rendering concern and lives here rather than in
    /// `SuppressionTimeline`, which owes its callers every anchor it computed.
    static func decimated(
        _ samples: [SuppressionTimeline.Sample],
        keeping anchors: Set<Date>,
        limit: Int = drawingLimit
    ) -> [SuppressionTimeline.Sample] {
        guard samples.count > limit, limit > 1 else { return samples }
        let step = max(2, Int((Double(samples.count) / Double(limit)).rounded(.up)))
        return samples.enumerated().compactMap { index, sample in
            index % step == 0
                || index == samples.count - 1
                || anchors.contains(sample.date)
                ? sample
                : nil
        }
    }
}

// MARK: - Chart

struct SuppressionChart: View {

    let timeline: SuppressionTimeline

    /// Compact in the card, roomy in the sheet: the sheet gets annotations and
    /// a y-axis the card has no room for.
    var isExpanded = false

    /// The Session that opened this chart, if any — its drinks get brighter
    /// ticks so a night can be found inside a multi-day episode.
    var highlightedEventIDs: Set<UUID> = []

    /// The instant the user is pointing at, in the expanded chart.
    var selection: Date?

    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    private var summary: SuppressionSummary { SuppressionSummary(timeline) }

    private var yDomain: ClosedRange<Double> { SuppressionChartGeometry.yDomain(for: timeline) }

    private var anchorDates: Set<Date> {
        Set(SuppressionChartGeometry.anchors(for: timeline).map(\.date))
    }

    /// The samples actually drawn: thinned for rendering, with every milestone
    /// kept exactly where the timeline put it.
    private var drawn: [SuppressionTimeline.Sample] {
        SuppressionChartGeometry.decimated(timeline.samples, keeping: anchorDates)
    }

    private var curve: (past: [SuppressionTimeline.Sample], future: [SuppressionTimeline.Sample]) {
        SuppressionChartGeometry.split(drawn, at: timeline.now)
    }

    private var ticks: [SuppressionChartGeometry.Tick] {
        SuppressionChartGeometry.ticks(
            for: timeline.drinkMarkers,
            in: timeline.range,
            highlighting: highlightedEventIDs
        )
    }

    private var xTicks: [SuppressionTime.AxisTick] {
        SuppressionTime.axisTicks(in: timeline.range, calendar: calendar, locale: locale)
    }

    private var selectedSample: SuppressionTimeline.Sample? {
        selection.flatMap { SuppressionChartGeometry.sample(at: $0, in: timeline) }
    }

    var body: some View {
        Chart {
            area
            past
            future
            startMarker
            drinkTicks
            peakMarker
            nowMarker
            endpointMarker
            selectionMarker
        }
        .chartXScale(domain: timeline.range)
        .chartYScale(domain: yDomain)
        .chartLegend(.hidden)
        .chartXAxis { xAxis }
        .chartYAxis { yAxis }
    }

    // MARK: Curve

    private var fill: LinearGradient {
        LinearGradient(
            colors: [TallyColor.amber.opacity(0.45), TallyColor.amber.opacity(0.03)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// One area across the whole episode. The elapsed part is not drained to
    /// neutral when the curve is back at baseline — the progression that
    /// already happened stays legible (design: "Layout and interaction").
    @ChartContentBuilder
    private var area: some ChartContent {
        ForEach(drawn, id: \.date) { sample in
            AreaMark(
                x: .value("Time", sample.date),
                y: .value(SuppressionSummary.yAxisLabel, sample.display)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(fill)
        }
    }

    @ChartContentBuilder
    private var past: some ChartContent {
        ForEach(curve.past, id: \.date) { sample in
            LineMark(
                x: .value("Time", sample.date),
                y: .value(SuppressionSummary.yAxisLabel, sample.display),
                series: .value("Curve", "elapsed")
            )
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .foregroundStyle(TallyColor.amberBright)
        }
    }

    /// Dashed, because it has not happened: both halves are modeled, but only
    /// one of them is modeled over drinks that are already logged *and* time
    /// that has already passed.
    @ChartContentBuilder
    private var future: some ChartContent {
        ForEach(curve.future, id: \.date) { sample in
            LineMark(
                x: .value("Time", sample.date),
                y: .value(SuppressionSummary.yAxisLabel, sample.display),
                series: .value("Curve", "forecast")
            )
            .interpolationMethod(.monotone)
            .lineStyle(StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [4, 3]))
            .foregroundStyle(TallyColor.amberBright.opacity(0.85))
        }
    }

    private var lineWidth: CGFloat { isExpanded ? 2.5 : 2 }

    // MARK: Milestones

    /// Where the episode began. Drawn hollow so it reads as an origin rather
    /// than as a value.
    @ChartContentBuilder
    private var startMarker: some ChartContent {
        PointMark(
            x: .value("First drink", timeline.start),
            y: .value(SuppressionSummary.yAxisLabel, startDisplay)
        )
        .symbol {
            Circle()
                .strokeBorder(TallyColor.amberBright, lineWidth: 1.5)
                .frame(width: isExpanded ? 9 : 7, height: isExpanded ? 9 : 7)
        }
        .annotation(position: .topLeading, spacing: 2) {
            if isExpanded {
                Text("First drink")
                    .font(.system(size: 9))
                    .foregroundStyle(TallyColor.inkTertiary)
            }
        }
    }

    private var startDisplay: Double {
        SuppressionChartGeometry.sample(at: timeline.start, in: timeline)?.display ?? 0
    }

    /// Every logged drink, along the bottom. Clusters carry their count so a
    /// compressed hour is not silently drawn as one drink.
    @ChartContentBuilder
    private var drinkTicks: some ChartContent {
        ForEach(ticks) { tick in
            RuleMark(
                x: .value("Drink", tick.date),
                yStart: .value(SuppressionSummary.yAxisLabel, 0),
                yEnd: .value(SuppressionSummary.yAxisLabel, yDomain.upperBound * tickHeight(tick))
            )
            .lineStyle(StrokeStyle(lineWidth: tick.isHighlighted ? 2 : 1.2, lineCap: .round))
            .foregroundStyle(
                tick.isHighlighted
                    ? TallyColor.amberBright
                    : TallyColor.amber.opacity(highlightedEventIDs.isEmpty ? 0.85 : 0.4)
            )
            .annotation(position: .top, spacing: 0) {
                if tick.count > 1 {
                    Text("×\(tick.count)")
                        .font(.system(size: isExpanded ? 9 : 8).monospacedDigit())
                        .foregroundStyle(
                            tick.isHighlighted ? TallyColor.amberBright : TallyColor.inkTertiary
                        )
                }
            }
        }
    }

    private func tickHeight(_ tick: SuppressionChartGeometry.Tick) -> Double {
        tick.isHighlighted ? 0.12 : 0.08
    }

    /// The episode's overall maximum, past or future. A capped plateau marks
    /// its first occurrence; the sheet describes the interval in words.
    @ChartContentBuilder
    private var peakMarker: some ChartContent {
        PointMark(
            x: .value("Peak", timeline.peak.date),
            y: .value(SuppressionSummary.yAxisLabel, timeline.peak.display)
        )
        .symbolSize(isExpanded ? 44 : 26)
        .foregroundStyle(TallyColor.amberBright)
        .annotation(position: .top, spacing: 3) {
            if isExpanded {
                Text(summary.peak.date <= timeline.now ? "Peaked" : "Peak")
                    .font(.system(size: 9))
                    .foregroundStyle(TallyColor.inkTertiary)
            }
        }
    }

    /// The Now rule while the episode is running; once it is over the clock has
    /// left the plot, and the rule is replaced by what actually happened.
    @ChartContentBuilder
    private var nowMarker: some ChartContent {
        if let nowValue = timeline.nowValue, !timeline.isComplete {
            RuleMark(x: .value("Now", nowValue.date))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(TallyColor.inkSecondary.opacity(0.7))
                .annotation(position: .top, alignment: .center, spacing: 1) {
                    Text("Now")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(TallyColor.inkSecondary)
                }

            PointMark(
                x: .value("Now", nowValue.date),
                y: .value(SuppressionSummary.yAxisLabel, nowValue.display)
            )
            .symbolSize(isExpanded ? 60 : 36)
            .foregroundStyle(TallyColor.amberBright)
        }
    }

    /// The labelled endpoint: where the curve comes to rest, and — for a
    /// finished episode — the sentence that replaces the Now rule.
    @ChartContentBuilder
    private var endpointMarker: some ChartContent {
        if let crossing = timeline.baselineReturn.date, timeline.range.contains(crossing) {
            PointMark(
                x: .value("Modeled baseline", crossing),
                y: .value(SuppressionSummary.yAxisLabel, 0)
            )
            .symbol {
                Circle()
                    .strokeBorder(TallyColor.inkSecondary, lineWidth: 1.2)
                    .frame(width: 6, height: 6)
            }
            .annotation(position: .topTrailing, alignment: .trailing, spacing: 2) {
                Text(SuppressionSummary.endpointLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(TallyColor.inkTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }

            if let completion = summary.completionText(calendar: calendar, locale: locale) {
                RuleMark(x: .value("Returned", crossing))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(TallyColor.inkSecondary.opacity(0.5))
                    .annotation(position: .top, alignment: .trailing, spacing: 1) {
                        Text(completion)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(TallyColor.inkSecondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
            }
        }
    }

    // MARK: Inspection

    @ChartContentBuilder
    private var selectionMarker: some ChartContent {
        if let sample = selectedSample {
            RuleMark(x: .value("Selected", sample.date))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(TallyColor.ink.opacity(0.35))

            PointMark(
                x: .value("Selected", sample.date),
                y: .value(SuppressionSummary.yAxisLabel, sample.display)
            )
            .symbolSize(70)
            .foregroundStyle(TallyColor.ink)
        }
    }

    // MARK: Axes

    /// Four to six labels computed from the episode's own span, with the day
    /// named wherever the range crosses midnight — an episode can be eighteen
    /// hours or eight days, and a fixed hourly stride reads wrong for one of
    /// them.
    @AxisContentBuilder
    private var xAxis: some AxisContent {
        AxisMarks(values: xTicks.map(\.date)) { value in
            if let tick = tick(for: value) {
                AxisGridLine()
                    .foregroundStyle(TallyColor.line.opacity(tick.isDayBoundary ? 1 : 0.55))
                AxisValueLabel {
                    Text(tick.text)
                        .font(.system(size: isExpanded ? 10 : 8.5).monospacedDigit())
                        .foregroundStyle(
                            tick.isDayBoundary ? TallyColor.inkSecondary : TallyColor.inkTertiary
                        )
                }
            }
        }
    }

    private func tick(for value: AxisValue) -> SuppressionTime.AxisTick? {
        guard let date = value.as(Date.self) else { return nil }
        return xTicks.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }

    /// Zero and the episode's ceiling only. The numbers are display values on
    /// the axis the caption names — quiet reference points, never a score.
    @AxisContentBuilder
    private var yAxis: some AxisContent {
        AxisMarks(position: .trailing, values: [0, yDomain.upperBound]) { value in
            AxisGridLine().foregroundStyle(TallyColor.line)
            AxisValueLabel {
                if let display = value.as(Double.self) {
                    Text("\(Int(display.rounded()))")
                        .font(.system(size: isExpanded ? 10 : 8.5).monospacedDigit())
                        .foregroundStyle(TallyColor.inkTertiary)
                }
            }
        }
    }
}

// MARK: - Facts

/// **First drink · Peak / Peaked · Baseline / Returned** — the three compact
/// facts under every suppression chart.
///
/// They exist because chart annotations collide: on a busy episode the peak
/// label can land on the Now rule and the endpoint label can land on the last
/// tick, and when that happens this row is still the whole story in words.
struct SuppressionFactsRow: View {

    let facts: [SuppressionSummary.Fact]

    var labelSize: CGFloat = 9
    var valueSize: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 1) {
                    Text(fact.label)
                        .font(.system(size: labelSize, weight: .semibold))
                        .textCase(.uppercase)
                        .kerning(0.4)
                        .foregroundStyle(TallyColor.inkTertiary)
                        .lineLimit(1)

                    Text(fact.value)
                        .font(.system(size: valueSize, weight: .medium).monospacedDigit())
                        .foregroundStyle(TallyColor.inkSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
