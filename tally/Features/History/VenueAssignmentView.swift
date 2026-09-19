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

    @State private var nearby: [VenueCandidate] = []
    @State private var isLoading = false
    @State private var resolvedAnchor: LocationFix?
    @State private var resolvedPOISearch: (any POISearching)?

    /// SPEC §2's venue search, shared verbatim with the check-in picker: the
    /// field types, the model debounces, one request is in flight at a time.
    @State private var search: VenueSearchModel

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
        _search = State(initialValue: VenueSearchModel(service: poiSearch, anchor: anchorFix))
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
    nonisolated public static func anchor(for events: [DrinkEventSnapshot]) -> LocationFix? {
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
        .onDisappear { search.cancel() }
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

            TextField("Search or name this place", text: $search.query)
                .font(.system(size: 15))
                .foregroundStyle(PlacePalette.ink)
                .submitLabel(.done)
                .autocorrectionDisabled()

            if !search.query.isEmpty {
                Button {
                    search.clear()
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

                // SPEC §2: "When the typed name isn't on screen, *Use "X"*
                // creates a user-defined venue at the fix." The same row the
                // check-in picker offers, from the same rule.
                if let typed = typedNameCandidate {
                    useTypedNameRow(typed)
                }

                // SPEC §2: a failed lookup is not an empty one.
                if search.state == .unavailable {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 13))
                            .foregroundStyle(PlacePalette.ink3)
                        Text("Search unavailable")
                            .font(.system(size: 13))
                            .foregroundStyle(PlacePalette.ink3)
                    }
                    .padding(.vertical, 12)
                }

                if isLoading || search.state == .searching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(search.state == .searching ? "Searching…" : "Looking around…")
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
            // The picker's row, for the picker's distances: this list is read
            // in whatever units the reader's locale uses, not always meters.
            CheckInPickerRow(candidate: candidate, hasFix: activeAnchor != nil)
        }
        .buttonStyle(.plain)
    }

    private func useTypedNameRow(_ candidate: VenueCandidate) -> some View {
        Button {
            onAssign(candidate)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PlacePalette.amberBright)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Use “\(candidate.name)”")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(PlacePalette.ink)
                        .lineLimit(1)

                    Text(anchorFix == nil ? "Saves a new venue right here" : "Saves a new venue where you logged")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PlacePalette.ink3)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .placeGlassCard(tint: PlacePalette.amberBright, cornerRadius: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(CheckInPickerA11y.useTypedName)
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
        guard !search.query.isEmpty else { return candidates.sorted(by: VenueCandidate.isOrderedBefore) }
        return CheckInPickerRanking.filtered(candidates, by: search.query)
            .sorted(by: VenueCandidate.isOrderedBefore)
    }

    /// Saved venues already have their own section; don't list them twice.
    /// The query narrows this list as well — with search running as you type,
    /// an unfiltered "near where you logged" would bury the answer.
    private var filteredNearby: [VenueCandidate] {
        CheckInPickerRanking.filtered(
            nearby.filter { candidate in
                !savedVenues.contains { candidate.matches($0) }
            },
            by: search.query
        )
    }

    /// SPEC §2's remote results, minus anything the two local sections already
    /// show, with saved venues winning name and identity.
    private var searchResults: [VenueCandidate] {
        VenueSearchRanking.merged(
            remote: search.results,
            nearby: filteredSaved + filteredNearby,
            saved: savedVenues
        )
    }

    private var typedNameCandidate: VenueCandidate? {
        CheckInPickerRanking.typedNameCandidate(
            for: search.query,
            matching: searchResults + filteredSaved + filteredNearby,
            fix: activeAnchor
        )
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
            // SPEC §2: results are anchored to the fix, or to where the drinks
            // were logged — whichever this sheet turned out to have.
            search.anchor = fix
        }

        guard let fix, let poi = poiSearch ?? resolvedPOISearch else { return }
        nearby = await poi.nearbyVenues(around: fix, radiusMeters: Self.nearbyRadiusMeters)
    }
}
