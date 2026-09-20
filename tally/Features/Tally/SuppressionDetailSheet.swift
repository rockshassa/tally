import Charts
import SwiftUI
import TallyKit

/// The expanded episode chart: the same timeline the card draws, with room for
/// the annotations the card cannot fit and a way to read a value off the curve.
///
/// Opened from the Tally card, and from Session detail's **Recovery timeline**
/// row — where the Session's own drinks are highlighted inside an episode that
/// may be longer than the night.
///
/// Inspection has two paths on purpose. Dragging is the direct one; the
/// `accessibilityAdjustableAction` steps through the episode's anchors — first
/// drink, each drawn tick, the peak, now, the modeled return — so the chart is
/// readable with VoiceOver without a gesture that VoiceOver has taken over.
struct SuppressionDetailSheet: View {

    let timeline: SuppressionTimeline

    /// The drinks belonging to the Session that opened this sheet, if any.
    var highlightedEventIDs: Set<UUID> = []

    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    /// The inspected instant, from a drag or from the accessible stepper.
    @State private var selection: Date?

    /// Where the accessible stepper is standing, so it resumes rather than
    /// restarting after a drag.
    @State private var anchorIndex: Int?

    private static let chartHeight: CGFloat = 260

    private var summary: SuppressionSummary { SuppressionSummary(timeline) }

    private var anchors: [SuppressionTimeline.Sample] {
        SuppressionChartGeometry.anchors(for: timeline)
    }

    private var selectedSample: SuppressionTimeline.Sample? {
        selection.flatMap { SuppressionChartGeometry.sample(at: $0, in: timeline) }
    }

    /// What the inspection says, or the invitation to inspect.
    private var readout: String? {
        selectedSample.map {
            SuppressionSummary.readout(
                display: $0.display,
                at: $0.date,
                relativeTo: timeline.now,
                calendar: calendar,
                locale: locale
            )
        }
    }

    // MARK: Body

    var body: some View {
        ZStack {
            TallyColor.pageGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        chart
                        readoutLine
                        SuppressionFactsRow(
                            facts: summary.facts(calendar: calendar, locale: locale),
                            labelSize: 10,
                            valueSize: 14
                        )
                        notes
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)

                Button("Done") { dismiss() }
                    .buttonStyle(TallyPrimaryButtonStyle(tint: TallyColor.amberBright.opacity(0.9)))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier(SuppressionCardA11y.detailDoneButton)
            }
        }
        .presentationBackground(TallyColor.background)
        .presentationDragIndicator(.visible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SuppressionCardA11y.detailSheet)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(SuppressionSummary.header)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(TallyColor.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Text(summary.stateText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(
                        summary.state == .atBaseline ? TallyColor.inkSecondary : TallyColor.amberBright
                    )
            }

            Text(SuppressionSummary.yAxisLabel)
                .font(.system(size: 11))
                .foregroundStyle(TallyColor.inkTertiary)
        }
        .padding(.top, 10)
    }

    // MARK: Chart

    private var chart: some View {
        SuppressionChart(
            timeline: timeline,
            isExpanded: true,
            highlightedEventIDs: highlightedEventIDs,
            selection: selection
        )
        .frame(height: Self.chartHeight)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                inspect(at: value.location.x, proxy: proxy, geometry: geometry)
                            }
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(SuppressionCardA11y.detailChart)
        .accessibilityLabel(summary.voiceOverSummary(calendar: calendar, locale: locale))
        .accessibilityValue(readout ?? "Not inspected")
        .accessibilityHint("Swipe up or down to step through the episode")
        // The non-drag path: VoiceOver owns the touch, so the chart offers the
        // same story through its anchors instead.
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(by: 1)
            case .decrement: step(by: -1)
            @unknown default: break
            }
        }
    }

    /// Maps a touch to an instant on the curve, clamped to the plotted range so
    /// a finger off the edge reads the endpoint rather than nothing.
    private func inspect(at x: CGFloat, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let origin = geometry[plotFrame].origin
        guard let date = proxy.value(atX: x - origin.x, as: Date.self) else { return }
        selection = min(max(date, timeline.range.lowerBound), timeline.range.upperBound)
        anchorIndex = nil
    }

    private func step(by delta: Int) {
        guard !anchors.isEmpty else { return }
        let current = anchorIndex ?? nearestAnchorIndex()
        let next = min(max(current + delta, 0), anchors.count - 1)
        anchorIndex = next
        selection = anchors[next].date
    }

    /// Picks up where a drag left off, so the two inspection paths share one
    /// position instead of fighting over it.
    private func nearestAnchorIndex() -> Int {
        guard let selection else { return 0 }
        return anchors.indices.min {
            abs(anchors[$0].date.timeIntervalSince(selection))
                < abs(anchors[$1].date.timeIntervalSince(selection))
        } ?? 0
    }

    // MARK: Readout

    /// Fixed height so the layout does not jump between "nothing selected" and
    /// a reading.
    private var readoutLine: some View {
        HStack(spacing: 6) {
            Text(readout ?? "Touch the chart to read a modeled value")
                .font(.system(size: 13, weight: readout == nil ? .regular : .medium).monospacedDigit())
                .foregroundStyle(readout == nil ? TallyColor.inkTertiary : TallyColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Spacer(minLength: 0)

            if selection != nil {
                Button("Clear") {
                    selection = nil
                    anchorIndex = nil
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TallyColor.inkTertiary)
                .buttonStyle(.plain)
            }
        }
        .frame(height: 20)
        .accessibilityHidden(true)
    }

    // MARK: Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let plateau = summary.plateauText(calendar: calendar, locale: locale) {
                note(plateau)
            }
            if let footnote = summary.footnote {
                note(footnote)
            }
            note(SuppressionSummary.infoText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyGlassCard()
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(TallyColor.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Preview

#Preview {
    let events = SuppressionCurvePreview.events
    return Color.clear
        .sheet(isPresented: .constant(true)) {
            if let timeline = SuppressionTimeline.make(now: Date(), events: events) {
                SuppressionDetailSheet(timeline: timeline)
            }
        }
        .preferredColorScheme(.dark)
}
