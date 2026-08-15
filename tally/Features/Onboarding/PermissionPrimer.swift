import SwiftUI
import TallyKit

/// The in-app screen that always precedes a system permission dialog (SPEC §9).
///
/// > iOS shows each system dialog exactly once, so every ask is preceded by an
/// > in-app primer with a "Not now" — declining a primer defers the ask without
/// > burning the one system prompt.
///
/// That is the entire contract, and it is why this component is generic: Wave 2
/// and Wave 3 reuse it verbatim for notifications (after the first Session
/// closes), the Always-location upgrade (Bar Radar), and HealthKit reads
/// (Connect Health). A caller supplies the words and two closures — this view
/// owns the shape, the tone, and the guarantee that "Not now" is always there
/// and never harder to hit than the grant.
///
/// ```swift
/// PermissionPrimer(
///     identifierPrefix: "settings.notifications",
///     symbolName: "bell.badge",
///     title: "Want the weekly digest?",
///     message: "…",
///     grantTitle: "Turn on notifications",
///     grant: { await permissions.requestNotifications() },
///     notNow: { dismiss() }
/// )
/// ```
struct PermissionPrimer: View {

    /// Accessibility identifiers are built from this: `<prefix>.grantButton`,
    /// `<prefix>.notNowButton`, `<prefix>.title`.
    let identifierPrefix: String

    let symbolName: String
    var tint: Color = TallyColor.amberBright

    let title: String
    let message: String

    /// Optional supporting points. Keep them factual — SPEC §5's tone rules
    /// apply to primers too.
    var bullets: [String] = []

    var grantTitle: String = "Continue"
    var notNowTitle: String = "Not now"

    /// Small print under the buttons — typically the privacy posture (SPEC §10).
    var footnote: String?

    /// Performs the system request. Called only after the user has read this
    /// screen and tapped the grant button.
    let grant: () async -> Void

    /// Defers the ask. Must leave the feature usable in its degraded form.
    let notNow: () -> Void

    @State private var isRequesting = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            Image(systemName: symbolName)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(tint)
                .padding(.bottom, 22)
                .accessibilityHidden(true)

            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(TallyColor.ink)
                .accessibilityIdentifier(identifierPrefix + A11yPrimerSuffix.title)
                .padding(.bottom, 10)

            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(TallyColor.inkSecondary)
                .padding(.horizontal, 4)

            if !bullets.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(bullets, id: \.self) { bullet in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Circle()
                                .fill(tint)
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                            Text(bullet)
                                .font(.footnote)
                                .foregroundStyle(TallyColor.inkSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .tallyGlassCard()
                .padding(.top, 22)
            }

            Spacer(minLength: 20)

            Button {
                requestPermission()
            } label: {
                Text(grantTitle)
                    .opacity(isRequesting ? 0 : 1)
                    .overlay {
                        if isRequesting {
                            ProgressView().tint(TallyColor.ink)
                        }
                    }
            }
            .buttonStyle(TallyPrimaryButtonStyle(tint: tint.opacity(0.9)))
            .disabled(isRequesting)
            .accessibilityIdentifier(identifierPrefix + A11yPrimerSuffix.grantButton)

            Button(notNowTitle) { notNow() }
                .buttonStyle(TallyQuietButtonStyle())
                .disabled(isRequesting)
                .accessibilityIdentifier(identifierPrefix + A11yPrimerSuffix.notNowButton)

            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(TallyColor.inkTertiary)
                    .padding(.top, 2)
            }
        }
        .padding(TallyMetrics.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifierPrefix + A11yPrimerSuffix.root)
    }

    private func requestPermission() {
        guard !isRequesting else { return }
        isRequesting = true
        Task {
            await grant()
            isRequesting = false
        }
    }
}

#Preview {
    ZStack {
        TallyColor.pageGradient.ignoresSafeArea()
        PermissionPrimer(
            identifierPrefix: A11y.Onboarding.locationPrimer,
            symbolName: "mappin.and.ellipse",
            title: "Know where you drank",
            message: "Tally takes one location fix when you log a drink, so nights can be grouped by venue.",
            bullets: ["One fix per drink — never a trail.", "Skip it and everything still works."],
            grantTitle: "Allow location",
            footnote: "Nothing leaves your device.",
            grant: {},
            notNow: {}
        )
    }
    .preferredColorScheme(.dark)
}
