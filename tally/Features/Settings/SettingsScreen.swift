import SwiftData
import SwiftUI
import TallyKit

// MARK: - Ratio goal options

/// The NA-ratio goal (SPEC §3: default 1:1, configurable).
///
/// A short list rather than a slider: the goal is a promise you make to
/// yourself, and four legible choices beat a continuous value nobody can name.
enum RatioGoalOption: Double, CaseIterable, Identifiable, Sendable {

    case oneToTwo = 0.5
    case oneToOne = 1.0
    case threeToTwo = 1.5
    case twoToOne = 2.0

    var id: Double { rawValue }

    /// NA : alcoholic, the order SPEC §3 uses.
    var label: String {
        switch self {
        case .oneToTwo: "1 : 2"
        case .oneToOne: "1 : 1"
        case .threeToTwo: "3 : 2"
        case .twoToOne: "2 : 1"
        }
    }

    var explanation: String {
        switch self {
        case .oneToTwo: "One non-alcoholic drink for every two alcoholic ones."
        case .oneToOne: "One non-alcoholic drink for every alcoholic one."
        case .threeToTwo: "Three non-alcoholic drinks for every two alcoholic ones."
        case .twoToOne: "Two non-alcoholic drinks for every alcoholic one."
        }
    }

    /// Nearest option to a stored value, so a goal written by another surface
    /// still selects something sensible.
    static func nearest(to value: Double) -> RatioGoalOption {
        allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) } ?? .oneToOne
    }
}

// MARK: - Settings screen

/// SPEC §9's Settings, in full: *"Every configurable default named elsewhere in
/// this spec has exactly one home here."*
///
/// Presented from the You tab's gear (SPEC §9: "Lives on the You tab"). The view
/// carries no navigation container of its own so it can be pushed; use
/// `SettingsSheet` for modal presentation.
///
/// ```swift
/// // Pushed from the You tab:
/// NavigationLink { SettingsScreen(permissions: permissions) } label: { … }
///
/// // Or presented from a toolbar gear:
/// .sheet(isPresented: $showingSettings) {
///     SettingsSheet(permissions: permissions, syncSection: AnyView(SyncSettingsSection()))
/// }
/// ```
public struct SettingsScreen: View {

    // MARK: Inputs

    private let permissions: any PermissionsService

    /// **Mount point for the `sync` workstream (SPEC §8).**
    ///
    /// Pass `AnyView(SyncSettingsSection())` — the injected view renders its own
    /// `Section`, which this screen drops into the iCloud slot below. `nil`
    /// leaves an explanatory placeholder, so an unwired build still reads
    /// correctly.
    private let syncSection: AnyView?

    private let settings: TallySettings
    private let service: NotificationService

    /// - Parameters:
    ///   - permissions: the app's own service. It owns a `CLLocationManager`, so
    ///     inject rather than let this screen create a second one.
    ///   - syncSection: the `sync` stream's section, or `nil`.
    public init(
        permissions: (any PermissionsService)? = nil,
        syncSection: AnyView? = nil
    ) {
        self.permissions = permissions ?? SharedPermissions.service
        self.syncSection = syncSection
        self.settings = .shared
        self.service = .shared
    }

    /// Full-control initializer for previews and tests.
    init(
        permissions: any PermissionsService,
        syncSection: AnyView?,
        settings: TallySettings,
        service: NotificationService
    ) {
        self.permissions = permissions
        self.syncSection = syncSection
        self.settings = settings
        self.service = service
    }

    // MARK: State

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var locationStatus: LocationAuthorization = .notDetermined
    @State private var notificationStatus: PermissionStatus = .notDetermined
    @State private var healthStatus: HealthAuthorization = .unavailable

    @State private var primerRequest: SettingsPrimerRequest?
    @State private var exportBundle: TallyExport.Bundle?
    @State private var isConfirmingErase = false
    @State private var isConfirmingEraseFinally = false
    @State private var isShowingRecoveryExplainer = false

