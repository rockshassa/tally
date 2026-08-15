import SwiftData
import SwiftUI
import TallyKit

/// SPEC §4's health insights, as they appear at the top of the Trends tab.
///
/// ## Mounting it
///
/// ```swift
/// Tab("Trends", systemImage: "chart.bar.xaxis", value: RootTab.trends) {
///     NavigationStack {
///         TrendsScreen { HealthInsightsSection() }
///     }
/// }
/// ```
///
/// That is the whole integration on the Trends side — `TrendsScreen` is generic
/// over its insights slot and this view fills it. Nothing else on the screen
/// depends on it (SPEC §4: *"Nothing else in the app depends on this feature"*).
///
/// ## What it renders
///
/// | State | Renders |
/// |---|---|
/// | HealthKit unavailable | nothing |
/// | Reads never granted, or revoked | the "Connect Health" card (SPEC §9) |
/// | Connected, nothing cleared the guardrails | nothing — *"Absence is fine"* |
/// | Qualifying correlations | one card each, morning-after first, with its chart |
///
/// Three of those four are silence or an offer, which is the intended ratio:
/// SPEC §4 spends a paragraph establishing that *"no insight is better than a
/// spurious one"*.
///
/// ## Refresh
///
/// On appear, on `scenePhase` returning to `.active`, and on every
/// `HKObserverQuery` ping. Each refresh is a fresh HealthKit read and a fresh
/// derivation — nothing about the user's Health data is stored between them
/// (SPEC §10).
public struct HealthInsightsSection: View {

    // MARK: Inputs

    private let injectedModel: HealthInsightsModel?
    private let injectedProvider: (any HealthDataProviding)?
    private let injectedPermissions: (any PermissionsService)?

    /// Pinned only by fixtures and previews; `nil` reads the clock each refresh.
    private let pinnedNow: Date?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var model: HealthInsightsModel?
    @State private var isShowingPrimer = false

    /// The shipping initializer.
    public init(now: Date? = nil) {
        self.pinnedNow = now
        self.injectedModel = nil
        self.injectedProvider = nil
        self.injectedPermissions = nil
    }

    /// Fixture injection — the entry point PLAN Gate 3's synthetic HealthKit
    /// data uses, and the one previews use to show all four states without a
    /// device.
    public init(
        provider: any HealthDataProviding,
        permissions: (any PermissionsService)? = nil,
        now: Date? = nil
    ) {
        self.pinnedNow = now
        self.injectedModel = nil
        self.injectedProvider = provider
        self.injectedPermissions = permissions
    }

    /// Full injection, for tests that want to inspect the model afterwards.
    public init(model: HealthInsightsModel, now: Date? = nil) {
        self.pinnedNow = now
        self.injectedModel = model
        self.injectedProvider = nil
        self.injectedPermissions = nil
    }

    private var now: Date { pinnedNow ?? Date() }

    // MARK: Body

