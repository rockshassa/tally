import SwiftUI

// The insight slot's furniture: identifiers, the "Connect Health" placeholder,
// and the card an insight renders into. Kept beside the section rather than in
// `TrendsChrome.swift` because that file is shared with the rest of the Trends
// tab and Wave 3 owns only this subdirectory.

// MARK: - Accessibility identifiers

/// Identifiers for the SPEC §4 surfaces. Namespaced under `insights.` so they
/// never collide with `TrendsA11y`.
enum InsightsA11y {

    /// The whole section. `trends.insightsSlot` (owned by `TrendsScreen`) wraps
    /// it; this one exists so a test can tell "the slot is mounted" from "the
    /// slot has content".
    static let section = "insights.section"

    static let connectCard = "insights.connectCard"
    static let connectButton = "insights.connectCard.button"

    /// Prefix handed to `PermissionPrimer`, which appends `.grantButton`,
    /// `.notNowButton`, and `.title`.
    static let primer = "insights.healthPrimer"

    static let morningAfterChart = "insights.morningAfterChart"

    static func card(_ kind: HealthInsight.Kind) -> String { "insights.card.\(kind.rawValue)" }
}

// MARK: - Connect card

/// SPEC §9's just-in-time HealthKit ask, as it appears in Trends:
///
/// > | HealthKit read | Tapping the "Connect Health" placeholder card in Trends |
/// > | "See what drinking does to your activity — on-device only" |
///
/// A card rather than a screen, because it lives at the top of a scroll view the
/// user came to for charts. Tapping it opens the `PermissionPrimer` sheet, which
/// is where the "Not now" lives — the system read sheet is never reached without
/// passing that.
struct ConnectHealthCard: View {

    /// `true` once the read sheet has been shown. The offer changes: iOS presents
    /// it exactly once, so re-asking would do nothing and Settings is the only
    /// way back.
    let hasAsked: Bool

    let action: () -> Void

    private var title: String {
        hasAsked ? "Health isn't sharing activity" : "Connect Health"
    }

    /// SPEC §9's exact words for the first ask.
    private var message: String {
        hasAsked
            ? "Tally asked for activity reads and Health is returning nothing. Turn them back on in Settings and the cards come back."
            : "See what drinking does to your activity — on-device only."
    }

    private var buttonTitle: String {
        hasAsked ? "Open Settings" : "Connect Health"
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "heart.text.square")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(TallyColor.aquaBright)
                    .frame(width: 26)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TallyColor.ink)

                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(TallyColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    Text(buttonTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TallyColor.aquaBright)
                        .padding(.top, 4)
                        .accessibilityIdentifier(InsightsA11y.connectButton)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TallyColor.inkTertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 12)
            .tallyGlassCard()
            .contentShape(RoundedRectangle(cornerRadius: TallyMetrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(InsightsA11y.connectCard)
        .accessibilityLabel(title)
        .accessibilityHint(message)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Insight card

/// One qualifying correlation (SPEC §4), in the Trends card shape.
///
/// The layout puts the *sentence* first and the percentage second, because the
/// sentence is the one that carries the user's own numbers — SPEC §4's framing
/// rule is that an insight is made of "12 min vs your usual 34", not of "65 %".
struct HealthInsightCard<Accessory: View>: View {

    let insight: HealthInsight
    var basis: String?
    @ViewBuilder var accessory: Accessory

    /// Amber for movement away from the user's baseline activity, aqua for
    /// movement toward it, neutral for anything ambiguous — the same rule the
    /// rest of Trends uses, and never a verdict.
    private var tone: Color {
        if insight.relativeChange <= -0.05 { return TallyColor.amberBright }
        if insight.relativeChange >= 0.05 { return TallyColor.aquaBright }
        return TallyColor.inkSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: insight.kind.systemImageName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tone)
                    .accessibilityHidden(true)

                Text(insight.kind.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(TallyColor.ink)

                Spacer(minLength: 6)

                Text(insight.headline)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            Text(insight.detail)
                .font(.system(size: 12.5))
                .foregroundStyle(TallyColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            accessory

            if let basis {
                Text(basis)
                    .font(.system(size: 9.5))
                    .foregroundStyle(TallyColor.inkTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .tallyGlassCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(InsightsA11y.card(insight.kind))
        .accessibilityLabel(insight.kind.title)
        .accessibilityValue(insight.detail)
    }
}

extension HealthInsightCard where Accessory == EmptyView {

    init(insight: HealthInsight, basis: String? = nil) {
        self.init(insight: insight, basis: basis) { EmptyView() }
    }
}