    /// SPEC §4's recovery layer, read through `@AppStorage` so the row repaints
    /// the moment the value moves. `RecoveryContext` owns the writes — it mirrors
    /// the App Group (what the widget reads) into `.standard` (what this sees),
    /// so this screen never writes the key directly.
    @AppStorage(RecoveryContext.enabledKey) private var recoveryEnabled = false

    /// One explainer, ever (SPEC §4). App-local: the widget has no use for it.
    @AppStorage(RecoveryContext.explainerSeenKey) private var recoveryExplainerSeen = false

    /// Write-through bindings into the injected settings object. `@Bindable` as
    /// a stored property would fight the initializer, and the sections are
    /// computed properties rather than inline `body` code, so the wrapper is
    /// built where it is used.
    private var bind: Bindable<TallySettings> { Bindable(settings) }

    // MARK: Body

    public var body: some View {
        List {
            goalSection
            venuesSection
            barRadarSection
            notificationsSection
            healthSection
            iCloudSection
            dataSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .settingsSurface()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(SettingsA11y.screen)
        .task {
            await refreshPermissionStatus()
            refreshExport()
            mirrorRecoveryPreference()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshPermissionStatus() }
        }
        .sheet(item: $primerRequest) { request in
            SettingsPrimerSheet(request: request) {
                primerRequest = nil
                Task { await refreshPermissionStatus() }
            }
        }
        .sheet(isPresented: $isShowingRecoveryExplainer) {
            RecoveryExplainerSheet(
                confirm: {
                    // The confirm *is* the enable (SPEC §4): until this runs, the
                    // toggle has not moved and no recovery surface exists.
                    recoveryExplainerSeen = true
                    RecoveryContext.setEnabled(true)
                    isShowingRecoveryExplainer = false
                },
                cancel: { isShowingRecoveryExplainer = false }
            )
        }
        .confirmationDialog(
            "Erase all data?",
            isPresented: $isConfirmingErase,
            titleVisibility: .visible
        ) {
            Button("Erase all data", role: .destructive) { isConfirmingEraseFinally = true }
                .accessibilityIdentifier(SettingsA11y.Data.eraseConfirmButton)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every drink, venue, and Session is deleted from this device. Export first if you want a copy.")
        }
        .alert("This cannot be undone", isPresented: $isConfirmingEraseFinally) {
            Button("Erase everything", role: .destructive) { eraseAllData() }
                .accessibilityIdentifier(SettingsA11y.Data.eraseFinalButton)
            Button("Keep my data", role: .cancel) {}
        } message: {
            Text("There is no backup on our side — there is no our side. Erasing is final.")
        }
    }

    // MARK: - Goal (SPEC §3, §9)

