import Charts
import SwiftUI
import TallyKit

// The four charts of SPEC §4, all Swift Charts, all in the two semantic hues.
//
// Two rules hold everywhere in this file:
// * **amber is alcohol, aqua is not** — no chart ever introduces a third
//   categorical colour; the 7-day average and the ratio goal are drawn in
//   neutral ink precisely so they read as reference, not as a third series;
// * **no degenerate axes** — every scale has an explicit domain with a floor, so
//   an empty store, one event, and 90 days of data all produce a readable plot
//   (PLAN Gate 2).

private enum TrendsSeries {
    static let alcoholic = "Alcoholic"
    static let nonAlcoholic = "Non-alc"

    static let scale: KeyValuePairs<String, Color> = [
        alcoholic: TallyColor.amber,
        nonAlcoholic: TallyColor.aqua
    ]
}

// MARK: - Drinks per day/week/month

/// SPEC §4: "Bar chart of drinks per day/week/month, alcoholic vs NA stacked"
/// with the "Rolling 7-day average line overlay — the headline trend signal."
struct TrendsDrinksChart: View {

    let buckets: [TrendsBucket]
    let granularity: TrendsGranularity
    var calendar: Calendar = .current

    private struct Segment: Identifiable {
        let id: String
        let bucketStart: Date
        let series: String
        let count: Int
    }

    private var segments: [Segment] {
        buckets.flatMap { bucket -> [Segment] in
            var out: [Segment] = []
            if bucket.alcoholic > 0 {
                out.append(Segment(
                    id: "\(bucket.start.timeIntervalSince1970)-a",
                    bucketStart: bucket.start,
                    series: TrendsSeries.alcoholic,
                    count: bucket.alcoholic
                ))
            }
            if bucket.nonAlcoholic > 0 {
                out.append(Segment(
                    id: "\(bucket.start.timeIntervalSince1970)-n",
                    bucketStart: bucket.start,
                    series: TrendsSeries.nonAlcoholic,
                    count: bucket.nonAlcoholic
                ))
            }
            return out
        }
    }

    /// The overlay is plotted at each bar's midpoint so the line sits over the
    /// bars rather than on their leading edge.
    private struct AveragePoint: Identifiable {
        let id: Date
        let midpoint: Date
        let value: Double
    }

    private var averagePoints: [AveragePoint] {
        buckets.compactMap { bucket in
            guard let average = bucket.average else { return nil }
            let end = TrendsMath.endOfBucket(start: bucket.start, granularity: granularity, calendar: calendar)
            let midpoint = bucket.start.addingTimeInterval(end.timeIntervalSince(bucket.start) / 2)
            return AveragePoint(id: bucket.start, midpoint: midpoint, value: average)
        }
    }

    private var domain: ClosedRange<Date> {
        guard let first = buckets.first, let last = buckets.last else {
            let now = Date()
            return now.addingTimeInterval(-86_400)...now
        }
        let upper = TrendsMath.endOfBucket(start: last.start, granularity: granularity, calendar: calendar)
        return first.start...max(upper, first.start.addingTimeInterval(60))
    }

    /// Floors at 2 so a single logged drink does not produce a one-tick axis.
    private var yMax: Double {
        let peakBar = buckets.map(\.total).max() ?? 0
        let peakLine = averagePoints.map(\.value).max() ?? 0
        return max(2, (Double(peakBar) * 1.15).rounded(.up), (peakLine * 1.15).rounded(.up))
    }

    var body: some View {
        Chart {
            ForEach(segments) { segment in
                BarMark(
                    x: .value("Date", segment.bucketStart, unit: granularity.unit),
                    y: .value("Drinks", Double(segment.count))
                )
                .foregroundStyle(by: .value("Series", segment.series))
                .cornerRadius(2)
                .accessibilityLabel(axisLabel(segment.bucketStart))
                .accessibilityValue("\(segment.count) \(segment.series)")
            }

            ForEach(averagePoints) { point in
                LineMark(
                    x: .value("Date", point.midpoint),
                    y: .value(granularity.averageLegendLabel, point.value)
                )
                .foregroundStyle(TallyColor.inkSecondary)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
                .symbol(.circle)
                .symbolSize(12)
                .accessibilityLabel("\(granularity.averageLegendLabel), \(axisLabel(point.midpoint))")
                .accessibilityValue(point.value.formatted(.number.precision(.fractionLength(0...1))))
            }
        }
        .chartForegroundStyleScale(TrendsSeries.scale)
        .chartLegend(.hidden)
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...yMax)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                AxisGridLine().foregroundStyle(TallyColor.line)
                AxisValueLabel()
                    .font(.system(size: 8.5).monospacedDigit())
                    .foregroundStyle(TallyColor.inkTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: granularity.unit, count: strideCount)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(date))
                            .font(.system(size: 8.5))
                            .foregroundStyle(TallyColor.inkTertiary)
                    }
                }
            }
        }
        .frame(height: 150)
        .accessibilityLabel("Drinks per \(granularity.title.lowercased()), alcoholic and non-alcoholic stacked, with the 7-day average overlaid")
    }

    private var strideCount: Int {
        switch granularity {
        case .day: 3
        case .week: 2
        case .month: 2
        }
    }

    private func axisLabel(_ date: Date) -> String {
        switch granularity {
        case .day: date.formatted(.dateTime.day())
        case .week: date.formatted(.dateTime.month(.abbreviated).day())
        case .month: date.formatted(.dateTime.month(.narrow))
        }
    }
}

