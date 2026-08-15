import SwiftData
import SwiftUI
import TallyKit

/// History — "the list of past Sessions… lives behind the today count on the
/// Tally tab" (SPEC §9).
///
/// Built to be pushed: no `NavigationStack` of its own, so the shell's
/// `historyDestination` slot can present it inside whatever stack it already
/// has. Detail is reached through a destination-closure `NavigationLink`, which
/// needs no route registration from the host.
public struct HistoryView: View {

    // MARK: Inputs

    private let locationService: (any LocationFixProviding)?
    private let poiSearch: (any POISearching)?
    private let permissions: (any PermissionsService)?

    @Environment(\.modelContext) private var modelContext
    @State private var model: HistoryModel?

    public init(
        locationService: (any LocationFixProviding)? = nil,
        poiSearch: (any POISearching)? = nil,
        permissions: (any PermissionsService)? = nil
    ) {
        self.locationService = locationService
        self.poiSearch = poiSearch
        self.permissions = permissions
    }

    // MARK: Body

    public var body: some View {
        ScrollView {
            if let model {
                content(model)
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.large)
        .placeNightSurface()
        .task {
            if model == nil { model = HistoryModel(modelContext: modelContext) }
            model?.reload()
        }
    }

    @ViewBuilder
    private func content(_ model: HistoryModel) -> some View {
        LazyVStack(alignment: .leading, spacing: 10) {

            if model.sessions.isEmpty {
                if model.hasLoaded { emptyState }
            } else {
                if !model.pinnedSessions.isEmpty {
                    sectionHeader("Pinned")
                    ForEach(model.pinnedSessions) { session in
                        row(session, model: model)
                    }
                    sectionHeader("All Sessions")
                        .padding(.top, 8)
                }

                ForEach(model.unpinnedSessions) { session in
                    row(session, model: model)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 28)
    }

    private func row(_ session: DerivedSession, model: HistoryModel) -> some View {
        NavigationLink {
            SessionDetailView(
                sessionID: session.id,
                model: model,
                locationService: locationService,
                poiSearch: poiSearch,
                permissions: permissions
            )
        } label: {
            SessionHistoryRow(
                session: session,
                venueName: SessionFormatting.venueName(for: session, venues: model.venues),
                badge: model.badge(for: session)
            )
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.7)
            .foregroundStyle(PlacePalette.ink3)
            .padding(.leading, 4)
            .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No Sessions yet")
                .font(.system(size: 19, weight: .semibold, design: .serif))
                .foregroundStyle(PlacePalette.ink)
            Text("A Session opens with your first drink and closes three hours after your last. They'll collect here.")
                .font(.system(size: 14))
                .foregroundStyle(PlacePalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 40)
    }
}

// MARK: - Row

/// One Session card, per design/ux-mockups.html: venue and date on top, the
/// counts line under it, an italic note when there is one, and a badge for the
/// nights that earned one. Zero-alcohol Sessions wear aqua.
struct SessionHistoryRow: View {

    let session: DerivedSession
    let venueName: String
    var badge: Badge?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            HStack(spacing: 6) {
                if session.pinned {
                    Image(systemName: "mappin")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(PlacePalette.amberBright)
                }

                Text(venueName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(session.venueID == nil ? PlacePalette.ink2 : PlacePalette.ink)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(SessionFormatting.shortDate(session.startedAt))
                    .font(.system(size: 12.5))
                    .foregroundStyle(PlacePalette.ink3)
            }

            statsLine

            if let note = session.note, session.hasNote {
                Text("\u{201C}\(note)\u{201D}")
                    .font(.system(size: 13.5, design: .serif))
                    .italic()
                    .foregroundStyle(PlacePalette.amberBright)
                    .lineLimit(2)
            }

            if let badge {
                HStack(spacing: 4) {
                    Image(systemName: badge.systemImageName)
                        .font(.system(size: 9, weight: .semibold))
                    Text(badge.title)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(PlacePalette.aquaBright)
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .placeGlassCard(tint: session.isZeroAlcohol ? PlacePalette.aqua : nil)
        .contentShape(Rectangle())
    }

    private var statsLine: some View {
        HStack(spacing: 6) {
            PlaceDrinkSwatch(type: .alcoholic)
            Text("\(session.alcoholicCount)")
            Text("·").foregroundStyle(PlacePalette.ink3)
            PlaceDrinkSwatch(type: .nonAlcoholic)
            Text(spacerText)
            Text("·").foregroundStyle(PlacePalette.ink3)
            Text(SessionFormatting.duration(session.duration))
        }
        .font(.system(size: 13))
        .foregroundStyle(PlacePalette.ink2)
    }

    private var spacerText: String {
        if session.alcoholicCount == 0 { return "\(session.nonAlcoholicCount) non-alc" }
        return session.spacerCount == 1 ? "1 spacer" : "\(session.spacerCount) spacers"
    }
}