    private var goalSection: some View {
        Section {
            Picker("NA-ratio goal", selection: goalBinding) {
                ForEach(RatioGoalOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .settingsRowBackground()
            .accessibilityIdentifier(SettingsA11y.Goal.picker)

            Text(RatioGoalOption.nearest(to: settings.ratioGoal).explanation)
                .font(.system(size: 12))
                .foregroundStyle(TallyColor.inkSecondary)
                .settingsRowBackground()
                .accessibilityIdentifier(SettingsA11y.Goal.summary)
        } header: {
            SettingsSectionHeader(title: "Goal")
        } footer: {
            SettingsSectionFootnote(
                text: "Hitting the goal on a day extends your streak. Dry days extend it automatically."
            )
        }
    }

    private var goalBinding: Binding<RatioGoalOption> {
        Binding(
            get: { RatioGoalOption.nearest(to: settings.ratioGoal) },
            set: { settings.ratioGoal = $0.rawValue }
        )
    }

    // MARK: - Venues (SPEC §2, §9)

    private var venuesSection: some View {
        Section {
            NavigationLink {
                HomeSetupView()
            } label: {
                SettingsNavigationRow(
                    title: "Home",
                    detail: "Pin & radius",
                    systemImage: "house"
                )
            }
            .settingsRowBackground()
            .accessibilityIdentifier(SettingsA11y.Venues.homeRow)

            NavigationLink {
                VenueListView()
            } label: {
                SettingsNavigationRow(
                    title: "Saved venues",
                    systemImage: "mappin.and.ellipse"
                )
            }
            .settingsRowBackground()
            .accessibilityIdentifier(SettingsA11y.Venues.venueListRow)

            NavigationLink {
                SuppressedPlacesView()
            } label: {
                SettingsNavigationRow(
                    title: "Suppressed places",
                    systemImage: "bell.slash"
                )
            }
            .settingsRowBackground()
            .accessibilityIdentifier(SettingsA11y.Venues.suppressedRow)
        } header: {
            SettingsSectionHeader(title: "Venues")
        } footer: {
            SettingsSectionFootnote(
                text: "Tally never guesses where you live. Home is only ever the pin you set."
            )
        }
    }

    // MARK: - Bar Radar (SPEC §2, §9)

    private var barRadarSection: some View {
        Section {
            Toggle("Bar Radar", isOn: barRadarBinding)
                .font(.system(size: 15))
                .foregroundStyle(TallyColor.ink)
                .tint(TallyColor.amberBright)
                .settingsRowBackground()
                .accessibilityIdentifier(SettingsA11y.BarRadar.masterToggle)

            if settings.barRadarEnabled {
                Toggle("Discover new bars", isOn: bind.barRadarDiscoveryEnabled)
                    .font(.system(size: 15))
                    .foregroundStyle(TallyColor.ink)
                    .tint(TallyColor.amberBright)
                    .settingsRowBackground()
                    .accessibilityIdentifier(SettingsA11y.BarRadar.discoveryToggle)

                Stepper(
                    "Dwell reminder: \(settings.barRadarDwellMinutes) min",
                    value: bind.barRadarDwellMinutes,
                    in: 15...120,
                    step: 15
                )
                .font(.system(size: 15))
                .foregroundStyle(TallyColor.ink)
                .settingsRowBackground()
                .accessibilityIdentifier(SettingsA11y.BarRadar.dwellStepper)

                // SPEC §9: "mid-Session reminder interval (default 60 min)".
                //
                // 30–180 because this clock starts at the last drink: under half
                // an hour it would land while the glass is still full, and past
                // three hours the Session has closed itself anyway (SPEC §2).
                Stepper(
                    "Session reminder: \(settings.sessionReminderMinutes) min",
                    value: bind.sessionReminderMinutes,
                    in: 30...180,
                    step: 15
                )
                .font(.system(size: 15))
                .foregroundStyle(TallyColor.ink)
                .settingsRowBackground()
                .accessibilityIdentifier(SettingsA11y.BarRadar.sessionReminderStepper)

                if settings.barRadarDiscoveryEnabled {
                    MinuteOfDayPicker(title: "Discovery from", minutes: bind.discoveryStartMinutes)
                        .settingsRowBackground()
                        .accessibilityIdentifier(SettingsA11y.BarRadar.discoveryStartPicker)

                    MinuteOfDayPicker(title: "Discovery until", minutes: bind.discoveryEndMinutes)
                        .settingsRowBackground()
                        .accessibilityIdentifier(SettingsA11y.BarRadar.discoveryEndPicker)
                }
            }

            PermissionStatusRow(
                title: "Always location",
                status: locationStatus.asPermissionStatus,
                detail: locationStatusDetail,
                requestTitle: "Allow",
                request: { presentBarRadarPrimer() },
                openSystemSettings: { permissions.openSystemSettings() }
            )
            .settingsRowBackground()
            .accessibilityIdentifier(SettingsA11y.BarRadar.statusRow)
        } header: {
            SettingsSectionHeader(title: "Bar Radar")
        } footer: {
            SettingsSectionFootnote(
                text: "Bar Radar is the only feature that needs Always location. Turning it off drops back to a single fix per drink."
            )
        }
    }

    private var locationStatusDetail: String? {
        switch locationStatus {
        case .always: nil
        case .whenInUse: "Logging works. Bar Radar needs Always."
        case .denied, .restricted: "Location is off at the system level."
        case .notDetermined: "Not asked yet."
        }
    }

    /// SPEC §2/§9: the master toggle triggers the Always upgrade, and the primer
    /// explains both tiers before the system ever asks. Declining leaves the
    /// toggle off — "Bar Radar stays off; nothing else changes."
    private var barRadarBinding: Binding<Bool> {
        Binding(
            get: { settings.barRadarEnabled },
            set: { newValue in
                guard newValue else {
                    settings.barRadarEnabled = false
                    return
                }
                if locationStatus.allowsBarRadar {
                    settings.barRadarEnabled = true
                } else {
                    presentBarRadarPrimer()
                }
            }
        )
    }

    private func presentBarRadarPrimer() {
        primerRequest = SettingsPrimerRequest(
            identifierPrefix: SettingsA11y.BarRadar.primer,
            symbolName: "dot.radiowaves.left.and.right",
            title: "Let Tally notice the bar",
            message: "Bar Radar prompts you to start a Session when you arrive somewhere worth tracking. It needs Always location — iOS does the watching, and only tells Tally when you arrive or leave.",
            bullets: [
                "Bars you go to often get a precise geofence — the prompt arrives as you walk in.",
                "Discovery spots new bars from the visits iOS already detects, during your chosen hours.",
                "No location stream, ever. Non-matches are discarded on the spot.",
                "Home is never a Bar Radar target."
            ],
            grantTitle: "Allow Always location",
            footnote: "Turning Bar Radar off later drops straight back to When-In-Use.",
            grant: {
                let result = await permissions.requestLocationAlways()
                locationStatus = result
                settings.barRadarEnabled = result.allowsBarRadar
            }
        )
    }

    // MARK: - Notifications (SPEC §5, §9)

    private var notificationsSection: some View {
        Section {
            ForEach(TallyNotificationCategory.userConfigurable) { category in
                NotificationCategoryToggleRow(
                    category: category,
                    settings: settings,
                    onChange: { changed in
                        Task { await service.categoryToggleChanged(changed, context: modelContext) }
                    }
                )
                .settingsRowBackground()
            }

            Toggle("Quiet hours", isOn: bind.quietHoursEnabled)
                .font(.system(size: 15))
                .foregroundStyle(TallyColor.ink)
                .tint(TallyColor.amberBright)
                .settingsRowBackground()
                .accessibilityIdentifier(SettingsA11y.Notifications.quietHoursToggle)

            if settings.quietHoursEnabled {
                MinuteOfDayPicker(title: "Quiet from", minutes: bind.quietHoursStartMinutes)
                    .settingsRowBackground()
                    .accessibilityIdentifier(SettingsA11y.Notifications.quietHoursStartPicker)

                MinuteOfDayPicker(title: "Quiet until", minutes: bind.quietHoursEndMinutes)
                    .settingsRowBackground()
                    .accessibilityIdentifier(SettingsA11y.Notifications.quietHoursEndPicker)
            }

            PermissionStatusRow(
                title: "Notifications",
                status: notificationStatus,
                detail: notificationStatusDetail,
                requestTitle: "Turn on",
                request: { presentNotificationsPrimer() },
                openSystemSettings: { permissions.openSystemSettings() }
            )
            .settingsRowBackground()
            .accessibilityIdentifier(SettingsA11y.Notifications.statusRow)
        } header: {
            SettingsSectionHeader(title: "Notifications")
        } footer: {
            SettingsSectionFootnote(text: NotificationCopy.Settings.quietHoursFootnote)
        }
    }

    private var notificationStatusDetail: String? {
        switch notificationStatus {
        case .denied, .restricted: NotificationCopy.Settings.deniedStatus
        case .provisional: NotificationCopy.Settings.provisionalStatus
        default: nil
        }
    }

    private func presentNotificationsPrimer() {
        primerRequest = SettingsPrimerRequest(
            identifierPrefix: SettingsA11y.NotificationsPrimer.prefix,
            symbolName: "bell.badge",
            title: NotificationCopy.Primer.title,
            message: NotificationCopy.Primer.message,
            bullets: NotificationCopy.Primer.bullets,
            grantTitle: NotificationCopy.Primer.grantTitle,
            footnote: NotificationCopy.Primer.footnote,
            grant: {
                notificationStatus = await permissions.requestNotifications(provisional: false)
                await service.refresh(context: modelContext)
            }
        )
    }

    // MARK: - Health (SPEC §4, §9, §10)

    @ViewBuilder
    private var healthSection: some View {
        Section {
            if healthStatus.isAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(healthStatus.readRequested ? TallyColor.aquaBright : TallyColor.inkTertiary)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)

                        Text("Activity data")
                            .font(.system(size: 15))
                            .foregroundStyle(TallyColor.ink)

                        Spacer(minLength: 8)

                        Text(healthStatus.readRequested ? "Asked" : "Not connected")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TallyColor.inkSecondary)
                    }

                    Text("Exercise minutes, active energy, steps, and workouts — read on this device when an insight is computed, never stored or synced. iOS never tells apps which reads were granted, so Tally can only say it asked.")
                        .font(.system(size: 12))
                        .foregroundStyle(TallyColor.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(healthStatus.readRequested ? "Review in Health" : "Connect Health") {
                        if healthStatus.readRequested {
                            permissions.openSystemSettings()
                        } else {
                            presentHealthReadPrimer()
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TallyColor.aquaBright)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(SettingsA11y.Health.connectButton)
                }
                .padding(.vertical, 4)
                .settingsRowBackground()
                .accessibilityIdentifier(SettingsA11y.Health.readStatusRow)

                Toggle("Write drinks to Health", isOn: healthWriteBinding)
                    .font(.system(size: 15))
                    .foregroundStyle(TallyColor.ink)
                    .tint(TallyColor.amberBright)
                    .settingsRowBackground()
                    .accessibilityIdentifier(SettingsA11y.Health.writeToggle)

                Stepper(
                    "Morning-after threshold: \(settings.morningAfterThreshold)+ drinks",
                    value: bind.morningAfterThreshold,
                    in: 1...10
                )
                .font(.system(size: 15))
                .foregroundStyle(TallyColor.ink)
                .settingsRowBackground()
                .accessibilityIdentifier(SettingsA11y.Health.thresholdStepper)
            } else {
                Text("Health data isn't available on this device.")
                    .font(.system(size: 13))
                    .foregroundStyle(TallyColor.inkSecondary)
                    .settingsRowBackground()
            }

            // Outside the HealthKit branch on purpose: the recovery layer is
            // derived from Tally's own event log (SPEC §4), so it works on a
            // device where HealthKit does not.
            recoveryRow
        } header: {
            SettingsSectionHeader(title: "Health")
        } footer: {
            SettingsSectionFootnote(
                text: "Insights compare you against your own baseline and appear only when there's enough data to mean something."
            )
        }
    }

    // MARK: - Recovery context (SPEC §4, §10)

    /// SPEC §9's Health section, last row: *"Recovery context toggle (§4, off by
    /// default, with its explainer)."* One factual subtitle — the layer's claim
    /// about itself, stated the way the layer states everything else.
    private var recoveryRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Recovery context", isOn: recoveryBinding)
                .font(.system(size: 15))
                .foregroundStyle(TallyColor.ink)
                .tint(TallyColor.amberBright)
                .accessibilityIdentifier(SettingsA11y.Health.recoveryToggle)

            Text("Adds a modeled layer for fibrinolytic suppression — how much, and until when — computed on this device from your own log.")
                .font(.system(size: 12))
                .foregroundStyle(TallyColor.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .settingsRowBackground()
    }

    /// Turning it **off** is immediate. Turning it **on** goes through the
    /// explainer the first time and only lands if the user confirms there — the
    /// binding deliberately does not write on the way up (SPEC §4).
    private var recoveryBinding: Binding<Bool> {
        Binding(
            get: { recoveryEnabled },
            set: { newValue in
                guard newValue else {
                    RecoveryContext.setEnabled(false)
                    return
                }
                if recoveryExplainerSeen {
                    RecoveryContext.setEnabled(true)
                } else {
                    isShowingRecoveryExplainer = true
                }
            }
        )
    }

    /// `@AppStorage` watches `.standard`, but the App Group holds the value the
    /// widget reads. `RecoveryContext.setEnabled` writes both, so they only ever
    /// diverge if `.standard` was cleared out from under us; re-mirroring the
    /// App Group's answer on appear makes the row show the truth either way.
    private func mirrorRecoveryPreference() {
        let enabled = RecoveryContext.isEnabled()
        guard enabled != recoveryEnabled else { return }
        RecoveryContext.setEnabled(enabled)
    }

    private var healthWriteBinding: Binding<Bool> {
        Binding(
            get: { settings.writesAlcoholToHealth && healthStatus.alcoholWrite.isUsable },
            set: { newValue in
                guard newValue else {
                    settings.writesAlcoholToHealth = false
                    return
                }
                if healthStatus.alcoholWrite.isUsable {
                    settings.writesAlcoholToHealth = true
                } else if healthStatus.alcoholWrite.needsSystemSettings {
                    permissions.openSystemSettings()
                } else {
                    presentHealthWritePrimer()
                }
            }
        )
    }

    private func presentHealthReadPrimer() {
        primerRequest = SettingsPrimerRequest(
            identifierPrefix: SettingsA11y.Health.primer,
            symbolName: "figure.run",
            title: "See what drinking does to your activity",
            message: "Tally can compare your exercise minutes, steps, and workouts against your own drinking days — on this device, and nowhere else.",
            bullets: [
                "Reads activity only. No sleep, no heart rate.",
                "Nothing is copied into Tally's store or to iCloud.",
                "No correlation, no card. Weak signals stay quiet."
            ],
            grantTitle: "Connect Health",
            footnote: "You pick which metrics to share in the Health sheet.",
            grant: {
                await permissions.requestHealthActivityRead()
                healthStatus = permissions.healthAuthorization()
            }
        )
    }

    private func presentHealthWritePrimer() {
        primerRequest = SettingsPrimerRequest(
            identifierPrefix: SettingsA11y.Health.primer,
            symbolName: "heart.text.square",
            title: "Write drinks to Health",
            message: "Every alcoholic drink you log is also saved to Health as a standard drink, so other apps you trust can see it.",
            bullets: ["Off by default.", "Only alcoholic drinks — nothing else is written."],
            grantTitle: "Allow writing",
            grant: {
                let granted = await permissions.requestHealthAlcoholWrite()
                healthStatus = permissions.healthAuthorization()
                settings.writesAlcoholToHealth = granted
            }
        )
    }

    // MARK: - iCloud sync (SPEC §8) — the `sync` mount point

    @ViewBuilder
    private var iCloudSection: some View {
        if let syncSection {
            syncSection
                .accessibilityIdentifier(SettingsA11y.Sync.section)
        } else {
            Section {
                Text("iCloud sync arrives with the sync workstream. Tally works fully signed out either way.")
                    .font(.system(size: 13))
                    .foregroundStyle(TallyColor.inkSecondary)
                    .settingsRowBackground()
                    .accessibilityIdentifier(SettingsA11y.Sync.placeholderRow)
            } header: {
                SettingsSectionHeader(title: "iCloud")
            }
        }
    }

    // MARK: - Data (SPEC §9)

    private var dataSection: some View {
        Section {
            if let exportBundle {
                ShareLink(item: exportBundle.csv) {
                    SettingsNavigationRow(
                        title: "Export CSV",
                        detail: "\(exportBundle.eventCount) events",
                        systemImage: "tablecells"
                    )
                }
                .settingsRowBackground()
                .accessibilityIdentifier(SettingsA11y.Data.exportCSV)

                ShareLink(item: exportBundle.json) {
                    SettingsNavigationRow(
                        title: "Export JSON",
                        detail: "Everything",
                        systemImage: "curlybraces"
                    )
                }
                .settingsRowBackground()
                .accessibilityIdentifier(SettingsA11y.Data.exportJSON)
            } else {
                Text("Preparing export…")
                    .font(.system(size: 13))
                    .foregroundStyle(TallyColor.inkSecondary)
                    .settingsRowBackground()
            }

            Button(role: .destructive) {
                isConfirmingErase = true
            } label: {
                Text("Erase all data")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(hex: 0xE0655B))
            }
            .settingsRowBackground()
            .accessibilityIdentifier(SettingsA11y.Data.eraseButton)
        } header: {
            SettingsSectionHeader(title: "Data")
        } footer: {
            SettingsSectionFootnote(
                text: "The CSV is your event log. The JSON is everything: events, venues, Sessions, and suppressed places."
            )
        }
    }

    // MARK: - About (SPEC §9, §10)

    private var aboutSection: some View {
        Section {
            NavigationLink {
                AboutSettingsView()
            } label: {
                SettingsNavigationRow(
                    title: "About & privacy",
                    systemImage: "lock.shield"
                )
            }
            .settingsRowBackground()
            .accessibilityIdentifier(SettingsA11y.About.row)
        }
    }

    // MARK: - Behaviour

    private func refreshPermissionStatus() async {
        locationStatus = permissions.locationAuthorization()
        healthStatus = permissions.healthAuthorization()
        notificationStatus = await permissions.notificationAuthorization()
    }

    /// `ShareLink` needs its item up front, so the files are written when the
    /// screen appears rather than when the row is tapped. It reads the main
    /// context and writes two small files — a drink log is hundreds of rows, not
    /// millions — so it stays on the main actor where the context lives.
    private func refreshExport() {
        exportBundle = try? TallyExport.make(context: modelContext)
    }

    /// SPEC §9: *"Erase all data (destructive, double-confirm, also clears the
    /// CloudKit private database when sync is on)."*
    private func eraseAllData() {
        // Stop the merge passes before the wipe so a remote-change callback can't
        // race the deletes; the deletions themselves mirror to CloudKit.
        SyncCoordinator.shared.stop()
        try? EventStore.eraseAll(in: modelContext)
        SyncSettings.shared.clearSyncHistory()

        // Preferences survive on purpose: SPEC §9's erase is about *data*, and a
        // user who wipes their log has not asked for their ratio goal to move.
        // The scheduling bookkeeping does not survive — it describes a log that
        // no longer exists.
        service.cancelAll()
        service.resetSchedulingHistory()
        ActivityInsightScheduler.shared.resetSchedulingHistory()
        Task { await RadarService.shared.eraseAll() }

        exportBundle = nil
        refreshExport()
    }
}

// MARK: - Sheet wrapper

/// `SettingsScreen` with its own navigation container and a Done button — the
/// shape a toolbar gear wants.
public struct SettingsSheet: View {

    private let permissions: (any PermissionsService)?
    private let syncSection: AnyView?

    @Environment(\.dismiss) private var dismiss

    public init(
        permissions: (any PermissionsService)? = nil,
        syncSection: AnyView? = nil
    ) {
        self.permissions = permissions
        self.syncSection = syncSection
    }

    public var body: some View {
        NavigationStack {
            SettingsScreen(permissions: permissions, syncSection: syncSection)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier(SettingsA11y.closeButton)
                    }
                }
        }
        .preferredColorScheme(.dark)
        .tint(TallyColor.amberBright)
    }
}

#Preview {
    NavigationStack {
        SettingsScreen(permissions: MockPermissionsService())
    }
    .preferredColorScheme(.dark)
    .modelContainer(PreviewStore.container)
}
