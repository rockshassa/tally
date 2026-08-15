import CoreLocation
import SwiftData
import SwiftUI
import TallyKit

/// The counter — SPEC §1, and the whole product at M1.
///
/// Shape of the screen, top to bottom: today's two counts (tappable, History
/// lives behind them per SPEC §9), the live Session card while one is running,
/// then the amber +1 with its undo and the aqua +1 with its undo.
///
/// The invariant that governs every path through this file: **the count never
/// waits.** The event is written and the tally moves before a location fix is
/// even requested; coordinates are backfilled onto the saved event if a fix
/// arrives inside the ~5 s window (SPEC §6) and simply stay nil otherwise.
struct TallyScreen: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.featureSlots) private var featureSlots

    /// Drives invalidation: any insert or delete re-renders the counts, the
    /// Session card, and everything derived from the log.
    @Query(sort: \DrinkEvent.timestamp, order: .forward) private var events: [DrinkEvent]
    @Query private var venues: [Venue]
    @Query private var materializedSessions: [TallyKit.Session]

    @State private var locationFix = OneShotLocationFix()
    @State private var retroLogRequest: RetroLogRequest?
    @State private var pendingCheckIn: PresentedSlot?
    @State private var showsHistory = false

    /// `.sensoryFeedback` triggers — SPEC §1 wants a haptic on tap.
    @State private var logTrigger = 0
    @State private var undoTrigger = 0

    private let deriver = SessionDeriver()

    var body: some View {
        ZStack {
            TallyColor.pageGradient.ignoresSafeArea()

            VStack(spacing: 18) {
                todayHeader

                if let session = activeSession {
                    LiveSessionCard(session: session, venueName: venueName(for: session.venueID))
                }

                Spacer(minLength: 0)

                buttons
            }
            .padding(.horizontal, TallyMetrics.screenPadding)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .accessibilityIdentifier(A11y.Tally.screen)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .animation(.snappy(duration: 0.25), value: counts)
        .animation(.snappy(duration: 0.3), value: activeSession?.id)
        .sensoryFeedback(.impact(weight: .medium), trigger: logTrigger)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: undoTrigger)
        .sheet(item: $retroLogRequest) { request in
            RetroLogSheet(type: request.type) { timestamp in
                logRetroactively(request.type, at: timestamp)
            }
        }
        .sheet(item: $pendingCheckIn) { slot in
            slot.content
        }
    }

    // MARK: - Today's counts (SPEC §1: "today's tallies always visible")

    private var todayHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The link is its own control rather than a wrapper around the
            // counts: a NavigationLink label folds its children into one
            // accessibility element, and the two numbers have to stay
            // independently readable — by VoiceOver and by the UI suite.
            Button {
                showsHistory = true
            } label: {
                HStack(spacing: 6) {
                    Text(Self.todayLabel())
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(TallyColor.inkSecondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TallyColor.inkTertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(A11y.Tally.todayCountsHeader)
            .accessibilityLabel("Today's tally")
            .accessibilityHint("Opens History")

            HStack(alignment: .firstTextBaseline, spacing: 28) {
                countBlock(
                    value: counts.alcoholic,
                    caption: "Drinks",
                    tint: .alcoholic,
                    size: 52,
                    identifier: A11y.Tally.alcoholicCount,
                    label: "Alcoholic drinks today"
                )
                countBlock(
                    value: counts.nonAlcoholic,
                    caption: "Non-alc",
                    tint: .nonAlcoholic,
                    size: 32,
                    identifier: A11y.Tally.nonAlcoholicCount,
                    label: "Non-alcoholic drinks today"
                )
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { showsHistory = true }
        }
        .navigationDestination(isPresented: $showsHistory) {
            HistorySlotScreen()
        }
    }

    private func countBlock(
        value: Int,
        caption: String,
        tint: TallyDrinkTint,
        size: CGFloat,
        identifier: String,
        label: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(tint == .alcoholic ? TallyColor.ink : TallyColor.inkSecondary)
                .contentTransition(.numericText())
                .monospacedDigit()
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(label)
                .accessibilityValue("\(value)")

            HStack(spacing: 5) {
                Circle()
                    .fill(TallyColor.tint(for: tint))
                    .frame(width: 7, height: 7)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(TallyColor.inkTertiary)
            }
            .accessibilityHidden(true)
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                DrinkButton(
                    title: "Drink",
                    tint: .alcoholic,
                    prominence: .primary,
                    identifier: A11y.Tally.logDrinkButton,
                    accessibilityLabel: "Log one alcoholic drink",
                    action: { log(.alcoholic) },
                    longPressAction: { retroLogRequest = RetroLogRequest(type: .alcoholic) }
                )

                UndoButton(
                    tint: .alcoholic,
                    diameter: TallyMetrics.undoDiameter,
                    identifier: A11y.Tally.undoDrinkButton,
                    accessibilityLabel: "Undo the last alcoholic drink",
                    isEnabled: counts.alcoholic > 0,
                    action: { undo(.alcoholic) }
                )
            }

            HStack(spacing: 12) {
                DrinkButton(
                    title: "Water · NA",
                    tint: .nonAlcoholic,
                    prominence: .secondary,
                    identifier: A11y.Tally.logNonAlcoholicButton,
                    accessibilityLabel: "Log one non-alcoholic drink",
                    action: { log(.nonAlcoholic) },
                    longPressAction: { retroLogRequest = RetroLogRequest(type: .nonAlcoholic) }
                )

                UndoButton(
                    tint: .nonAlcoholic,
                    diameter: TallyMetrics.undoDiameterSmall,
                    identifier: A11y.Tally.undoNonAlcoholicButton,
                    accessibilityLabel: "Undo the last non-alcoholic drink",
                    isEnabled: counts.nonAlcoholic > 0,
                    action: { undo(.nonAlcoholic) }
                )
            }

            Text("Hold a button to log at an earlier time")
                .font(.caption2)
                .foregroundStyle(TallyColor.inkTertiary)
        }
    }

    // MARK: - Derived state

    /// The shared definition of "today", so the app, the widget, and the watch
    /// can never disagree about the number on screen.
    private var counts: TodayCounts {
        (try? TodayCounts.load(in: modelContext)) ?? .zero
    }

    private var activeSession: DerivedSession? {
        deriver.activeSession(
            events: events.map(\.snapshot),
            materialized: materializedSessions.map(\.snapshot)
        )
    }

    private func venueName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return venues.first { $0.id == id }?.name
    }

    private static func todayLabel(_ date: Date = Date()) -> String {
        "Today · " + date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    // MARK: - Logging (SPEC §1)

    private func log(_ type: DrinkType) {
        guard let event = try? EventStore.logDrink(
            type: type,
            timestamp: Date(),
            source: TallyRuntime.eventSource,
            in: modelContext
        ) else { return }

        logTrigger += 1

        // Everything below this line happens *after* the tally has already moved.
        attachLocationThenOfferCheckIn(
            eventID: event.id,
            type: type,
            timestamp: event.timestamp
        )
    }

    /// SPEC §1: retro-logged events carry no location, by construction.
    private func logRetroactively(_ type: DrinkType, at timestamp: Date) {
        try? EventStore.logDrink(
            type: type,
            timestamp: timestamp,
            source: TallyRuntime.eventSource,
            in: modelContext
        )
        logTrigger += 1
    }

    /// SPEC §1: removes the most recent event of that type today; no-op at zero.
    private func undo(_ type: DrinkType) {
        let removed = (try? EventStore.undoMostRecent(type: type, in: modelContext)) ?? false
        // No haptic when nothing happened — the silence *is* the feedback.
        if removed { undoTrigger += 1 }
    }

    // MARK: - One-shot fix + the `place` seam

    private func attachLocationThenOfferCheckIn(eventID: UUID, type: DrinkType, timestamp: Date) {
        Task {
            let fix = await locationFix.fix()

            // The user may have undone the drink while the fix was in flight.
            guard let event = try? EventStore.event(id: eventID, in: modelContext) else { return }

            if let fix {
                event.latitude = fix.coordinate.latitude
                event.longitude = fix.coordinate.longitude
                event.horizontalAccuracy = fix.horizontalAccuracy
                try? modelContext.save()
            }

            let context = CheckInContext(
                eventID: eventID,
                drinkType: type,
                timestamp: timestamp,
                latitude: event.latitude,
                longitude: event.longitude,
                horizontalAccuracy: event.horizontalAccuracy,
                sessionID: activeSession?.id
            )

            // Unwired, this returns nil and nothing is presented.
            if let sheet = await featureSlots.checkInSheet(for: context) {
                pendingCheckIn = PresentedSlot(content: sheet)
            }
        }
    }
}

/// Identifies a pending retro-log so it can drive `.sheet(item:)`.
struct RetroLogRequest: Identifiable {
    let id = UUID()
    let type: DrinkType
}

/// Hosts whatever `place` registered for History (SPEC §2, §9). Reading the slot
/// here rather than at the call site keeps the environment available to the
/// pushed screen.
struct HistorySlotScreen: View {

    @Environment(\.featureSlots) private var featureSlots

    var body: some View {
        featureSlots.historyDestination()
            .accessibilityIdentifier(A11y.History.screen)
    }
}

#Preview {
    NavigationStack {
        TallyScreen()
    }
    .preferredColorScheme(.dark)
    .modelContainer(PreviewStore.container)
}
