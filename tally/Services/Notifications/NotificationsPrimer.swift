import SwiftData
import SwiftUI
import TallyKit

// MARK: - The category toggles

/// One SPEC §5 category, with its opt-in.
///
/// Written once and used twice — inside the primer (SPEC §9: "with the §5
/// per-category toggles") and again as the Settings → Notifications rows — so
/// the two lists can never drift apart.
struct NotificationCategoryToggleRow: View {

    let category: TallyNotificationCategory
    var settings: TallySettings = .shared

    /// Called after the toggle flips. Settings reschedules immediately; the
    /// primer, which has not been granted anything yet, passes `nil`.
    var onChange: ((TallyNotificationCategory) -> Void)?

    var body: some View {
        Toggle(isOn: binding) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: category.systemImageName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(TallyColor.amberBright)
                    .frame(width: 22)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(category.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(TallyColor.ink)
                    Text(category.blurb)
                        .font(.system(size: 12))
                        .foregroundStyle(TallyColor.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(TallyColor.amberBright)
        .accessibilityIdentifier(SettingsA11y.Notifications.toggle(category))
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { settings.isEnabled(category) },
            set: { newValue in
                settings.setEnabled(newValue, for: category)
                onChange?(category)
            }
        )
    }
}

/// The whole list, as the primer shows it: one glass card, hairline separators.
struct NotificationCategoryToggles: View {

    var settings: TallySettings = .shared
    var onChange: ((TallyNotificationCategory) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(TallyNotificationCategory.userConfigurable.enumerated()), id: \.element) { index, category in
                if index > 0 {
                    Divider().overlay(TallyColor.line)
                }
                NotificationCategoryToggleRow(
                    category: category,
                    settings: settings,
                    onChange: onChange
                )
                .padding(.vertical, 11)
                .padding(.horizontal, 14)
            }
        }
    }
}

// MARK: - The primer sheet

/// SPEC §9's just-in-time notification ask: *"Right after the first Session
/// closes — a success moment, not a cold start."*
///
/// Two steps, one system dialog:
/// 1. the reused `PermissionPrimer` — what Tally would send, and "Not now";
/// 2. the per-category toggles, so the user trims the set once the ask is
///    answered. Declining at step 1 skips step 2 and turns every category off,
///    exactly as SPEC §9's table says.
struct NotificationsPrimerSheet: View {

    let permissions: any PermissionsService
    var settings: TallySettings = .shared
    let onFinish: () -> Void

    private enum Step {
        case primer
        case categories
    }

    @State private var step: Step = .primer
    @State private var grantedStatus: PermissionStatus = .notDetermined

    var body: some View {
        ZStack {
            TallyColor.pageGradient.ignoresSafeArea()

            switch step {
            case .primer:
                PermissionPrimer(
                    identifierPrefix: SettingsA11y.NotificationsPrimer.prefix,
                    symbolName: "bell.badge",
                    title: NotificationCopy.Primer.title,
                    message: NotificationCopy.Primer.message,
                    bullets: NotificationCopy.Primer.bullets,
                    grantTitle: NotificationCopy.Primer.grantTitle,
                    notNowTitle: NotificationCopy.Primer.notNowTitle,
                    footnote: NotificationCopy.Primer.footnote,
                    grant: { await grant() },
                    notNow: { decline() }
                )
            case .categories:
                categoryStep
            }
        }
        .accessibilityIdentifier(SettingsA11y.NotificationsPrimer.sheet)
        .presentationBackground(TallyColor.background)
    }

    // MARK: Step 2

    private var categoryStep: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text(grantedStatus.isUsable ? "What should Tally send?" : "Notifications stayed off")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(TallyColor.ink)
                    .multilineTextAlignment(.center)

                Text(
                    grantedStatus.isUsable
                        ? "Turn off anything you don't want. You can change all of this later in Settings."
                        : "Nothing will be sent. Every category can be turned on later from Settings."
                )
                .font(.callout)
                .foregroundStyle(TallyColor.inkSecondary)
                .multilineTextAlignment(.center)
            }
            .padding(.top, 28)
            .padding(.horizontal, TallyMetrics.screenPadding)

            if grantedStatus.isUsable {
                ScrollView {
                    NotificationCategoryToggles(settings: settings)
                        .tallyGlassCard()
                        .padding(.horizontal, TallyMetrics.screenPadding)
                        .padding(.top, 22)
                }
            } else {
                Spacer()
            }

            Button("Done") { onFinish() }
                .buttonStyle(TallyPrimaryButtonStyle(tint: TallyColor.amberBright.opacity(0.9)))
                .padding(.horizontal, TallyMetrics.screenPadding)
                .padding(.bottom, 24)
                .padding(.top, 16)
                .accessibilityIdentifier(SettingsA11y.NotificationsPrimer.doneButton)
        }
    }

    // MARK: Behaviour

    private func grant() async {
        grantedStatus = await permissions.requestNotifications(provisional: false)
        step = .categories
    }

    /// SPEC §9: "If declined — all categories off; re-enable from Settings."
    private func decline() {
        settings.disableAllNotificationCategories()
        onFinish()
    }
}

