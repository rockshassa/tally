import Charts
import SwiftUI
import TallyKit

/// SPEC §4's modeled suppression curve across the Trends window: the Tally
/// card's episode chart, stretched to whatever the Day / Week / Month picker
/// covers, on the same x-span as the drinks chart above it.
///
/// Same honesty rules as the card: amber only, never green; the numbers are
/// display values on the scale the subtitle names; the part that has not
/// happened yet is dashed, because it is a forecast of the model rather than
/// of anything observed.
struct TrendsSuppressionChart: View {

    let series: TrendsSuppressionSeries
    let granularity: TrendsGranularity

    private var past: [TrendsSuppressionPoint] {
        // Carries the first point after `now` too, so the solid and dashed
        // halves meet instead of leaving a gap.
        let cut = series.points.firstIndex { $0.date > series.now } ?? series.points.endIndex
        return Array(series.points[..<min(cut + 1, series.points.endIndex)])
    }

    private var future: [TrendsSuppressionPoint] {
        let cut = series.points.lastIndex { $0.date <= series.now } ?? series.points.startIndex
        return Array(series.points[cut...])
    }

    /// Same headroom and floor as the Tally card, so a light fortnight is not
    /// magnified into a heavy one.
    private var yMax: Double {
        max(series.peak * SuppressionChartGeometry.headroom, SuppressionChartGeometry.minimumTop)
    }

    private var fill: LinearGradient {
        LinearGradient(
            colors: [TallyColor.amber.opacity(0.4), TallyColor.amber.opacity(0.03)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        if series.peak <= 0 {
            TrendsChartNote(text: "No modeled suppression in this window.")
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart {
            ForEach(series.points, id: \.date) { point in
                AreaMark(
                    x: .value("Time", point.date),
                    y: .value(SuppressionSummary.yAxisLabel, point.display)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(fill)
            }

            ForEach(past, id: \.date) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value(SuppressionSummary.yAxisLabel, point.display),
                    series: .value("Curve", "elapsed")
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .foregroundStyle(TallyColor.amberBright)
            }

            ForEach(future, id: \.date) { point in
                LineMark(
                    x: .value("Time", point.date),
                    y: .value(SuppressionSummary.yAxisLabel, point.display),
                    series: .value("Curve", "forecast")
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [4, 3]))
                .foregroundStyle(TallyColor.amberBright.opacity(0.85))
            }

            if series.range.contains(series.now) {
                RuleMark(x: .value("Now", series.now))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(TallyColor.inkSecondary.opacity(0.6))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: series.range)
        .chartYScale(domain: 0...yMax)
        .chartYAxis { SuppressionYAxis.marks(isExpanded: false) }
        .chartXAxis {
            AxisMarks(values: .stride(by: granularity.unit, count: strideCount)) { value in
                AxisGridLine().foregroundStyle(TallyColor.line.opacity(0.5))
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // Matches `TrendsDrinksChart`, so the two charts' labels line up.
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

    private var accessibilityText: String {
        let peak = series.points.max { $0.display < $1.display }
        let peakText = peak.map {
            "highest \(SuppressionYAxis.label($0.display)) on \($0.date.formatted(.dateTime.month(.abbreviated).day()))"
        } ?? ""
        return "Modeled suppression above baseline, \(granularity.chartSpan). \(peakText)"
    }
}

extension TrendsGranularity {

    /// The span the Trends charts cover, in words — "last 14 days".
    var chartSpan: String {
        switch self {
        case .day: "last 14 days"
        case .week: "last 12 weeks"
        case .month: "last 12 months"
        }
    }

    /// The same, opening a subtitle — "Last 14 days".
    var chartSpanTitle: String {
        switch self {
        case .day: "Last 14 days"
        case .week: "Last 12 weeks"
        case .month: "Last 12 months"
        }
    }
}
