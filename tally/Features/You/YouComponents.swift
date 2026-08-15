import SwiftUI

/// The three pieces of chrome the You tab is built from: the streak ring, the
/// weekly ratio-goal bar, and the small caption style they share.
///
/// One rule governs every colour choice in this file, from SPEC §3 and repeated
/// in `design/ux-mockups.html`: **the game layer is aqua.** Amber is reserved
/// for values that *count alcoholic drinks* — on this screen that is exactly one
/// number, the alcohol side of the weekly ratio. Nothing that reads as a reward
/// is ever amber, because nothing here rewards alcohol.

// MARK: - Streak ring

/// The aqua ring from the You frame: a track, an arc filling toward the next
/// streak milestone, and the streak length in the middle.
struct YouStreakRing: View {

    let streak: Int
    let progress: Double
    let milestone: Int?

    var diameter: CGFloat = 92
    var lineWidth: CGFloat = 7

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(
                    AngularGradient(
                        colors: [TallyColor.aqua, TallyColor.aquaBright, TallyColor.aqua],
                        center: .center,
                        angle: .degrees(-90)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                // Start at twelve o'clock, like the mockup's rotate(-90).
                .rotationEffect(.degrees(-90))
                .shadow(color: TallyColor.aqua.opacity(0.45), radius: 6)

            VStack(spacing: 1) {
                Text("\(streak)")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(TallyColor.ink)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                Text("DAY STREAK")
                    .font(.system(size: 8, weight: .semibold))
                    .kerning(0.7)
                    .foregroundStyle(TallyColor.inkSecondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.snappy(duration: 0.35), value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ratio goal streak")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let days = streak == 1 ? "1 day" : "\(streak) days"
        guard let milestone, milestone > streak else { return days }
        let togo = milestone - streak
        return "\(days). \(togo == 1 ? "1 day" : "\(togo) days") to a \(milestone)-day streak."
    }
}

// MARK: - Ratio goal bar

/// "This week's ratio goal · 1 : 1 — 13 NA / 12", with the bar under it.
///
/// The alcohol count is the single amber value on the screen. It is a fact
/// about the week, not a score: the bar it sits above only ever fills with NA
/// drinks.
struct YouRatioGoalBar: View {

    let ratioGoal: Double
    let nonAlcoholicCount: Int
    let alcoholicCount: Int
    let progress: Double
    let isMet: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("This week's ratio goal · \(RatioGoalPreference.displayString(ratioGoal))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TallyColor.inkSecondary)

                Spacer(minLength: 4)

                HStack(spacing: 3) {
                    Text("\(nonAlcoholicCount)")
                        .foregroundStyle(TallyColor.aquaBright)
                    Text("NA")
                        .foregroundStyle(TallyColor.inkTertiary)
                    Text("/")
                        .foregroundStyle(TallyColor.inkTertiary)
                    // The one amber number on the You tab: it counts alcohol.
                    Text("\(alcoholicCount)")
                        .foregroundStyle(TallyColor.amberBright)
                }
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [TallyColor.aqua, TallyColor.aquaBright],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(proxy.size.width * progress, progress > 0 ? 8 : 0))
                }
            }
            .frame(height: 8)

            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(isMet ? TallyColor.aquaBright : TallyColor.inkTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyGlassCard()
        .animation(.snappy(duration: 0.3), value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week's ratio goal, \(RatioGoalPreference.displayString(ratioGoal))")
        .accessibilityValue(
            "\(nonAlcoholicCount) non-alcoholic to \(alcoholicCount) alcoholic. \(caption)"
        )
    }

    private var caption: String {
        if alcoholicCount == 0 {
            return nonAlcoholicCount == 0 ? "Nothing logged this week." : "Dry week — the goal is yours."
        }
        if isMet { return "Goal met." }
        let needed = Int((ratioGoal * Double(alcoholicCount)).rounded(.up)) - nonAlcoholicCount
        return needed == 1 ? "1 more non-alcoholic hits it." : "\(needed) more non-alcoholic hit it."
    }
}

// MARK: - Section header

/// The small uppercase heading over the badge case.
struct YouSectionHeader: View {

    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.7)
            .foregroundStyle(TallyColor.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)
    }
}