// MARK: - Root modifier

/// The one line the app entry needs for everything in SPEC §5 and the §9
/// notification primer.
///
/// It does three things, all on foreground, all cheap:
/// * asks for provisional (silent) authorization once, so the first weekly
///   digest can arrive before any prompt (SPEC §9 etiquette);
/// * re-derives Sessions and reschedules the digest, trend alert, and streak
///   nudge (SPEC §5);
/// * presents the primer the first time a Session has closed — the success
///   moment SPEC §9 asks for, and never before.
struct NotificationsPrimerModifier: ViewModifier {

    private let permissions: any PermissionsService
    private let service: NotificationService
    private let settings: TallySettings

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var isPresented = false

    init(
        permissions: (any PermissionsService)? = nil,
        service: NotificationService? = nil,
        settings: TallySettings? = nil
    ) {
        self.permissions = permissions ?? SharedPermissions.service
        self.service = service ?? .shared
        self.settings = settings ?? .shared
    }

    func body(content: Content) -> some View {
        content
            .task {
                service.activate()
                await evaluate()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await evaluate() }
            }
            .sheet(isPresented: $isPresented) {
                NotificationsPrimerSheet(
                    permissions: permissions,
                    settings: settings,
                    onFinish: { finishPrimer() }
                )
                .interactiveDismissDisabled()
            }
    }

    private func evaluate() async {
        await service.requestProvisionalDeliveryIfNeeded(using: permissions)
        await service.refresh(context: modelContext)
        await presentPrimerIfEarned()
    }

    /// SPEC §9: the ask lands "right after the first Session closes".
    private func presentPrimerIfEarned() async {
        guard !isPresented else { return }
        guard !TallyDefaults.bool(forKey: TallyDefaults.Keys.notificationsPrimerShown, default: false) else { return }

        // Already answered at the system level (or blocked): there is nothing a
        // primer could add, and SPEC §9 sends those cases to Settings instead.
        let status = await service.authorization()
        guard status == .notDetermined || status == .provisional else {
            TallyDefaults.set(true, forKey: TallyDefaults.Keys.notificationsPrimerShown)
            return
        }

        guard hasClosedSession() else { return }
        isPresented = true
    }

    private func hasClosedSession(now: Date = Date()) -> Bool {
        guard
            let events = try? EventStore.snapshots(in: modelContext),
            !events.isEmpty,
            let materialized = try? EventStore.materializedSessions(in: modelContext)
        else { return false }

        return SessionDeriver()
            .derive(events: events, materialized: materialized)
            .contains { $0.isClosed(asOf: now) }
    }

    private func finishPrimer() {
        TallyDefaults.set(true, forKey: TallyDefaults.Keys.notificationsPrimerShown)
        isPresented = false
        Task { await service.refresh(context: modelContext) }
    }
}

public extension View {

    /// Attach at the app's root view, beside `.venueReconciliation()`.
    ///
    /// ```swift
    /// ContentView(permissions: permissions)
    ///     .notificationsPrimer(permissions: permissions)
    /// ```
    ///
    /// Pass the app's own `PermissionsService` — it owns a `CLLocationManager`,
    /// and a second instance would mean a second authorization delegate.
    func notificationsPrimer(
        permissions: (any PermissionsService)? = nil,
        service: NotificationService? = nil,
        settings: TallySettings? = nil
    ) -> some View {
        modifier(
            NotificationsPrimerModifier(
                permissions: permissions,
                service: service,
                settings: settings
            )
        )
    }
}

// MARK: - Fallback permissions instance

/// Used only when a caller does not inject one — previews, and any host that
/// presents Settings without threading the app's service through.
@MainActor
enum SharedPermissions {
    static let service: any PermissionsService = LivePermissionsService()
}
