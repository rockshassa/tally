import SwiftUI

/// SPEC §9 About: *"privacy explainer (what leaves the device: nothing),
/// standard-drink guidelines link."*
///
/// The wording tracks SPEC §10 closely on purpose. This screen is the app's only
/// statement of posture, and every claim on it has to stay true of the code:
/// no analytics, no third-party SDKs, no server, and HealthKit data that is read
/// at computation time and never stored.
struct AboutSettingsView: View {

    /// NIAAA's definition — the reference the US guidelines are written against.
    static let standardDrinkGuidelinesURL = URL(
        string: "https://www.niaaa.nih.gov/alcohols-effects-health/what-standard-drink"
    )

    var body: some View {
        List {
            Section {
                paragraph(
                    "Nothing leaves your device.",
                    "There is no Tally server and no account. Your events, venues, and Sessions live in this app's storage. Turn on iCloud sync and they also live in your own private iCloud database, which Apple encrypts and which nobody else — including us — can read."
                )

                paragraph(
                    "No analytics, no SDKs.",
                    "Tally ships no third-party code and collects no usage data. There is nothing to opt out of."
                )

                paragraph(
                    "Location, only at the moment you log.",
                    "A single fix per drink, never a trail. Bar Radar is the one exception: enabling it asks for Always access so the system can tell the app when you arrive at a bar you've chosen. Even then, geofences are evaluated by iOS and the app receives entry and exit events only."
                )

                paragraph(
                    "Health data stays in Health.",
                    "Activity metrics are read when an insight is computed and are never copied into Tally's store or to iCloud. Revoking the permission removes the insight cards and nothing else."
                )
            } header: {
                SettingsSectionHeader(title: "Privacy")
            }

            Section {
                paragraph(
                    "Not a medical device.",
                    "Tally counts what you tell it to count. Insights describe correlations in your own numbers — never a diagnosis, a claim, or advice."
                )

                if let url = Self.standardDrinkGuidelinesURL {
                    Link(destination: url) {
                        SettingsNavigationRow(
                            title: "What counts as a standard drink",
                            detail: "NIAAA",
                            systemImage: "arrow.up.right.square"
                        )
                    }
                    .settingsRowBackground()
                    .accessibilityIdentifier(SettingsA11y.About.guidelinesLink)
                }
            } header: {
                SettingsSectionHeader(title: "Guidelines")
            } footer: {
                SettingsSectionFootnote(
                    text: "Tally treats every alcoholic drink as one unit. Sizes and strengths vary — the link explains by how much."
                )
            }

            Section {
                LabeledContent("Version") {
                    Text(versionLabel)
                        .foregroundStyle(TallyColor.inkSecondary)
                }
                .font(.system(size: 15))
                .foregroundStyle(TallyColor.ink)
                .settingsRowBackground()
            }
        }
        .listStyle(.insetGrouped)
        .settingsSurface()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(SettingsA11y.About.screen)
    }

    private func paragraph(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TallyColor.ink)
            Text(body)
                .font(.system(size: 13))
                .foregroundStyle(TallyColor.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .settingsRowBackground()
    }

    private var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

#Preview {
    NavigationStack {
        AboutSettingsView()
    }
    .preferredColorScheme(.dark)
}
