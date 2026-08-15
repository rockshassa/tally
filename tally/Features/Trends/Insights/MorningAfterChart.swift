import Charts
import SwiftUI

/// SPEC §4's morning-after comparison: *"drinking-day-after vs dry-day-after
/// activity, side by side."*
///
/// Two bars, because there are two numbers. A two-category comparison is the one
/// case where bars beat every other mark, and adding a trend line, an axis of
/// dates, or a third reference series would be decoration — the finding is
/// entirely contained in "this one vs that one".
///
/// **Colour.** The rest of the app spends amber on alcohol and aqua on
/// everything else, and this chart keeps that: the bar for days after a drinking
/// night is amber, the baseline bar is aqua. It is a categorical mapping the user
/// has already learned on the counter, not a good/bad scale — SPEC §5's tone
/// rules mean the amber bar is a fact, not a scold.
struct MorningAfterChart: View {

    let comparison: HealthInsightComparison

    private struct Bar: Identifiable {
        let id: String
        let label: String
        let value: Double
        let dayCount: Int
        let color: Color
    }

    private var bars: [Bar] {
        [
            Bar(
                id: "drinking",
                label: "After \(comparison.threshold)+ drinks",
                value: comparison.afterDrinking,
                dayCount: comparison.drinkingDayCount,
                color: TallyColor.amber
            ),
            Bar(
                id: "dry",
                label: "After dry nights",
                value: comparison.afterDry,
                dayCount: comparison.dryDayCount,
                color: TallyColor.aqua
            )
        ]
    }

    /// Floored so a comparison of two small numbers still draws two readable
    /// bars rather than one hairline and one full-height block.
    private var xMax: Double {
        let peak = bars.map(\.value).max() ?? 0
        return max(peak * 1.25, 1)
    }

    var body: some View {
        Chart(bars) { bar in
            BarMark(
                x: .value(comparison.metric.axisLabel, bar.value),
                y: .value("Group", bar.label)
            )
            .foregroundStyle(bar.color)
            .cornerRadius(3)
            .annotation(position: .trailing, alignment: .leading, spacing: 5) {
                Text(comparison.metric.formatted(bar.value))
                    .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(TallyColor.ink)
            }
            .accessibilityLabel(bar.label)
            .accessibilityValue("\(comparison.metric.formatted(bar.value)) over \(bar.dayCount) days")
        }
        .chartXScale(domain: 0...xMax)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisValueLabel()
                    .font(.system(size: 9.5))
                    .foregroundStyle(TallyColor.inkSecondary)
            }
        }
        .chartPlotStyle { plot in
            plot.padding(.trailing, 46)
        }
        .frame(height: 66)
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(InsightsA11y.morningAfterChart)
        .accessibilityLabel("Morning-after \(comparison.metric.subject), by night type")
    }
}

#Preview("Morning after") {
    ZStack {
        TallyColor.pageGradient.ignoresSafeArea()
        MorningAfterChart(
            comparison: HealthInsightComparison(
                metric: .exerciseMinutes,
                afterDrinking: 12,
                afterDry: 34,
                drinkingDayCount: 11,
                dryDayCount: 29,
                threshold: 3
            )
        )
        .padding(24)
    }
    .preferredColorScheme(.dark)
}