    public var body: some View {
        content
            .accessibilityIdentifier(InsightsA11y.section)
            .task { await prepare() }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await refresh() }
            }
            // Deliberately no `onDisappear` teardown: the observer and its
            // background delivery are what keep SPEC §4's insights fresh, and
            // switching away from the Trends tab is not a reason to give them up.
            // `HealthInsightsModel.stopObserving()` exists for the paths that
            // mean it — erase-all, and disconnecting Health.
            .sheet(isPresented: $isShowingPrimer) { primer }
    }

    @ViewBuilder
    private var content: some View {
        switch model?.state ?? .unavailable {

        case .unavailable, .silent:
            // SPEC §4: "no HealthKit permission, or no correlation found, simply
            // means the cards don't appear."
            EmptyView()

        case .connect(let hasAsked):
            ConnectHealthCard(hasAsked: hasAsked) {
                if hasAsked {
                    model?.openSystemSettings()
                } else {
                    isShowingPrimer = true
                }
            }
            .padding(.bottom, 2)

        case .insights(let insights):
            VStack(alignment: .leading, spacing: 10) {
                ForEach(insights) { insight in
                    card(for: insight)
                }
            }
            .padding(.bottom, 2)
        }
    }

    @ViewBuilder
    private func card(for insight: HealthInsight) -> some View {
        if let comparison = insight.comparison {
            HealthInsightCard(
                insight: insight,
                basis: HealthInsightCopy.basis(days: insight.sampleCount)
            ) {
                MorningAfterChart(comparison: comparison)
            }
        } else {
            HealthInsightCard(
                insight: insight,
                basis: HealthInsightCopy.basis(weeks: insight.sampleCount)
            )
        }
    }

    // MARK: Primer

    /// SPEC §9: every system dialog is preceded by an in-app primer with a "Not
    /// now", because iOS shows each one exactly once and a burned prompt cannot
    /// be re-asked.
    private var primer: some View {
        ZStack {
            TallyColor.pageGradient.ignoresSafeArea()
            PermissionPrimer(
                identifierPrefix: InsightsA11y.primer,
                symbolName: "heart.text.square",
                tint: TallyColor.aquaBright,
                title: "Connect Health",
                message: "See what drinking does to your activity — on-device only.",
                bullets: [
                    "Reads exercise minutes, active energy, steps, and workouts.",
                    "Compares you against your own baseline, never anyone else's.",
                    "Says nothing unless the pattern is strong enough to be real."
                ],
                grantTitle: "Connect Health",
                footnote: "Health data is read when a card is drawn and never stored, synced, or uploaded.",
                grant: {
                    await model?.connectHealth()
                    isShowingPrimer = false
                    await refresh()
                },
                notNow: { isShowingPrimer = false }
            )
        }
        .presentationDetents([.large])
    }

    // MARK: Plumbing

    private func prepare() async {
        if model == nil {
            model = injectedModel ?? HealthInsightsModel(
                provider: injectedProvider,
                permissions: injectedPermissions,
                // A fixture provider means a preview or a test. Neither should
                // put a notification in the user's queue — inject a model
                // directly if that is the path under test.
                schedulesNotifications: injectedProvider == nil
            )
        }
        await refresh()
    }

    private func refresh() async {
        await model?.refresh(context: modelContext, now: now)

        // SPEC §4 "Refresh": HealthKit tells us when there is new activity data,
        // and the answer is another on-demand read. Started after the refresh
        // rather than before it, so it begins the moment reads start working and
        // is a no-op until then; `startObserving` is idempotent, so calling it
        // on every refresh costs nothing.
        model?.startObserving {
            Task { await refresh() }
        }
    }
}

// MARK: - Previews

#Preview("Connect Health") {
    NavigationStack {
        TrendsScreen {
            HealthInsightsSection(
                provider: FixtureHealthDataProvider(samples: []),
                permissions: MockPermissionsService()
            )
        }
    }
    .preferredColorScheme(.dark)
    .modelContainer(PreviewStore.container)
}

#Preview("Insight card") {
    ZStack {
        TallyColor.pageGradient.ignoresSafeArea()
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HealthInsightCard(
                    insight: HealthInsight(
                        kind: .morningAfter,
                        metric: .exerciseMinutes,
                        headline: "Next-day exercise 65% lower",
                        detail: "After 3+ drink Sessions, your next-day exercise averages 12 min vs your usual 34.",
                        relativeChange: -0.647,
                        sampleCount: 40,
                        comparison: HealthInsightComparison(
                            metric: .exerciseMinutes,
                            afterDrinking: 12,
                            afterDry: 34,
                            drinkingDayCount: 11,
                            dryDayCount: 29,
                            threshold: 3
                        )
                    ),
                    basis: HealthInsightCopy.basis(days: 40)
                ) {
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
                }

                HealthInsightCard(
                    insight: HealthInsight(
                        kind: .workoutDisplacement,
                        metric: .workouts,
                        headline: "Workouts 54% lower in heavier weeks",
                        detail: "In your heavier weeks you average 1.1 workouts a week, against 2.4 in lighter ones.",
                        relativeChange: -0.54,
                        sampleCount: 12
                    ),
                    basis: HealthInsightCopy.basis(weeks: 12)
                )
            }
            .padding(16)
        }
    }
    .preferredColorScheme(.dark)
}
