import SwiftUI
import TallyKit

/// SPEC §2 step 3, drawn from design/ux-mockups.html.
///
/// *"Looks like you're at **The Anchor** — check in?"* Non-blocking on purpose:
/// the drink is already counted, so every path off this sheet is cheap. Confirm,
/// pick another nearby result, or wave it off for the night.
///
/// A plain view with explicit callbacks so it can be dropped into the shell's
/// `checkInSheet(context:)` slot unmodified.
public struct CheckInSheet: View {

    private let context: CheckInContext
    private let onConfirm: (VenueCandidate) -> Void
    private let onDismiss: () -> Void

    @State private var showingAlternates = false
    @State private var detent: PresentationDetent = .height(400)

    public init(
        context: CheckInContext,
        onConfirm: @escaping (VenueCandidate) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.context = context
        self.onConfirm = onConfirm
        self.onDismiss = onDismiss
    }

    /// Convenience wiring for the common case: let the coordinator do the
    /// writing, and just tell the host when the sheet is finished.
    public init(
        context: CheckInContext,
        coordinator: PlaceCoordinator,
        onFinish: @escaping () -> Void = {}
    ) {
        self.init(
            context: context,
            onConfirm: { candidate in
                coordinator.confirmCheckIn(candidate, in: context)
                onFinish()
            },
            onDismiss: {
                coordinator.dismissCheckIn(context)
                onFinish()
            }
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showingAlternates {
                alternatesHeader
                alternatesList
            } else {
                primaryContent
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .placeNightSurface()
        .presentationDetents([.height(400), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationBackground(PlacePalette.backgroundDeep)
        .presentationCornerRadius(28)
        .animation(.snappy(duration: 0.25), value: showingAlternates)
    }

    // MARK: - Confident candidate

    private var primaryContent: some View {
        VStack(alignment: .leading, spacing: 0) {

            Text("Looks like you're at")
                .font(.system(size: 13, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.8)
                .foregroundStyle(PlacePalette.ink3)

            Text(context.primary.name)
                .font(.system(size: 30, weight: .semibold, design: .serif))
                .foregroundStyle(PlacePalette.ink)
                .padding(.top, 6)
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            PlaceChip(
                systemImage: context.primary.systemImageName,
                text: context.primary.chipText,
                tint: PlacePalette.ink2
            )
            .padding(.top, 12)

            Spacer(minLength: 24)

            VStack(spacing: 10) {
                Button {
                    onConfirm(context.primary)
                } label: {
                    Text("Check in")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(PlacePalette.amberBright)
                        )
                        .foregroundStyle(PlacePalette.backgroundDeep)
                }

                if !context.alternates.isEmpty {
                    Button {
                        showingAlternates = true
                        detent = .large
                    } label: {
                        Text("Somewhere else nearby…")
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .fill(PlacePalette.glassStrong)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 15, style: .continuous)
                                    .strokeBorder(PlacePalette.line, lineWidth: 1)
                            )
                            .foregroundStyle(PlacePalette.ink)
                    }
                }

                Button("Not now", action: onDismiss)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PlacePalette.ink3)
                    .padding(.top, 2)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - "Somewhere else nearby…"

    private var alternatesHeader: some View {
        HStack(spacing: 10) {
            Button {
                showingAlternates = false
                detent = .height(400)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PlacePalette.ink2)
            }
            .buttonStyle(.plain)

            Text("Nearby")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(PlacePalette.ink)

            Spacer()

            Button("Not now", action: onDismiss)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PlacePalette.ink3)
                .buttonStyle(.plain)
        }
        .padding(.bottom, 14)
    }

    private var alternatesList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(context.allCandidates) { candidate in
                    Button {
                        onConfirm(candidate)
                    } label: {
                        VenueCandidateRow(
                            candidate: candidate,
                            isHighlighted: candidate.id == context.primary.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - Entry point

/// One-line wiring for a host that just wants the sheet to appear whenever the
/// pipeline produces a confident candidate.
///
/// Dragging the sheet away counts as "Not now" — SPEC §2 treats any dismissal
/// as an answer, and re-asking the next drink would be exactly the nagging the
/// spec rules out.
public struct CheckInPromptModifier: ViewModifier {

    private let coordinator: PlaceCoordinator

    public init(coordinator: PlaceCoordinator) {
        self.coordinator = coordinator
    }

    public func body(content: Content) -> some View {
        content.sheet(item: binding) { context in
            CheckInSheet(context: context, coordinator: coordinator)
        }
    }

    private var binding: Binding<CheckInContext?> {
        Binding(
            get: { coordinator.pendingCheckIn },
            set: { if $0 == nil { coordinator.dismissCheckIn() } }
        )
    }
}

public extension View {

    /// Presents the check-in sheet whenever `coordinator.pendingCheckIn` is set
    /// (SPEC §2 step 3).
    func checkInPrompt(coordinator: PlaceCoordinator) -> some View {
        modifier(CheckInPromptModifier(coordinator: coordinator))
    }
}

// MARK: - Row

/// One tappable candidate. Shared by the check-in sheet, History's venue
/// assignment, and the reconciliation prompt.
struct VenueCandidateRow: View {

    let candidate: VenueCandidate
    var isHighlighted: Bool = false
    var showsDistance: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: candidate.systemImageName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isHighlighted ? PlacePalette.amberBright : PlacePalette.ink3)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(PlacePalette.ink)
                    .lineLimit(1)

                Text(detailText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(PlacePalette.ink3)
            }

            Spacer(minLength: 8)

            if candidate.isSaved {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(PlacePalette.aqua)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .placeGlassCard(tint: isHighlighted ? PlacePalette.amberBright : nil, cornerRadius: 14)
        .contentShape(Rectangle())
    }

    private var detailText: String {
        guard showsDistance, candidate.distanceMeters > 0 else { return candidate.categoryLabel }
        return candidate.chipText
    }
}

// MARK: - Preview

#Preview("Check-in") {
    let fix = LocationFix(latitude: 51.5079, longitude: -0.0877, horizontalAccuracy: 12)
    return Color.black.sheet(isPresented: .constant(true)) {
        CheckInSheet(
            context: CheckInContext(
                sessionID: UUID(),
                eventID: UUID(),
                primary: VenueCandidate(
                    id: "anchor",
                    name: "The Anchor",
                    category: .bar,
                    latitude: 51.5079,
                    longitude: -0.0877,
                    distanceMeters: 40,
                    mapItemID: "anchor",
                    categoryLabel: "Bar"
                ),
                alternates: [
                    VenueCandidate(
                        id: "golden",
                        name: "Golden Tap",
                        category: .bar,
                        latitude: 51.508,
                        longitude: -0.088,
                        distanceMeters: 95,
                        categoryLabel: "Brewery"
                    )
                ],
                fix: fix
            ),
            onConfirm: { _ in },
            onDismiss: {}
        )
    }
}
