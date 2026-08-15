import SwiftData
import SwiftUI
import TallyKit

/// The "reconcile on next open" prompt (SPEC §6, §7).
///
/// Lightweight on purpose: the drinks are already counted and the trends
/// already include them. All that's missing is a name for the place, so every
/// row offers exactly two answers and neither of them is work.
public struct ReconciliationPromptView: View {

    private let service: ReconciliationService
    private let locationService: (any LocationFixProviding)?
    private let poiSearch: (any POISearching)?
    private let onFinish: () -> Void

    @State private var assigningItem: ReconciliationService.Item?

    public init(
        service: ReconciliationService,
        locationService: (any LocationFixProviding)? = nil,
        poiSearch: (any POISearching)? = nil,
        onFinish: @escaping () -> Void = {}
    ) {
        self.service = service
        self.locationService = locationService
        self.poiSearch = poiSearch
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(service.items) { item in
                        card(item)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.hidden)

            footer
        }
        .placeNightSurface()
        .presentationDetents([.medium, .large])
        .presentationBackground(PlacePalette.backgroundDeep)
        .presentationCornerRadius(28)
        .sheet(item: $assigningItem) { item in
            VenueAssignmentView(
                anchorFix: item.anchorFix,
                title: "Where were you?",
                savedVenues: service.savedVenues(),
                locationService: locationService,
                poiSearch: poiSearch,
                onAssign: { candidate in
                    service.assign(candidate, to: item)
                    assigningItem = nil
                    finishIfDone()
                },
                onCancel: { assigningItem = nil }
            )
        }
        .onChange(of: service.items.isEmpty) { _, isEmpty in
            if isEmpty { onFinish() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tag where these happened?")
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundStyle(PlacePalette.ink)

            Text("These were logged away from the app, so Tally couldn't get a location in time. They're already counted — this only names the place.")
                .font(.system(size: 13))
                .foregroundStyle(PlacePalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private func card(_ item: ReconciliationService.Item) -> some View {
        VStack(alignment: .leading, spacing: 10) {

            VStack(alignment: .leading, spacing: 3) {
                Text(item.sourceSummary)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PlacePalette.ink)
                Text(item.whenSummary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(PlacePalette.ink3)
            }

            HStack(spacing: 6) {
                ForEach(item.events.prefix(8), id: \.id) { event in
                    PlaceDrinkSwatch(type: event.type, size: 9)
                }
                if item.events.count > 8 {
                    Text("+\(item.events.count - 8)")
                        .font(.system(size: 11))
                        .foregroundStyle(PlacePalette.ink3)
                }
            }

            HStack(spacing: 8) {
                Button {
                    assigningItem = item
                } label: {
                    Text("Tag a venue")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(PlacePalette.backgroundDeep)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(PlacePalette.amberBright)
                        )
                }

                Button {
                    service.skip(item)
                    finishIfDone()
                } label: {
                    Text("Leave untagged")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(PlacePalette.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .placeGlassCard(cornerRadius: 12)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .placeGlassCard()
    }

    private var footer: some View {
        Button("Not now") { onFinish() }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(PlacePalette.ink3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .buttonStyle(.plain)
            .padding(.bottom, 8)
    }

    private func finishIfDone() {
        if service.items.isEmpty { onFinish() }
    }
}

// MARK: - Entry point

/// The one line the app entry needs (SPEC §6: "reconciles on next open").
///
/// Rescans whenever the app comes to the foreground and presents the prompt
/// only when there is something to ask about — never on a cold start with a
/// clean log.
public struct VenueReconciliationModifier: ViewModifier {

    private let locationService: (any LocationFixProviding)?
    private let poiSearch: (any POISearching)?
    private let lookback: TimeInterval

    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @State private var service: ReconciliationService?
    @State private var isPresented = false

    public init(
        locationService: (any LocationFixProviding)? = nil,
        poiSearch: (any POISearching)? = nil,
        lookback: TimeInterval = ReconciliationService.defaultLookback
    ) {
        self.locationService = locationService
        self.poiSearch = poiSearch
        self.lookback = lookback
    }

    public func body(content: Content) -> some View {
        content
            .task { scan() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { scan() }
            }
            .sheet(isPresented: $isPresented) {
                if let service {
                    ReconciliationPromptView(
                        service: service,
                        locationService: locationService,
                        poiSearch: poiSearch,
                        onFinish: { isPresented = false }
                    )
                }
            }
    }

    private func scan() {
        // Don't stack a second prompt on top of an open one.
        guard !isPresented else { return }
        let active = service ?? ReconciliationService(modelContext: modelContext, lookback: lookback)
        service = active
        active.refresh()
        isPresented = active.hasPendingWork
    }
}

public extension View {

    /// Attach at the app's root view. Offers venue tagging for recent widget and
    /// watch events that never got a fix (SPEC §6, §7).
    func venueReconciliation(
        locationService: (any LocationFixProviding)? = nil,
        poiSearch: (any POISearching)? = nil,
        lookback: TimeInterval = ReconciliationService.defaultLookback
    ) -> some View {
        modifier(
            VenueReconciliationModifier(
                locationService: locationService,
                poiSearch: poiSearch,
                lookback: lookback
            )
        )
    }
}
