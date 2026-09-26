import SwiftUI
import TallyKit

// The suppression curve card (SPEC §4 "Recovery context · Suppression curve
// card"), rebuilt on `TallyKit.SuppressionTimeline`.
//
// What it shows is the *whole episode* — first drink → rise → peak → decline →
// 0 — rather than a window around the clock, so opening the app the next
// morning still shows where the night began and how much of the recovery is
// left. Time passing moves the Now marker along the curve instead of sliding
// the beginning of it offscreen.
//
// Three rules from SPEC §4's honesty section govern everything below:
// * every caption carries the word **"modeled"** — this is a rendering of
//   published population dose-response, never a measurement;
// * **amber intensity only, never green** — no colour here can be read as
//   permission, and the elapsed curve is never drained to neutral just because
//   the model is back inside its baseline band;
// * the numbers are **display values** — `max(0, raw − baselineThreshold)`,
//   the scale the axis is labelled with — never percentages and never the raw
//   index.

// MARK: - Accessibility

/// The card's identifiers.
///
/// They belong next to `A11y.Tally.sessionCard`, but the *strings* are the
/// contract either way, so folding this into `A11y.Tally` later is a pure move.
enum SuppressionCardA11y {
    static let card = "tally.suppressionCard"
    static let detailSheet = "tally.suppressionDetail"
    static let detailChart = "tally.suppressionDetail.chart"
    static let detailDoneButton = "tally.suppressionDetail.doneButton"
}

// MARK: - Card

/// The Tally screen's recovery card (SPEC §4).
///
/// Mounted unconditionally below the live Session card; it decides for itself
/// whether it exists. The hidden branch is a bare `EmptyView` with no modifiers
/// attached, which is what keeps the promise of *zero footprint* literal — a
/// zero-height-but-present view would still earn the enclosing `VStack`'s
/// spacing on both sides.
///
/// With recovery context on it is always there: the active episode, else the
/// most recent one however long ago it ended (`SuppressionTimeline.makeLatest`),
/// so the last night's shape — and when it returned to baseline — is one
/// glance away instead of vanishing 24 h later. The widget keeps the 24 h
/// retention; it has no room for a curve that is old news.
struct SuppressionCurveCard: View {

    /// The full log. Episode selection is the timeline's job — there is no
    /// rolling cutoff here to silently drop a prolonged episode's first drinks.
    let events: [DrinkEventSnapshot]

    var model: FibrinolysisModel = FibrinolysisModel()

    /// The design's 140–160 pt window, at its target. It stays 150 on every
    /// device because the Tally screen scrolls its context rather than
    /// squeezing the chart; the knob is here for a caller that needs less.
    var chartHeight: CGFloat = SuppressionCurveCard.preferredChartHeight

    static let preferredChartHeight: CGFloat = 150

    /// Mirrored into `.standard` by `RecoveryContext.setEnabled`, so flipping
    /// the Settings toggle repaints this card without a relaunch.
    @AppStorage(RecoveryContext.enabledKey) private var isRecoveryEnabled = false

    /// The clock. `LiveSessionCard` gets this from a `TimelineView`, which is
    /// the better tool when the view is already on screen for good — here the
    /// card has to be able to *retire itself*, and a `TimelineView` cannot do
    /// that without leaving its slot (and its stack spacing) behind.
    @State private var now = Date()
    @State private var isExpanded = false

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

    private static let tick: TimeInterval = 60

    var body: some View {
        // Nothing below this line runs while the toggle is off — the model is
        // not even asked (SPEC §4: zero footprint when off).
        if isRecoveryEnabled, let timeline = SuppressionTimeline.makeLatest(now: now, events: events, model: model) {
            card(timeline)
                .task(id: refreshKey) {
                    // Keeps the Now marker, the clock times, and the card's own
                    // existence honest between logged events.
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(Self.tick))
                        guard !Task.isCancelled else { return }
                        now = Date()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Coming back from the background can be hours later; the
                    // 60 s tick was suspended for all of it.
                    if phase == .active { now = Date() }
                }
                .sheet(isPresented: $isExpanded) {
                    SuppressionDetailSheet(timeline: timeline)
                }
        }
    }

    /// Restarts the ticker whenever the log's *content* changes.
    ///
    /// Deliberately not `events.count`: editing a drink's timestamp or type, or
    /// undoing one and logging another, leaves the count alone while changing
    /// the episode — and can merge or split episodes outright.
    private var refreshKey: Int {
        var hasher = Hasher()
        for event in events where event.type == .alcoholic {
            hasher.combine(event.id)
            hasher.combine(event.timestamp)
            hasher.combine(event.type)
        }
        return hasher.finalize()
    }

    // MARK: Layout

    private func card(_ timeline: SuppressionTimeline) -> some View {
        let summary = SuppressionSummary(timeline)

        return Button {
            isExpanded = true
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                header(summary)

                Text(SuppressionSummary.yAxisLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(TallyColor.inkTertiary)

                SuppressionChart(timeline: timeline)
                    .frame(height: chartHeight)

                SuppressionFactsRow(facts: summary.facts(calendar: calendar, locale: locale))

                if let footnote = summary.footnote {
                    Text(footnote)
                        .font(.system(size: 9))
                        .foregroundStyle(TallyColor.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tallyGlassCard()
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(SuppressionCardA11y.card)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(summary.voiceOverSummary(calendar: calendar, locale: locale))
        .accessibilityHint("Opens the expanded chart")
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func header(_ summary: SuppressionSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(SuppressionSummary.header)
                .font(.caption.weight(.medium))
                .foregroundStyle(TallyColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Text(summary.stateText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(stateTint(summary.state))
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(TallyColor.inkTertiary)
        }
    }

    /// Amber while there is something to say, neutral ink at baseline — the
    /// second half of SPEC §4's colour rule, and the reason no state word can
    /// ever be green.
    private func stateTint(_ state: SuppressionTimeline.State) -> Color {
        state == .atBaseline ? TallyColor.inkSecondary : TallyColor.amberBright
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

enum SuppressionCurvePreview {
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
