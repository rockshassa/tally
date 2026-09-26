import SwiftUI
import TallyKit

// Session detail's door into the recovery episode this night belongs to
// (SPEC §4, design: "Completion and updates").
//
// A Session is an outing; an episode is a drinking-and-recovery interval, and
// the two are not the same shape. One long episode can contain several
// Sessions, and this row deliberately opens the *whole* episode rather than a
// slice of it — with the Session's own drinks highlighted, so a night can be
// found inside a recovery that outlasts it.

// MARK: - Accessibility

/// The identifier the row carries. `HistoryA11y` (in `SessionFormatting.swift`)
/// is the other half of History's identifier set; both are API to the XCUITest
/// suite, so neither gets renamed casually.
enum HistoryRecoveryA11y {
    static let timelineRow = "history.recoveryTimeline"
}

// MARK: - Derivation (pure, view-free, tested)

/// Everything Session detail needs to know about the episode behind a Session,
/// with no view and no store in the way.
enum SessionRecoveryTimeline {

    /// Whether the row belongs on screen at all.
    ///
    /// Recovery off is SPEC §4's promised zero footprint; a night with nothing
    /// alcoholic in it has no episode to open, and a row that opens an empty
    /// sheet is worse than no row.
    static func isAvailable(for session: DerivedSession, recoveryEnabled: Bool) -> Bool {
        recoveryEnabled && session.alcoholicCount > 0
    }

    /// The Session's earliest alcoholic drink — the event whose episode this
    /// row opens.
    ///
    /// Ordered by TallyKit's total order rather than by array position, so two
    /// drinks logged in the same second still resolve to the same anchor on
    /// every device.
    static func anchorEventID(for session: DerivedSession) -> UUID? {
        session.events
            .filter { $0.type == .alcoholic }
            .min(by: DrinkEventSnapshot.isOrderedBefore)?
            .id
    }

    /// The Session's alcoholic drinks, for brighter ticks inside the episode.
    static func highlightedEventIDs(for session: DerivedSession) -> Set<UUID> {
        Set(session.events.filter { $0.type == .alcoholic }.map(\.id))
    }

    /// The episode containing this Session's first drink — regardless of
    /// retention, because History is exactly where an episode that finished
    /// weeks ago is meant to still be openable.
    static func make(
        session: DerivedSession,
        events: [DrinkEventSnapshot],
        now: Date = Date(),
        model: FibrinolysisModel = FibrinolysisModel()
    ) -> SuppressionTimeline? {
        guard let anchor = anchorEventID(for: session) else { return nil }
        return SuppressionTimeline.make(now: now, events: events, model: model, containing: anchor)
    }
}

// MARK: - Row

/// One quiet, tappable line under the rebound classification.
struct RecoveryTimelineRow: View {

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 12))
                    .foregroundStyle(PlacePalette.amberBright.opacity(0.8))

                Text("Recovery timeline")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(PlacePalette.ink)

                Text("Modeled, first drink to baseline")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PlacePalette.ink3)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PlacePalette.ink3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .placeGlassCard(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(HistoryRecoveryA11y.timelineRow)
        .accessibilityLabel("Recovery timeline")
        .accessibilityHint("Opens the modeled suppression episode this session belongs to")
    }
}

// MARK: - Sheet host

/// Resolves the episode at presentation time and hands it to the same expanded
/// chart the Tally card opens.
///
/// `nil` is possible and is said out loud rather than papered over: a Session
/// whose only alcoholic drinks are dated in the future has no episode, because
/// the model refuses to count a drink that has not happened.
struct RecoveryTimelineSheet: View {

    let timeline: SuppressionTimeline?
    let highlightedEventIDs: Set<UUID>

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let timeline {
            SuppressionDetailSheet(timeline: timeline, highlightedEventIDs: highlightedEventIDs)
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        VStack(spacing: 14) {
            Text("No modeled episode")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(TallyColor.ink)

            Text("This session has no logged drink the model can place in time yet.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(TallyColor.inkSecondary)

            Button("Done") { dismiss() }
                .buttonStyle(TallyPrimaryButtonStyle(tint: TallyColor.amberBright.opacity(0.9)))
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(TallyColor.pageGradient.ignoresSafeArea())
        .presentationDetents([.height(260)])
        .presentationBackground(TallyColor.background)
    }
}
