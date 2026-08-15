import SwiftUI
import TallyKit

/// The badge case (SPEC §3): every badge in the game, earned ones lit and dated,
/// locked ones dimmed with the copy that says how to earn them — and, where the
/// badge has a countable threshold, how close you are.
///
/// Showing the locked ones is the point. A case that only listed what you had
/// would be a trophy shelf; this one doubles as the rule book, which is the only
/// place the game's rules are written down in the app.
struct YouBadgeCase: View {

    let states: [YouBadgeState]

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(states) { state in
                YouBadgeCard(state: state)
            }
        }
        .accessibilityIdentifier(YouA11y.badgeCase)
    }
}

/// One tile. Earned: aqua icon chip, aqua-tinted border, earned date. Locked:
/// muted chip, dimmed, how-to-earn copy, and a hairline progress bar when the
/// badge counts toward something.
struct YouBadgeCard: View {

    let state: YouBadgeState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {

            iconChip

            Text(state.badge.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state.isEarned ? TallyColor.ink : TallyColor.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(TallyColor.inkTertiary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !state.isEarned, let progress = state.progress, progress.current > 0 {
                progressBar(progress)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: TallyMetrics.cardRadius, style: .continuous)
                .fill(state.isEarned ? TallyColor.glassStrong : TallyColor.glass)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TallyMetrics.cardRadius, style: .continuous)
                .stroke(
                    state.isEarned ? TallyColor.aquaBright.opacity(0.4) : TallyColor.line,
                    lineWidth: 1
                )
        )
        // Locked tiles read as unfinished, not as broken — the copy inside still
        // has to be legible, so this dims rather than hides.
        .opacity(state.isEarned ? 1 : 0.6)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(YouA11y.badge(state.badge))
        .accessibilityLabel(state.badge.title)
        .accessibilityValue(accessibilityValue)
    }

    // MARK: Pieces

    private var iconChip: some View {
        Image(systemName: state.isEarned ? state.badge.systemImageName : "lock.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(state.isEarned ? TallyColor.aquaBright : TallyColor.inkSecondary)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(state.isEarned ? TallyColor.aquaBright.opacity(0.16) : Color.white.opacity(0.07))
            )
    }

    private func progressBar(_ progress: YouBadgeState.Progress) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(TallyColor.aqua)
                        .frame(width: max(proxy.size.width * progress.fraction, 4))
                }
            }
            .frame(height: 4)

            Text("\(progress.current) / \(progress.target)")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(TallyColor.inkTertiary)
        }
        .padding(.top, 2)
    }

    // MARK: Copy

    private var subtitle: String {
        if let earnedAt = state.earnedAt {
            return "Earned \(earnedAt.formatted(.dateTime.month(.abbreviated).day()))"
        }
        return state.lockedDetail
    }

    private var accessibilityValue: String {
        if let earnedAt = state.earnedAt {
            return "Earned \(earnedAt.formatted(.dateTime.month(.wide).day().year()))."
        }
        var value = "Locked. \(state.lockedDetail)"
        if let progress = state.progress {
            value += " \(progress.current) of \(progress.target)."
        }
        return value
    }
}

// MARK: - Zero state

/// SPEC §3's mechanics explained in one sentence, shown while the score is still
/// zero. Points are the least self-evident thing in the app — someone who has
/// only ever tapped the amber button has no way to guess what a spacer is — so
/// the empty state is where the rule gets stated rather than implied.
struct YouEmptyStateCard: View {

    /// Distinguishes "nothing logged yet" from "logged plenty, scored none" —
    /// the second is the person the spacer sentence is actually written for.
    let hasEvents: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hasEvents ? "No points yet" : "Nothing logged yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(TallyColor.ink)

            Text("Log a non-alcoholic drink between two alcoholic ones — that's a spacer, and spacers are worth the most points here.")
                .font(.system(size: 13))
                .foregroundStyle(TallyColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyGlassCard()
        .accessibilityIdentifier(YouA11y.emptyState)
        .accessibilityElement(children: .combine)
    }
}