// MARK: - Ratio over time

/// SPEC §4: "Ratio over time (NA : alcoholic)". Aqua, because the ratio is the
/// NA story; the goal line is neutral ink so it reads as a reference.
struct TrendsRatioChart: View {

    let points: [TrendsRatioPoint]
    let goal: Double

    private struct Plotted: Identifiable {
        let id: Date
        let ratio: Double
    }

    private var plotted: [Plotted] {
        points.compactMap { point in
            point.ratio.map { Plotted(id: point.weekStart, ratio: $0) }
        }
    }

    private var yMax: Double {
        max(goal * 2, (plotted.map(\.ratio).max() ?? 0) * 1.2, 2)
    }

    var body: some View {
        if plotted.isEmpty {
            TrendsChartNote(
                text: points.isEmpty
                    ? "No weeks to compare yet."
                    : "No alcoholic drinks in this window — nothing to pace against."
            )
        } else {
            Chart {
                RuleMark(y: .value("Goal", goal))
                    .foregroundStyle(TallyColor.inkTertiary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("goal \(TrendsMath.decimalRatioText(goal))")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(TallyColor.inkTertiary)
                    }
                    .accessibilityHidden(true)

                ForEach(plotted) { point in
                    AreaMark(
                        x: .value("Week", point.id),
                        y: .value("NA per drink", point.ratio)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [TallyColor.aqua.opacity(0.30), TallyColor.aqua.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                    .accessibilityHidden(true)
                }

                ForEach(plotted) { point in
                    LineMark(
                        x: .value("Week", point.id),
                        y: .value("NA per drink", point.ratio)
                    )
                    .foregroundStyle(TallyColor.aquaBright)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                    .symbol(.circle)
                    .symbolSize(12)
                    .accessibilityLabel("Week of \(point.id.formatted(.dateTime.month(.abbreviated).day()))")
                    .accessibilityValue("\(point.ratio.formatted(.number.precision(.fractionLength(0...1)))) non-alcoholic per alcoholic drink")
                }
            }
            .chartYScale(domain: 0...yMax)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                    AxisGridLine().foregroundStyle(TallyColor.line)
                    AxisValueLabel()
                        .font(.system(size: 8.5).monospacedDigit())
                        .foregroundStyle(TallyColor.inkTertiary)
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .weekOfYear, count: 3)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date.formatted(.dateTime.month(.abbreviated).day()))
                                .font(.system(size: 8.5))
                                .foregroundStyle(TallyColor.inkTertiary)
                        }
                    }
                }
            }
            .frame(height: 110)
            .accessibilityLabel("Non-alcoholic to alcoholic ratio by week, against your goal")
        }
    }
}

// MARK: - By venue

/// SPEC §4: "By-venue breakdown — where your drinks happen (Home vs bars vs
/// everything else)."
struct TrendsVenueChart: View {

    let rows: [TrendsVenueRow]

    private struct Segment: Identifiable {
        let id: String
        let venue: String
        let series: String
        let count: Int
    }

    private var segments: [Segment] {
        rows.flatMap { row -> [Segment] in
            var out: [Segment] = []
            if row.alcoholic > 0 {
                out.append(Segment(id: "\(row.id)-a", venue: row.name, series: TrendsSeries.alcoholic, count: row.alcoholic))
            }
            if row.nonAlcoholic > 0 {
                out.append(Segment(id: "\(row.id)-n", venue: row.name, series: TrendsSeries.nonAlcoholic, count: row.nonAlcoholic))
            }
            return out
        }
    }

