import CoreLocation
import SwiftUI
import TallyKit

/// SPEC §2 step 4: "tag with raw coordinates only; the history view lets you
/// assign a venue later."
///
/// Three ways in, in the order they're likely to be right: a venue you've
/// already saved, whatever is near where the drinks actually happened, and a
/// free-text search for everything else. Reused by the §6 reconciliation prompt.
public struct VenueAssignmentView: View {

    // MARK: Inputs

    private let anchorFix: LocationFix?
    private let title: String
    private let savedVenues: [VenueSnapshot]
    private let locationService: (any LocationFixProviding)?
    private let poiSearch: (any POISearching)?
    private let onAssign: (VenueCandidate) -> Void
    private let onClear: (() -> Void)?
    private let onCancel: () -> Void

    // MARK: State

    @State private var query = ""
    @State private var nearby: [VenueCandidate] = []
    @State private var searchResults: [VenueCandidate] = []
    @State private var isLoading = false
    @State private var resolvedAnchor: LocationFix?
    @State private var resolvedPOISearch: (any POISearching)?

    /// How far out the "nearby" list looks. Wider than the check-in radius on
    /// purpose — this is a deliberate choice after the fact, not an inference.
    private static let nearbyRadiusMeters: CLLocationDistance = 250

    public init(
        anchorFix: LocationFix?,
        title: String = "Where was this?",
        savedVenues: [VenueSnapshot],
        locationService: (any LocationFixProviding)? = nil,
        poiSearch: (any POISearching)? = nil,
        onAssign: @escaping (VenueCandidate) -> Void,
        onClear: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.anchorFix = anchorFix
        self.title = title
        self.savedVenues = savedVenues
        self.locationService = locationService
        self.poiSearch = poiSearch
        self.onAssign = onAssign
        self.onClear = onClear
        self.onCancel = onCancel
    }

    /// Convenience for History: anchors the nearby search on where the drinks
    /// were actually logged, when the log knows.
    public init(
        session: DerivedSession,
        savedVenues: [VenueSnapshot],
        locationService: (any LocationFixProviding)? = nil,
        poiSearch: (any POISearching)? = nil,
        onAssign: @escaping (VenueCandidate) -> Void,
        onClear: (() -> Void)? = nil,
        onCancel: @escaping () -> Void
    ) {
        self.init(
            anchorFix: Self.anchor(for: session.events),
            savedVenues: savedVenues,
            locationService: locationService,
            poiSearch: poiSearch,
            onAssign: onAssign,
            onClear: onClear,
            onCancel: onCancel
        )
    }

    /// The first event that carries coordinates. A Session logged from the
    /// widget or watch may have none at all (SPEC §6, §7) — then the nearby
    /// list falls back to a fresh fix.
    public static func anchor(for events: [DrinkEventSnapshot]) -> LocationFix? {
        guard let located = events.first(where: { $0.hasCoordinates }),
              let latitude = located.latitude,
              let longitude = located.longitude
        else { return nil }
        return LocationFix(
            latitude: latitude,
            longitude: longitude,
            horizontalAccuracy: located.horizontalAccuracy ?? 0,
            timestamp: located.timestamp
        )
    }

    // MARK: Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField
            list
        }
        .placeNightSurface()
        .presentationDetents([.large])
        .presentationBackground(PlacePalette.backgroundDeep)
        .presentationCornerRadius(28)
        .task { await loadNearby() }
    }

    private var header: some View {
        HStack {
            Text(title)
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundStyle(PlacePalette.ink)
            Spacer()
            Button("Cancel", action: onCancel)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(PlacePalette.ink3)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(PlacePalette.ink3)

            TextField("Search for a place", text: $query)
                .font(.system(size: 15))
                .foregroundStyle(PlacePalette.ink)
                .submitLabel(.search)
                .onSubmit { Task { await runSearch() } }
                .autocorrectionDisabled()

            if !query.isEmpty {
                Button {
                    query = ""
                    searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(PlacePalette.ink3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .placeGlassCard(cornerRadius: 14)
        .padding(.horizontal, 20)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {

                if !searchResults.isEmpty {
                    sectionHeader("Search results")
                    ForEach(searchResults) { candidate in
                        candidateRow(candidate)
                    }
                }

                if !filteredSaved.isEmpty {
                    sectionHeader("Saved venues")
                    ForEach(filteredSaved) { candidate in
                        candidateRow(candidate)
                    }
                }

                if !filteredNearby.isEmpty {
                    sectionHeader(anchorDescription)
                    ForEach(filteredNearby) { candidate in
                        candidateRow(candidate)
                    }
                }

                if isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking around…")
                            .font(.system(size: 13))
                            .foregroundStyle(PlacePalette.ink3)
                    }
                    .padding(.vertical, 12)
                }

                if let onClear {
                    Button("Remove venue from this Session", action: onClear)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(PlacePalette.ink3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .placeGlassCard(cornerRadius: 14)
                        .buttonStyle(.plain)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    private func candidateRow(_ candidate: VenueCandidate) -> some View {
        Button {
            onAssign(candidate)
        } label: {
            VenueCandidateRow(candidate: candidate, showsDistance: activeAnchor != nil)
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.7)
            .foregroundStyle(PlacePalette.ink3)
            .padding(.top, 8)
            .padding(.leading, 4)
    }

    // MARK: Data

    private var activeAnchor: LocationFix? { anchorFix ?? resolvedAnchor }

    private var anchorDescription: String {
        anchorFix == nil ? "Near you now" : "Near where you logged"
    }

    private var filteredSaved: [VenueCandidate] {
        let candidates = savedVenues.map { VenueCandidate(venue: $0, fix: activeAnchor) }
        guard !query.isEmpty else { return candidates.sorted(by: VenueCandidate.isOrderedBefore) }
        return candidates
            .filter { $0.name.localizedCaseInsensitiveContains(query) }
            .sorted(by: VenueCandidate.isOrderedBefore)
    }

    /// Saved venues already have their own section; don't list them twice.
    private var filteredNearby: [VenueCandidate] {
        nearby.filter { candidate in
            !savedVenues.contains { candidate.matches($0) }
        }
    }

    private func loadNearby() async {
        guard nearby.isEmpty, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        if resolvedPOISearch == nil, poiSearch == nil {
            resolvedPOISearch = POISearchService()
        }

        var fix = anchorFix
        if fix == nil {
            let service = locationService ?? LocationService()
            fix = await service.oneShotFix()
            resolvedAnchor = fix
        }

        guard let fix, let search = poiSearch ?? resolvedPOISearch else { return }
        nearby = await search.nearbyVenues(around: fix, radiusMeters: Self.nearbyRadiusMeters)
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        if resolvedPOISearch == nil, poiSearch == nil {
            resolvedPOISearch = POISearchService()
        }
        guard let search = poiSearch ?? resolvedPOISearch else { return }
        isLoading = true
        defer { isLoading = false }
        searchResults = await search.search(trimmed, near: activeAnchor?.coordinate)
    }
}
