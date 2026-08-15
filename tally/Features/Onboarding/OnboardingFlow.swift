import SwiftUI
import TallyKit

/// First run (SPEC §9): three screens, all skippable, under 30 seconds.
///
/// 1. **What Tally is** — one tap, one drink; amber is alcohol, aqua is not.
/// 2. **Location primer → When-In-Use prompt.** The primer always comes first;
///    "Not now" defers without burning the one system dialog iOS will ever show.
/// 3. **Set Home** — filled by the `place` workstream through
///    `FeatureSlots.onboardingHomeSetup(onDone:)`; skippable, and available
///    later in Settings.
///
/// The principle underneath all of it: *the counter never sits behind a
/// permission wall.* Skip is on every screen and lands straight on the counter.
struct OnboardingFlow: View {

    let permissions: any PermissionsService

    /// Marks first run complete and swaps in the tab shell.
    let onFinish: () -> Void

    @Environment(\.featureSlots) private var featureSlots
    @State private var page: Page = .welcome

    enum Page: Int, CaseIterable, Hashable {
        case welcome
        case location
        case home
    }

    var body: some View {
        ZStack {
            TallyColor.pageGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                Group {
                    switch page {
                    case .welcome: welcomePage
                    case .location: locationPage
                    case .home: homePage
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))

                pageDots
            }
        }
        .animation(.snappy(duration: 0.3), value: page)
        .accessibilityIdentifier(A11y.Onboarding.flow)
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Spacer()
            Button("Skip") { onFinish() }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(TallyColor.inkSecondary)
                .accessibilityIdentifier(A11y.Onboarding.skipButton)
        }
        .padding(.horizontal, TallyMetrics.screenPadding)
        .padding(.top, 8)
    }

    private var pageDots: some View {
        HStack(spacing: 7) {
            ForEach(Page.allCases, id: \.self) { dot in
                Circle()
                    .fill(dot == page ? TallyColor.amberBright : TallyColor.line)
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.bottom, 18)
        .accessibilityHidden(true)
    }

    // MARK: - Screen 1 — what Tally is

    private var welcomePage: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            TallyMark()
                .padding(.bottom, 26)

            Text("One tap, one drink")
                .font(.title.weight(.semibold))
                .foregroundStyle(TallyColor.ink)
                .padding(.bottom, 10)

            Text("Tally is a counter, nothing else. No forms, no categories, no judgement.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(TallyColor.inkSecondary)

            VStack(spacing: 14) {
                legendRow(
                    tint: .alcoholic,
                    title: "Amber is alcohol",
                    detail: "The big button. Tap it once per drink."
                )
                legendRow(
                    tint: .nonAlcoholic,
                    title: "Aqua is everything else",
                    detail: "Water, soda, NA beer — one bucket."
                )
            }
            .padding(18)
            .tallyGlassCard()
            .padding(.top, 26)

            Spacer(minLength: 20)

            Button("Continue") { page = .location }
                .buttonStyle(TallyPrimaryButtonStyle(tint: TallyColor.amber))
                .accessibilityIdentifier(A11y.Onboarding.welcomeContinueButton)
        }
        .padding(TallyMetrics.screenPadding)
        .accessibilityIdentifier(A11y.Onboarding.welcomePage)
    }

    private func legendRow(tint: TallyDrinkTint, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TallyColor.buttonGradient(for: tint))
                .frame(width: 34, height: 34)
                .overlay(
                    Text("+")
                        .font(.system(size: 18, weight: .light, design: .rounded))
                        .foregroundStyle(Color.black.opacity(0.8))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TallyColor.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(TallyColor.inkSecondary)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Screen 2 — location primer (SPEC §9)

    private var locationPage: some View {
        PermissionPrimer(
            identifierPrefix: A11y.Onboarding.locationPrimer,
            symbolName: "mappin.and.ellipse",
            title: "Know where the night happened",
            message: "Tally takes a single location fix at the moment you log a drink, so it can tag the venue and group your night into a Session.",
            bullets: [
                "One fix per drink — never a trail, never in the background.",
                "Skip it and logging works exactly the same; events just aren't tagged."
            ],
            grantTitle: "Allow location",
            footnote: "The fix never leaves your device.",
            grant: {
                // The primer has been read; only now does iOS get to ask.
                await permissions.requestLocationWhenInUse()
                page = .home
            },
            notNow: {
                // Deferred, not denied — the system prompt is still unspent.
                page = .home
            }
        )
        .accessibilityIdentifier(A11y.Onboarding.locationPrimer)
    }

    // MARK: - Screen 3 — Set Home (the `place` slot)

    private var homePage: some View {
        featureSlots.onboardingHomeSetup(onDone: onFinish)
            .accessibilityIdentifier(A11y.Onboarding.homeSetupPage)
    }
}

/// 正 — the five-stroke tally character the app icon is built from (SPEC §9
/// "App icon"), drawn here in its completed state as the onboarding mark.
private struct TallyMark: View {

    var body: some View {
        Text("正")
            .font(.system(size: 72, weight: .semibold))
            .foregroundStyle(TallyColor.amberBright)
            .shadow(color: TallyColor.amber.opacity(0.5), radius: 18)
            .accessibilityHidden(true)
    }
}

#Preview {
    OnboardingFlow(permissions: MockPermissionsService()) {}
        .preferredColorScheme(.dark)
}