    var body: some View {
        if rows.isEmpty {
            TrendsChartNote(text: "No drinks in the last 90 days.")
        } else {
            Chart(segments) { segment in
                BarMark(
                    x: .value("Drinks", segment.count),
                    y: .value("Venue", segment.venue)
                )
                .foregroundStyle(by: .value("Series", segment.series))
                .cornerRadius(3)
                .accessibilityLabel(segment.venue)
                .accessibilityValue("\(segment.count) \(segment.series)")
            }
            .chartForegroundStyleScale(TrendsSeries.scale)
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(TallyColor.line)
                    AxisValueLabel()
                        .font(.system(size: 8.5).monospacedDigit())
                        .foregroundStyle(TallyColor.inkTertiary)
                }
            }
            .chartYAxis {
                AxisMarks(preset: .aligned, position: .leading) {
                    AxisValueLabel()
                        .font(.system(size: 9.5))
                        .foregroundStyle(TallyColor.inkSecondary)
                }
            }
            .frame(height: CGFloat(rows.count) * 26 + 26)
            .accessibilityLabel("Drinks by venue over the last 90 days")
        }
    }
}

// MARK: - Hour × weekday heatmap

/// SPEC §4: "Time-of-day heatmap (hour × weekday)". A sequential amber ramp —
/// the cells count alcoholic drinks, so amber is the only honest hue.
struct TrendsHeatmap: View {

    let cells: [TrendsHeatmapCell]
    var calendar: Calendar = .current

    private var peak: Int { max(cells.map(\.count).max() ?? 0, 1) }
    private var symbols: [String] { TrendsMath.weekdaySymbols(calendar: calendar) }

    private func intensity(_ count: Int) -> Double {
        guard count > 0 else { return 0 }
        // Square-root ramp: one drink at 3 am should still be visible next to a
        // Friday-night pile-up.
        return 0.22 + 0.78 * (Double(count) / Double(peak)).squareRoot()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart(cells) { cell in
                RectangleMark(
                    xStart: .value("Hour", Double(cell.hour)),
                    xEnd: .value("Hour end", Double(cell.hour) + 1),
                    yStart: .value("Day", Double(cell.weekdayIndex)),
                    yEnd: .value("Day end", Double(cell.weekdayIndex) + 1)
                )
                .foregroundStyle(
                    cell.count > 0
                        ? TallyColor.amber.opacity(intensity(cell.count))
                        : Color.white.opacity(0.035)
                )
                .accessibilityLabel("\(symbol(cell.weekdayIndex)) \(hourLabel(cell.hour))")
                .accessibilityValue(cell.count == 1 ? "1 drink" : "\(cell.count) drinks")
                .accessibilityHidden(cell.count == 0)
            }
            .chartXScale(domain: 0.0...24.0)
            .chartYScale(domain: 0.0...7.0)
            .chartXAxis {
                AxisMarks(values: [0.0, 6.0, 12.0, 18.0, 24.0]) { value in
                    AxisValueLabel {
                        if let hour = value.as(Double.self) {
                            Text(hourLabel(Int(hour) % 24))
                                .font(.system(size: 8.5))
                                .foregroundStyle(TallyColor.inkTertiary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: (0..<7).map { Double($0) + 0.5 }) { value in
                    AxisValueLabel {
                        if let row = value.as(Double.self) {
                            Text(symbol(Int(row)))
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(TallyColor.inkTertiary)
                        }
                    }
                }
            }
            .frame(height: 132)
            .accessibilityLabel("Alcoholic drinks by hour and weekday over the last 90 days")

            intensityKey
        }
    }

    private var intensityKey: some View {
        HStack(spacing: 5) {
            Text("Less")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(TallyColor.inkTertiary)
            ForEach([0.0, 0.35, 0.6, 0.8, 1.0], id: \.self) { step in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(step == 0 ? Color.white.opacity(0.035) : TallyColor.amber.opacity(step))
                    .frame(width: 11, height: 8)
            }
            Text("More")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(TallyColor.inkTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cell shade runs from no drinks to \(peak) drinks in one hour")
    }

    private func symbol(_ index: Int) -> String {
        let list = symbols
        guard list.indices.contains(index) else { return "" }
        return list[index]
    }

    private func hourLabel(_ hour: Int) -> String {
        switch hour {
        case 0: "12a"
        case 12: "12p"
        case let h where h < 12: "\(h)a"
        default: "\(hour - 12)p"
        }
    }
}

// MARK: - Note

/// What a chart says instead of drawing an axis over nothing.
struct TrendsChartNote: View {

    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(TallyColor.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 14)
    }
}
