import SwiftUI
import TallyKit

// MARK: - Screen

/// SPEC §5's notification history.
///
/// > Surfaced as a reverse-chronological list in Settings → Notifications →
/// > *History*, grouped by day, with the suppression reason when something was
/// > deliberately **not** sent (quiet hours, category off, weekly cap,
/// > one-per-visit). It is a debugging and calibration surface — the log is
/// > derived from a rolling 30-day store, never synced, and cleared by erase-all.
///
/// "Debugging and calibration" is the design brief, and it settles the two
/// questions this screen would otherwise have to guess at:
///
/// * **Suppressions are the point, not the exception.** The question people
///   bring here is "why didn't I get that?", so a held-back row states its
///   reason as a sentence — "Quiet hours — held until 9:00 AM" — rather than
///   hiding behind an icon. It is drawn quieter than a delivered row because it
///   never reached a lock screen, not because it matters less.
/// * **Nothing is actionable.** No swipe-to-delete, no per-row menu. The log
///   describes what already happened; the only thing to *do* with it is clear
///   the whole thing.
struct NotificationHistoryView: View {

    private let history: NotificationHistory

    init(history: NotificationHistory = .shared) {
        self.history = history
    }

    @State private var filter: NotificationHistoryFilter = .all
    @State private var days: [NotificationHistoryDay] = []
    @State private var isLogEmpty = true
    @State private var isConfirmingClear = false

    /// Frozen when the list is loaded, so "Today" and every row's time agree
    /// with each other for as long as the screen is on-screen.
    @State private var loadedAt = Date()

    var body: some View {
        List {
            // A filter over nothing is a control that cannot do anything, which
            // SPEC §9's "no lies in Settings" posture rules out.
            if !isLogEmpty {
                filterSection
            }

            if days.isEmpty {
                emptySection
            } else {
                ForEach(days) { day in
                    daySection(day)
                }
            }

            if !isLogEmpty {
                clearSection
            }
        }
        .listStyle(.insetGrouped)
        .settingsSurface()
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(SettingsA11y.NotificationHistory.list)
        .task { reload() }
        .onChange(of: filter) { _, _ in reload() }
        .confirmationDialog(
            "Clear notification history?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear history", role: .destructive) {
                history.clear()
                reload()
            }
            .accessibilityIdentifier(SettingsA11y.NotificationHistory.clearConfirmButton)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the record of what Tally sent and held back. Your drinks, venues, and Sessions are untouched.")
        }
    }

    // MARK: - Sections

    private var filterSection: some View {
        Section {
            Picker("Show", selection: $filter) {
                ForEach(NotificationHistoryFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .settingsRowBackground()
            .accessibilityIdentifier(SettingsA11y.NotificationHistory.filter)
        }
    }

    private var emptySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(filter.emptyMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(TallyColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("The log lives on this device, covers the last 30 days, and is never synced.")
                    .font(.system(size: 12))
                    .foregroundStyle(TallyColor.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .settingsRowBackground()
            .accessibilityIdentifier(SettingsA11y.NotificationHistory.empty)
        }
    }

    private func daySection(_ day: NotificationHistoryDay) -> some View {
        Section {
            ForEach(day.records) { record in
                NotificationHistoryRow(record: record)
                    .settingsRowBackground()
                    .accessibilityIdentifier(SettingsA11y.NotificationHistory.row(record.id))
            }
        } header: {
            SettingsSectionHeader(title: day.title(asOf: loadedAt))
        }
    }

    private var clearSection: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingClear = true
            } label: {
                Text("Clear history")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(hex: 0xE0655B))
            }
            .settingsRowBackground()
            .accessibilityIdentifier(SettingsA11y.NotificationHistory.clearButton)
        } footer: {
            SettingsSectionFootnote(
                text: "Recorded on this device only, for 30 days. Nothing here is synced, and erasing your data clears it too."
            )
        }
    }

    // MARK: - Behaviour

    /// Reads the whole log on appear and on every filter change.
    ///
    /// No observation: the writers are a notification-centre delegate and a
    /// geofence handler, neither of which can run while this list is the thing
    /// on screen — except foreground delivery, and a row appearing under the
    /// user's thumb is worse than one that appears next time.
    private func reload() {
        loadedAt = Date()
        days = history.groupedByDay(matching: filter, asOf: loadedAt)
        isLogEmpty = history.isEmpty(asOf: loadedAt)
    }
}

