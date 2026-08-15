import SwiftUI

/// Stand-ins for screens later waves own.
///
/// They live here rather than in `Features/Trends/`, `Features/You/`,
/// `Features/History/` or `Features/Place/` on purpose: those directories belong
/// to other agents, and an agent that finds its directory already occupied has
/// to merge instead of just writing. Deleting a placeholder from this file is
/// the whole handover.

// MARK: - Wave 2: Trends (SPEC §4)

struct TrendsPlaceholderView: View {
    var body: some View {
        PlaceholderScaffold(
            symbolName: "chart.bar.xaxis",
            tint: TallyColor.amberBright,
            title: "Trends",
            message: "Charts, stat tiles, and health insights land here.",
            footnote: "SPEC §4"
        )
        .accessibilityIdentifier(A11y.Placeholder.trends)
    }
}

// MARK: - Wave 2: You (SPEC §3, §9)

struct YouPlaceholderView: View {
    var body: some View {
        PlaceholderScaffold(
            symbolName: "person.crop.circle",
            tint: TallyColor.aquaBright,
            title: "You",
            message: "Points, streaks, badges, and Settings land here.",
            footnote: "SPEC §3, §9"
        )
        .accessibilityIdentifier(A11y.Placeholder.you)
    }
}

// MARK: - Wave 1 `place`: History (SPEC §2, §9)

/// Default `FeatureSlots.historyDestination()`. Replaced by the real Sessions
/// list the moment `place` registers its slots.
struct HistoryPlaceholderView: View {
    var body: some View {
        PlaceholderScaffold(
            symbolName: "clock.arrow.circlepath",
            tint: TallyColor.inkSecondary,
            title: "History",
            message: "Past Sessions, each opening into its drink timeline.",
            footnote: "SPEC §2"
        )
        .accessibilityIdentifier(A11y.Placeholder.history)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Wave 1 `place`: Home setup (SPEC §9 screen 3)

/// Default `FeatureSlots.onboardingHomeSetup(onDone:)`.
///
/// SPEC §9 is explicit that screen 3 is skippable and that Home can be set later
/// in Settings, so the unwired version says exactly that and gets out of the way.
struct HomeSetupPlaceholderView: View {

    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "house")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(TallyColor.amberBright)

            Text("Set Home later")
                .font(.title2.weight(.semibold))
                .foregroundStyle(TallyColor.ink)

            Text("Drinks at home get tagged without ever prompting you. You can drop your home pin any time from Settings — nothing else waits on it.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(TallyColor.inkSecondary)
                .padding(.horizontal, 8)

            Spacer()

            Button("Start counting") { onDone() }
                .buttonStyle(TallyPrimaryButtonStyle(tint: TallyColor.amber))
                .accessibilityIdentifier(A11y.Onboarding.homeSetupDoneButton)
        }
        .padding(TallyMetrics.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(A11y.Placeholder.homeSetup)
    }
}

// MARK: - Shared scaffold

/// The one placeholder look, so five empty screens do not become five designs.
struct PlaceholderScaffold: View {

    let symbolName: String
    let tint: Color
    let title: String
    let message: String
    var footnote: String?

    var body: some View {
        ZStack {
            TallyColor.pageGradient.ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: symbolName)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(tint)

                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(TallyColor.ink)

                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(TallyColor.inkSecondary)

                if let footnote {
                    Text(footnote)
                        .font(.caption.monospaced())
                        .foregroundStyle(TallyColor.inkTertiary)
                }
            }
            .padding(28)
            .tallyGlassCard()
            .padding(TallyMetrics.screenPadding)
        }
    }
}

// MARK: - Button styles

/// The filled call-to-action used by onboarding and the placeholders.
struct TallyPrimaryButtonStyle: ButtonStyle {

    var tint: Color = TallyColor.amber

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(TallyColor.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.75 : 1))
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// The quiet "Not now" / "Skip" affordance. SPEC §9: declining is a first-class
/// action, never a dead end.
struct TallyQuietButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(TallyColor.inkSecondary.opacity(configuration.isPressed ? 0.6 : 1))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Rectangle())
    }
}
