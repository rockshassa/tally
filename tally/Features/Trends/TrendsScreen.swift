import SwiftData
import SwiftUI
import TallyKit

/// The Trends tab (SPEC §4).
///
/// Everything on this screen is derived on the spot from the event log through
/// `SessionDeriver` and `ScoringEngine` — SPEC §1's "derive, don't store" means
/// there is no chart cache, no aggregate row, and nothing to conflict-resolve
/// when devices merge.
///
/// ## Mounting it
///
/// ```swift
/// Tab("Trends", systemImage: "chart.bar.xaxis", value: RootTab.trends) {
///     NavigationStack { TrendsScreen() }
/// }
/// ```
///
/// ## The Wave 3 insights slot
///
/// `insights` is the mount point for M10's HealthKit cards and the "Connect
/// Health" placeholder (SPEC §4 "Surfaces: insight cards at the top of the
/// Trends tab", SPEC §9's just-in-time HealthKit ask). It defaults to
/// `EmptyView`, so the screen is complete without it:
///
/// ```swift
/// TrendsScreen { HealthInsightsSection() }
/// ```
///
/// The slot renders above the segmented control and below nothing — it is
/// literally the top of the scroll view — and Wave 3 owns everything inside it.
public struct TrendsScreen<Insights: View>: View {

    // MARK: Inputs

    private let injectedModel: TrendsModel?

    /// Pinned only by fixtures. `nil` — the shipping case — reads the clock at
    /// reload time, so a tab left open overnight redraws against the new today
    /// instead of yesterday's.
    private let pinnedNow: Date?

    private let insights: () -> Insights

    @Environment(\.modelContext) private var modelContext
    @State private var model: TrendsModel?

    /// SPEC §4's recovery context. The tile below is gated on this rather than on
    /// `data.suppression` alone so flipping the toggle in Settings repaints the
    /// grid immediately — `onChange` recomputes, and the `nil` case covers the
    /// instant in between.
    @AppStorage(RecoveryContext.enabledKey) private var recoveryEnabled = false

    public init(
        now: Date? = nil,
        model: TrendsModel? = nil,
        @ViewBuilder insights: @escaping () -> Insights
    ) {
        self.pinnedNow = now
        self.injectedModel = model
        self.insights = insights
    }

    private var now: Date { pinnedNow ?? Date() }