// MARK: - Row

/// One notification: when, which category, what it said, and what became of it.
struct NotificationHistoryRow: View {

    let record: NotificationRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(record.occurredAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(TallyColor.inkTertiary)
                .frame(width: 62, alignment: .leading)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    CategoryBadge(category: record.category, isMuted: record.isSuppressed)

                    if let venueName = record.venueName, !venueName.isEmpty {
                        Text(venueName)
                            .font(.system(size: 11))
                            .foregroundStyle(TallyColor.inkTertiary)
                            .lineLimit(1)
                    }
                }

                Text(record.title)
                    .font(.system(size: 15))
                    .foregroundStyle(record.isSuppressed ? TallyColor.inkSecondary : TallyColor.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if !record.body.isEmpty {
                    Text(record.body)
                        .font(.system(size: 12))
                        .foregroundStyle(TallyColor.inkTertiary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(record.outcome.displayText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(outcomeColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        // A held-back notification never reached a lock screen, and the row
        // says so before a word of it is read.
        .opacity(record.isSuppressed ? 0.75 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var outcomeColor: Color {
        switch record.outcome {
        case .suppressed: TallyColor.inkTertiary
        case .actionTaken, .opened: TallyColor.aquaBright
        case .scheduled: TallyColor.inkSecondary
        case .delivered, .dismissed: TallyColor.inkSecondary
        }
    }

    private var accessibilityLabel: String {
        var parts = [
            record.occurredAt.formatted(date: .omitted, time: .shortened),
            record.category.displayName,
            record.title
        ]
        if let venueName = record.venueName, !venueName.isEmpty { parts.append(venueName) }
        parts.append(record.outcome.displayText)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Badge

/// The category, as a small capsule. Amber for something that was sent, plain
/// grey for something that was not — the same colour logic the rest of Settings
/// uses for live-versus-inert.
struct CategoryBadge: View {

    let category: NotificationRecordCategory
    var isMuted = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: category.systemImageName)
                .font(.system(size: 9, weight: .semibold))
            Text(category.displayName)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.4)
        }
        .foregroundStyle(isMuted ? TallyColor.inkTertiary : TallyColor.amberBright)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(isMuted ? TallyColor.glass : TallyColor.amberBright.opacity(0.12))
        )
        .accessibilityHidden(true)
    }
}

// MARK: - Preview

private enum NotificationHistoryPreview {

    /// An in-memory log holding one of each shape the list has to draw.
    static func history() -> NotificationHistory {
        let history = NotificationHistory.ephemeral()
        let now = Date()

        history.recordDelivered(
            category: NotificationRecordCategory(.barRadarArrival),
            requestIdentifier: "preview.arrival",
            title: "Looks like you're at The Anchor",
            body: "Start a Session?",
            venueName: "The Anchor",
            deliveredAt: now.addingTimeInterval(-3600)
        )
        history.recordOutcome(
            .actionTaken(identifier: "tally.radar.action.logDrink"),
            requestIdentifier: "preview.arrival",
            category: NotificationRecordCategory(.barRadarArrival),
            title: "Looks like you're at The Anchor",
            body: "Start a Session?",
            venueName: "The Anchor",
            at: now.addingTimeInterval(-3540)
        )
        history.recordScheduled(
            category: NotificationRecordCategory(.weeklyDigest),
            requestIdentifier: "preview.digest",
            title: "Your week",
            body: "12 drinks this week, down 3 from last. 7-day avg: 1.7/day.",
            scheduledAt: now.addingTimeInterval(-7200),
            heldByQuietHoursUntil: now.addingTimeInterval(-7200)
        )
        history.recordSuppressed(
            .categoryOff,
            category: NotificationRecordCategory(.pacingNudge),
            requestIdentifier: "preview.pacing",
            title: "Time for a spacer?",
            body: "Three drinks in the last 90 minutes.",
            now: now.addingTimeInterval(-90_000)
        )

        return history
    }
}

#Preview {
    NavigationStack {
        NotificationHistoryView(history: NotificationHistoryPreview.history())
    }
    .preferredColorScheme(.dark)
}
