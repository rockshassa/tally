import SwiftData
import SwiftUI
import TallyKit

/// The You tab — SPEC §3's "lightweight progress screen: points, current
/// streak, badge case. No leaderboards, no social."
///
/// Three properties this file is built to keep:
///
/// * **Every number comes from `ScoringEngine`.** The view holds no score state
///   of its own and does no arithmetic the engine could have done; `YouSummary`
///   is the only thing between the log and the pixels. PLAN Gate 2 compares this
///   screen against headless engine output for a fixture, and that only means
///   anything if there is no second implementation to drift.
/// * **It recomputes live.** The `@Query`s below make a log on the Tally tab —
///   or a watch drink arriving over WatchConnectivity, or a CloudKit merge —
///   repaint the points without a relaunch, because SwiftData invalidates the
///   view on any insert or delete.
/// * **Nothing here rewards alcohol** (SPEC §3's design rule). The whole screen
///   is aqua; the only amber value is the alcohol side of the weekly ratio,
///   which is a count, not a score.
///
/// Built to be pushed or hosted: no `NavigationStack` of its own, so the shell
/// can mount it in whatever stack the You tab already has.
public struct YouScreen: View {

    // MARK: Inputs

    /// The Settings screen (SPEC §9), owned by another workstream. Non-`nil`
    /// puts a gear in the navigation bar; `nil` — the default — leaves the bar
    /// empty, so an unwired You tab is still a complete screen.
    private let settingsDestination: AnyView?

    public init(settingsDestination: AnyView? = nil) {
        self.settingsDestination = settingsDestination
    }

    // MARK: State

    @Environment(\.modelContext) private var modelContext

    /// The invalidation source. Sorted for determinism, not for display —
    /// `SessionDeriver` canonicalises anyway.
    @Query(sort: \DrinkEvent.timestamp, order: .forward) private var events: [DrinkEvent]
    @Query private var materializedSessions: [TallyKit.Session]
    @Query private var venues: [Venue]

    /// SPEC §3's configurable ratio goal, written by Settings. `@AppStorage`
    /// rather than a one-shot read so changing the goal repaints this screen
    /// immediately — see `RatioGoalPreference` for the key contract.
    @AppStorage(RatioGoalPreference.storageKey) private var storedRatioGoal = RatioGoalPreference.defaultValue

    private let deriver = SessionDeriver()

    // MARK: Body

    public var body: some View {
        let summary = currentSummary

        ScrollView {
            VStack(spacing: 12) {
                hero(summary)

                if summary.hasDrinksThisWeek {
                    YouRatioGoalBar(
                        ratioGoal: summary.ratioGoal,
                        nonAlcoholicCount: summary.weekNonAlcoholicCount,
                        alcoholicCount: summary.weekAlcoholicCount,
                        progress: summary.weekRatioProgress,
                        isMet: summary.meetsWeeklyRatioGoal
                    )
                    .accessibilityIdentifier(YouA11y.ratioGoalBar)
                }

                if summary.allTimePoints == 0 {
                    YouEmptyStateCard(hasEvents: summary.hasEvents)
                }

                YouSectionHeader(title: "Badge case")
                    .padding(.top, 6)

                YouBadgeCase(states: summary.badgeStates)

                if summary.longestStreak > 0 {
                    footnote(summary)
                }
            }
            .padding(.horizontal, TallyMetrics.screenPadding)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(TallyColor.pageGradient.ignoresSafeArea())
        .accessibilityIdentifier(YouA11y.screen)
        .navigationTitle("You")
        .navigationBarTitleDisplayMode(.large)
        .toolbar { settingsToolbarItem }
        .animation(.snappy(duration: 0.3), value: summary)
    }

    // MARK: Hero (SPEC §3: points + current streak)

    private func hero(_ summary: YouSummary) -> some View {
        HStack(spacing: 16) {
            YouStreakRing(
                streak: summary.currentStreak,
                progress: summary.streakProgress,
                milestone: summary.nextStreakMilestone
            )
            .accessibilityIdentifier(YouA11y.streakRing)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(summary.allTimePoints)")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(TallyColor.ink)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityIdentifier(YouA11y.allTimePoints)
                    .accessibilityLabel("Points, all time")
                    .accessibilityValue("\(summary.allTimePoints)")

                Text("points · all-time")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TallyColor.inkSecondary)
                    .accessibilityHidden(true)

                Text(weekPointsText(summary))
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(summary.weekPoints > 0 ? TallyColor.aquaBright : TallyColor.inkTertiary)
                    .padding(.top, 3)
                    .accessibilityIdentifier(YouA11y.weekPoints)
                    .accessibilityLabel("Points this week")
                    .accessibilityValue("\(summary.weekPoints)")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyGlassCard()
        .accessibilityIdentifier(YouA11y.hero)
    }

    private func weekPointsText(_ summary: YouSummary) -> String {
        summary.weekPoints > 0 ? "+\(summary.weekPoints) this week" : "0 this week"
    }

    /// The quiet line under the case. Bests belong here rather than in the hero:
    /// the number that matters is the streak you are on now.
    private func footnote(_ summary: YouSummary) -> some View {
        HStack(spacing: 6) {
            Text("Best ratio streak \(summary.longestStreak)d")
            Text("·").foregroundStyle(TallyColor.inkTertiary)
            Text("Longest dry \(summary.longestDryStreak)d")
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(TallyColor.inkTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
        .padding(.leading, 4)
    }

    // MARK: Settings slot (SPEC §9)

    @ToolbarContentBuilder
    private var settingsToolbarItem: some ToolbarContent {
        if let settingsDestination {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    settingsDestination
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(TallyColor.inkSecondary)
                }
                .accessibilityIdentifier(YouA11y.settingsButton)
                .accessibilityLabel("Settings")
            }
        }
    }

    // MARK: Derived state

    /// Recomputed on every invalidation. Cheap enough to do inline — the engine
    /// is a couple of linear passes over the log — and doing it inline is what
    /// keeps "the screen matches the engine" true by construction rather than by
    /// cache invalidation.
    private var currentSummary: YouSummary {
        let snapshots = events.map(\.snapshot)
        let sessions = deriver.derive(
            events: snapshots,
            materialized: materializedSessions.map(\.snapshot)
        )

        var venuesByID: [UUID: VenueSnapshot] = [:]
        for venue in venues { venuesByID[venue.id] = venue.snapshot }

        var configuration = ScoringEngine.Configuration.default
        // `@AppStorage` hands back the raw stored value; the range check lives in
        // one place so a corrupt write can't produce a nonsense streak.
        configuration.ratioGoal = RatioGoalPreference.allowedRange.contains(storedRatioGoal)
            ? storedRatioGoal
            : RatioGoalPreference.defaultValue

        return YouSummary.make(
            events: snapshots,
            sessions: sessions,
            venues: venuesByID,
            configuration: configuration
        )
    }
}

// MARK: - Previews

#Preview("You") {
    NavigationStack {
        YouScreen()
    }
    .preferredColorScheme(.dark)
    .modelContainer(PreviewStore.container)
}

#Preview("You · with Settings") {
    NavigationStack {
        YouScreen(settingsDestination: AnyView(Text("Settings").navigationTitle("Settings")))
    }
    .preferredColorScheme(.dark)
    .modelContainer(PreviewStore.container)
}