    // MARK: Body

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {

                // ── Wave 3 (M10) mounts HealthKit insight cards here ──────────
                // SPEC §4: insight cards sit at the top of the Trends tab.
                // Empty by default; nothing below depends on it.
                insights()
                    .accessibilityIdentifier(TrendsA11y.insightsSlot)
                // ─────────────────────────────────────────────────────────────

                if let model, model.hasLoaded {
                    content(model: model)
                }
            }
            .padding(.horizontal, TallyMetrics.screenPadding - 4)
            .padding(.top, 4)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(TallyColor.pageGradient.ignoresSafeArea())
        .navigationTitle("Trends")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(TrendsA11y.screen)
        .task { prepare() }
        .onAppear { model?.reload(asOf: now) }
        .onChange(of: recoveryEnabled) { _, _ in model?.reload(asOf: now) }
    }

    @ViewBuilder
    private func content(model: TrendsModel) -> some View {
        let data = model.data

        TrendsGranularityPicker(
            selection: Binding(
                get: { model.granularity },
                set: { model.granularity = $0 }
            )
        )
        .padding(.bottom, 2)

        if data.isEmpty {
            TrendsEmptyState()
        } else {
            drinksSection(data: data)
            tileGrid(data.tiles, suppression: data.suppression)
            ratioSection(data: data)
            venueSection(data: data)
            heatmapSection(data: data)
            sessionSection(data.sessionStats)
        }
    }

    // MARK: Sections

    private func drinksSection(data: TrendsData) -> some View {
        TrendsCard(
            title: "Drinks per \(data.granularity.title.lowercased())",
            subtitle: data.granularity.chartSubtitle,
            identifier: TrendsA11y.drinksChart
        ) {
            TrendsDrinksChart(buckets: data.buckets, granularity: data.granularity)
            TrendsLegend(averageLabel: data.granularity.averageLegendLabel)
        }
    }

    /// SPEC §4: "this week vs last week, longest dry streak, current streak,
    /// most frequent venue" — plus the two headline numbers from the mockup.
    private func tileGrid(_ tiles: TrendsTileSet, suppression: TrendsSuppression?) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {

            TrendsStatTile(
                key: "This week",
                value: "\(tiles.thisWeekAlcoholic)",
                delta: weekDeltaText(tiles),
                deltaTone: tone(forChange: tiles.weekDelta)
            )

            TrendsStatTile(
                key: "7-day avg",
                value: tiles.sevenDayAverage.formatted(.number.precision(.fractionLength(0...1))),
                unit: "/day",
                delta: averageDeltaText(tiles),
                deltaTone: tone(forChange: tiles.averageDelta)
            )

            TrendsStatTile(
                key: "NA ratio",
                value: TrendsMath.decimalRatioText(tiles.weekRatio),
                delta: "goal \(TrendsMath.decimalRatioText(tiles.ratioGoal))\(tiles.meetsRatioGoal ? " ✓" : "")",
                deltaTone: tiles.meetsRatioGoal ? .good : .neutral
            )

            TrendsStatTile(
                key: "Current streak",
                value: "\(tiles.currentStreak)",
                unit: tiles.currentStreak == 1 ? "day" : "days",
                delta: "ratio goal met",
                deltaTone: tiles.currentStreak > 0 ? .good : .neutral
            )

            TrendsStatTile(
                key: "Dry streak",
                value: "\(tiles.currentDryStreak)",
                unit: tiles.currentDryStreak == 1 ? "day" : "days",
                delta: "longest \(tiles.longestDryStreak)",
                deltaTone: .neutral
            )

            TrendsStatTile(
                key: "Top venue",
                value: tiles.topVenueName ?? "—",
                delta: tiles.topVenueName == nil
                    ? "no tagged venues yet"
                    : (tiles.topVenueSessionCount == 1 ? "1 Session" : "\(tiles.topVenueSessionCount) Sessions"),
                deltaTone: .neutral,
                valueSize: 13
            )

            // SPEC §4's recovery context: one more tile, and only when the layer
            // is on. Everything above is untouched by it.
            if recoveryEnabled, let suppression {
                TrendsStatTile(
                    key: "Modeled suppression",
                    value: suppression.thisWeekHours.formatted(.number.precision(.fractionLength(0...1))),
                    unit: "h",
                    delta: suppressionDeltaText(suppression),
                    deltaTone: suppressionTone(suppression)
                )
                .accessibilityIdentifier(TrendsA11y.suppressionTile)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(TrendsA11y.statTiles)
    }

    private func ratioSection(data: TrendsData) -> some View {
        TrendsCard(
            title: "NA : alcoholic over time",
            subtitle: "Non-alcoholic drinks per alcoholic drink, by week",
            identifier: TrendsA11y.ratioChart
        ) {
            TrendsRatioChart(points: data.ratioPoints, goal: data.tiles.ratioGoal)
        }
    }

    private func venueSection(data: TrendsData) -> some View {
        TrendsCard(
            title: "Where it happens",
            subtitle: "Last 90 days · untagged nights included",
            identifier: TrendsA11y.venueChart
        ) {
            TrendsVenueChart(rows: data.venueRows)
            if !data.venueRows.isEmpty {
                TrendsLegend()
            }
        }
    }

    private func heatmapSection(data: TrendsData) -> some View {
        TrendsCard(
            title: "When it happens",
            subtitle: "Alcoholic drinks by hour and weekday · last 90 days",
            identifier: TrendsA11y.heatmap
        ) {
            TrendsHeatmap(cells: data.heatmap)
        }
    }

    /// SPEC §4 Session stats.
    private func sessionSection(_ stats: TrendsSessionStats) -> some View {
        TrendsCard(
            title: "Sessions",
            subtitle: "Last 90 days",
            identifier: TrendsA11y.sessionStats
        ) {
            if stats.sessionCount == 0 {
                TrendsChartNote(text: "No Sessions in the last 90 days.")
            } else {
                VStack(spacing: 0) {
                    TrendsStatRow(
                        label: "Avg drinks per Session",
                        value: stats.averageAlcoholicPerSession.formatted(.number.precision(.fractionLength(0...1))),
                        detail: "\(stats.sessionCount) Session\(stats.sessionCount == 1 ? "" : "s")"
                    )
                    Divider().overlay(TallyColor.line)
                    TrendsStatRow(
                        label: "Sessions per week",
                        value: stats.sessionsPerWeek.formatted(.number.precision(.fractionLength(0...1)))
                    )
                    Divider().overlay(TallyColor.line)
                    TrendsStatRow(
                        label: "Longest Session",
                        value: stats.longest?.headline ?? "—",
                        detail: stats.longest?.detail
                    )
                    Divider().overlay(TallyColor.line)
                    TrendsStatRow(
                        label: "Best paced",
                        value: stats.bestPaced?.headline ?? "—",
                        detail: stats.bestPaced?.detail ?? "spacers per drink, once a Session has two"
                    )
                }
            }
        }
    }

    // MARK: Deltas

    /// SPEC §5's tone rules apply to numbers too: state the movement, never
    /// judge it. Aqua for down, amber for up, neither of them a verdict.
    private func tone(forChange change: Int) -> TrendsStatTile.Tone {
        if change < 0 { return .good }
        if change > 0 { return .rising }
        return .neutral
    }

    private func tone(forChange change: Double) -> TrendsStatTile.Tone {
        if change < -0.05 { return .good }
        if change > 0.05 { return .rising }
        return .neutral
    }

    private func weekDeltaText(_ tiles: TrendsTileSet) -> String {
        let delta = tiles.weekDelta
        if delta == 0 { return "same as last week" }
        return "\(delta < 0 ? "▼" : "▲") \(abs(delta)) vs last week"
    }

    private func averageDeltaText(_ tiles: TrendsTileSet) -> String {
        let delta = tiles.averageDelta
        let magnitude = abs(delta).formatted(.number.precision(.fractionLength(0...1)))
        if abs(delta) < 0.05 { return "flat" }
        return "\(delta < 0 ? "▼" : "▲") \(magnitude)"
    }

    /// Hours above baseline, this week against last. Half an hour of dead band:
    /// the model is a population curve sampled every fifteen minutes, and it
    /// would be dishonest to render a ten-minute difference as movement.
    private func suppressionDeltaText(_ suppression: TrendsSuppression) -> String {
        let delta = suppression.deltaHours
        guard abs(delta) >= 0.5 else { return "same as last week" }
        let magnitude = abs(delta).formatted(.number.precision(.fractionLength(0...1)))
        return "\(delta < 0 ? "▼" : "▲") \(magnitude) h vs last week"
    }

    /// Same convention as every other tile on this screen — aqua for down, amber
    /// for up, neither of them a verdict. Down here means fewer modeled hours
    /// above baseline; it is not a clot-risk score and it does not say "safe"
    /// (SPEC §4 honesty rules).
    private func suppressionTone(_ suppression: TrendsSuppression) -> TrendsStatTile.Tone {
        let delta = suppression.deltaHours
        if delta <= -0.5 { return .good }
        if delta >= 0.5 { return .rising }
        return .neutral
    }

    // MARK: Plumbing

    /// Builds the model once. Every later visit refreshes through `onAppear`,
    /// which is what keeps the charts current after drinks logged on the Tally
    /// tab, from the widget, or from the watch.
    private func prepare() {
        guard model == nil else { return }
        let created = injectedModel ?? TrendsModel(modelContext: modelContext, now: now)
        created.reload(asOf: now)
        model = created
    }
}

// MARK: - No-insights convenience

public extension TrendsScreen where Insights == EmptyView {

    /// The shipping configuration until Wave 3 lands its HealthKit cards.
    init(now: Date? = nil, model: TrendsModel? = nil) {
        self.init(now: now, model: model) { EmptyView() }
    }
}

// MARK: - Previews

#Preview("Trends — empty store") {
    NavigationStack {
        TrendsScreen()
    }
    .preferredColorScheme(.dark)
    .modelContainer(PreviewStore.container)
}
