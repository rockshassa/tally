import SwiftUI
import TallyKit

/// SPEC §9 Settings → **iCloud sync**: "toggle (on by default when signed in,
/// §8); last-sync status."
///
/// Self-contained on purpose. The `nudge` agent's Settings screen hosts it with
/// one line inside its `Form`/`List`:
///
/// ```swift
/// SyncSettingsSection()
/// ```
///
/// It brings its own state (`SyncSettings.shared`), its own copy, and its own
/// accessibility identifiers, so the host never has to know that flipping the
/// switch is a next-launch affair.
public struct SyncSettingsSection: View {

    /// Accessibility identifiers, published here rather than in the app's shared
    /// `A11y` table because that file belongs to another workstream this wave.
    /// Fold them in at integration if it is tidier.
    public enum A11yID {
        public static let section = "settings.sync.section"
        public static let toggle = "settings.sync.toggle"
        public static let status = "settings.sync.status"
    }

    @State private var settings: SyncSettings

    private let coordinator: SyncCoordinator

    /// - Parameters:
    ///   - settings: defaults to the process-wide instance. Inject one built on
    ///     a throwaway `UserDefaults` suite for previews and tests.
    ///   - coordinator: started on appear, so the merge passes run even when the
    ///     app entry point has not adopted `.tallySyncCoordination()`.
    public init(
        settings: SyncSettings = .shared,
        coordinator: SyncCoordinator = .shared
    ) {
        _settings = State(initialValue: settings)
        self.coordinator = coordinator
    }

    public var body: some View {
        Section {
            Toggle(isOn: $settings.isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync with iCloud")
                    Text(settings.statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(A11yID.status)
                }
            }
            .disabled(!settings.isToggleEnabled)
            .accessibilityIdentifier(A11yID.toggle)

            if settings.requiresRelaunch {
                Label(
                    settings.resolvedMode.isEnabled
                        ? "Sync starts the next time you open Tally."
                        : "Sync stops the next time you open Tally.",
                    systemImage: "arrow.clockwise"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text(settings.footerText)
        }
        .accessibilityIdentifier(A11yID.section)
        .task {
            settings.refreshAccount()
            coordinator.start()
        }
    }
}

#Preview("Sync on") {
    Form {
        SyncSettingsSection(settings: SyncSettings(defaults: .previewSuite(on: true)))
    }
}

#Preview("Sync off") {
    Form {
        SyncSettingsSection(settings: SyncSettings(defaults: .previewSuite(on: false)))
    }
}

private extension UserDefaults {
    /// Throwaway suite so a preview never writes the real sync preference.
    /// The "No iCloud account" state depends on the running device's account and
    /// cannot be faked from here.
    static func previewSuite(on: Bool) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "tally.sync.preview.\(on)") ?? .standard
        defaults.set(on, forKey: TallyStore.syncPreferenceKey)
        return defaults
    }
}
