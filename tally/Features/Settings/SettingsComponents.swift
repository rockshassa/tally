import SwiftUI
import TallyKit

// MARK: - Surface

/// The dark-glass treatment every Settings row shares (`design/ux-mockups.html`).
///
/// SPEC's visual rule — "a drink counter lives in bars, so the UI commits to
/// dark glass" — applies to Settings too, which means fighting `List`'s default
/// light chrome exactly once, here, rather than in eight sections.
extension View {

    func settingsRowBackground() -> some View {
        listRowBackground(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TallyColor.glass)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(TallyColor.line, lineWidth: 1)
                )
                .padding(.vertical, 2)
        )
    }

    func settingsSurface() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(TallyColor.pageGradient.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
            .tint(TallyColor.amberBright)
    }
}

/// Section header in the app's voice: small, uppercase, quiet.
struct SettingsSectionHeader: View {

    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.7)
            .foregroundStyle(TallyColor.inkTertiary)
    }
}

/// Explanatory text under a section. Facts only — SPEC §5's tone rules do not
/// stop at the lock screen.
struct SettingsSectionFootnote: View {

    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(TallyColor.inkTertiary)
    }
}

// MARK: - Permission status row

/// SPEC §9: *"Settings shows live permission status per feature; anything denied
/// at the system level deep-links to the iOS Settings app, since re-prompting is
/// impossible."*
///
/// That last clause is the whole reason this view exists: a denied permission
/// must never render as a tappable in-app control that silently does nothing.
struct PermissionStatusRow: View {

    let title: String
    let status: PermissionStatus

    /// Shown instead of the generic status when the feature has more to say.
    var detail: String?

    /// The in-app request, offered only while iOS would still show a dialog.
    var requestTitle: String = "Turn on"
    var request: (() -> Void)?

    let openSystemSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(TallyColor.ink)

                Spacer(minLength: 8)

                Text(statusLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TallyColor.inkSecondary)
            }

            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(TallyColor.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if status.needsSystemSettings {
                Button("Open iOS Settings", action: openSystemSettings)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TallyColor.aquaBright)
                    .buttonStyle(.plain)
            } else if status.canPrompt, let request {
                Button(requestTitle, action: request)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TallyColor.aquaBright)
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusLabel: String {
        switch status {
        case .authorized: "On"
        case .provisional: "Quiet delivery"
        case .limited: "Partial"
        case .denied: "Off in iOS Settings"
        case .restricted: "Unavailable"
        case .notDetermined: "Not asked"
        }
    }

    private var indicatorColor: Color {
        switch status {
        case .authorized: TallyColor.aquaBright
        case .provisional, .limited: TallyColor.amberBright
        case .denied, .restricted: Color(hex: 0xC2544B)
        case .notDetermined: TallyColor.inkTertiary
        }
    }
}

// MARK: - Time-of-day picker row

/// A minute-of-day value, bound to the only time control SwiftUI ships.
struct MinuteOfDayPicker: View {

    let title: String
    @Binding var minutes: Int

    var body: some View {
        DatePicker(
            title,
            selection: Binding(
                get: { QuietHours.date(fromMinuteOfDay: minutes) },
                set: { minutes = QuietHours.minuteOfDay(from: $0) }
            ),
            displayedComponents: .hourAndMinute
        )
        .font(.system(size: 15))
        .foregroundStyle(TallyColor.ink)
    }
}

// MARK: - Navigation row

/// The chevron rows in the Venues and About groups.
struct SettingsNavigationRow: View {

    let title: String
    var detail: String?
    var systemImage: String?

    var body: some View {
        HStack(spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(TallyColor.amberBright)
                    .frame(width: 22)
                    .accessibilityHidden(true)
            }

            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(TallyColor.ink)

            Spacer(minLength: 8)

            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(TallyColor.inkSecondary)
            }
        }
    }
}

// MARK: - Primer presentation

/// A `PermissionPrimer` in a sheet, which is how every just-in-time ask in
/// Settings is shaped (SPEC §9: an in-app primer always precedes the system
/// dialog).
struct SettingsPrimerRequest: Identifiable {

    let id = UUID()

    let identifierPrefix: String
    let symbolName: String
    let title: String
    let message: String
    var bullets: [String] = []
    var grantTitle: String
    var footnote: String?

    /// Runs the system request and reports what came back, so the caller can
    /// leave its toggle off when the user declines.
    let grant: () async -> Void
}

struct SettingsPrimerSheet: View {

    let request: SettingsPrimerRequest
    let onFinish: () -> Void

    var body: some View {
        ZStack {
            TallyColor.pageGradient.ignoresSafeArea()
            PermissionPrimer(
                identifierPrefix: request.identifierPrefix,
                symbolName: request.symbolName,
                title: request.title,
                message: request.message,
                bullets: request.bullets,
                grantTitle: request.grantTitle,
                footnote: request.footnote,
                grant: {
                    await request.grant()
                    onFinish()
                },
                notNow: { onFinish() }
            )
        }
        .presentationBackground(TallyColor.background)
    }
}
