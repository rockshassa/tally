import SwiftUI
import TallyKit

/// The one-time explainer that stands between the "Recovery context" toggle and
/// the layer actually coming on (SPEC §4).
///
/// > Off by default behind a Settings toggle ("Recovery context"); zero footprint
/// > when off. Enabling shows a one-time explainer: what the model is, what it is
/// > not, and that a clinician — not the app — is the authority, especially
/// > regarding anticoagulants.
///
/// Deliberately **not** a `PermissionPrimer`. Nothing here is asked of iOS: there
/// is no system dialog behind it, no one-shot prompt to protect, and therefore no
/// "Not now" — declining is just *cancel*, and the toggle stays where it was. The
/// only thing that turns the layer on is the confirm button, which is why the
/// caller hands this view the flip rather than performing it up front.
struct RecoveryExplainerSheet: View {

    /// Runs when the user confirms. The caller flips the toggle and records that
    /// the explainer has been seen — both, or neither.
    let confirm: () -> Void

    /// Runs on cancel. A swipe-down dismiss needs no callback at all — the
    /// toggle was never flipped, so doing nothing is already the right outcome.
    let cancel: () -> Void

    var body: some View {
        ZStack {
            TallyColor.pageGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(TallyColor.amberBright)
                            .padding(.top, 12)
                            .padding(.bottom, 20)
                            .accessibilityHidden(true)

                        Text(Copy.title)
                            .font(.title2.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(TallyColor.ink)
                            .padding(.bottom, 10)

                        Text(Copy.message)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(TallyColor.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)

                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Copy.points, id: \.heading) { point in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(point.heading)
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(TallyColor.ink)
                                    Text(point.body)
                                        .font(.footnote)
                                        .foregroundStyle(TallyColor.inkSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(18)
                        .tallyGlassCard()
                        .padding(.top, 22)
                        .padding(.bottom, 8)
                    }
                }
                .scrollIndicators(.hidden)

                Button(Copy.confirmTitle) { confirm() }
                    .buttonStyle(TallyPrimaryButtonStyle(tint: TallyColor.amberBright.opacity(0.9)))
                    .accessibilityIdentifier(SettingsA11y.Health.recoveryConfirmButton)

                Button(Copy.cancelTitle) { cancel() }
                    .buttonStyle(TallyQuietButtonStyle())
                    .accessibilityIdentifier(SettingsA11y.Health.recoveryCancelButton)

                Text(Copy.footnote)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(TallyColor.inkTertiary)
                    .padding(.top, 2)
            }
            .padding(TallyMetrics.screenPadding)
        }
        .presentationBackground(TallyColor.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(SettingsA11y.Health.recoveryExplainer)
    }

    // MARK: - Copy

    /// Every word the explainer says, in one place — SPEC §4's honesty rules are
    /// a copy contract before they are a code contract, and this is the copy.
    enum Copy {

        struct Point {
            let heading: String
            let body: String
        }

        static let title = "Recovery context"

        static let message = """
            Alcohol transiently raises PAI-1, which slows the t-PA-driven breakdown \
            of clots — and the suppression peaks hours after blood alcohol has \
            fallen, the morning after. Turning this on draws that lag from the \
            drinks you have already logged.
            """

        static let points: [Point] = [
            Point(
                heading: "What it shows",
                body: "A modeled population dose-response: published averages for how much fibrinolytic suppression a pattern of drinking produces, and how long it lasts. Burden and duration — how much, until when."
            ),
            Point(
                heading: "What it is not",
                body: "Not a measurement of anything in your blood. Not a clot risk score. Not medical advice. It is a model of a population, tuned to no individual — least of all you — and it can never tell you a night was safe."
            ),
            Point(
                heading: "Your clinician is the authority",
                body: "Especially about anticoagulants. Tally knows nothing about your medication, your history, or your body, and nothing it shows is a reason to change how you take a prescription. Ask the person treating you."
            ),
            Point(
                heading: "It stays on this device",
                body: "Computed on demand from your own event log, stored nowhere, sent nowhere. Turning it back off removes every recovery surface and changes nothing else."
            )
        ]

        static let confirmTitle = "I understand"
        static let cancelTitle = "Cancel"
        static let footnote = "Tally is not a medical device and makes no health claims."
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            RecoveryExplainerSheet(confirm: {}, cancel: {})
        }
        .preferredColorScheme(.dark)
}
