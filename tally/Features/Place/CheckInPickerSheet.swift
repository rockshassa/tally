import CoreLocation
import SwiftUI
import TallyKit

/// SPEC §2's check-in picker.
///
/// > "Somewhere else nearby…", and any tap-through from a Bar Radar
/// > notification, open a ranked list: every nearby candidate **ordered by
/// > distance**, each row showing name, category, and distance, with the
/// > inferred venue marked. Includes saved venues in range, a live-updating
/// > distance as a fresh fix arrives, a search field for naming a place MapKit
/// > doesn't return, and *Not a bar / don't ask here*.
///
/// The ranking, the merge, the formatting and the "Use 'X'" gate are all in
/// `CheckInPickerModel.swift`; this file is the screen they draw on.
public struct CheckInPickerSheet: View {

    private let content: CheckInPickerList

    public init(
        request: CheckInPickerRequest,
        savedVenues: [VenueSnapshot] = [],
        locationService: (any LocationFixProviding)? = nil,
        poiSearch: (any POISearching)? = nil,
        onPick: @escaping (VenueCandidate) -> Void,
        onSuppress: ((LocationFix?) -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        content = CheckInPickerList(
            request: request,
            savedVenues: savedVenues,
            locationService: locationService,
            poiSearch: poiSearch,
            onPick: onPick,
            onSuppress: onSuppress,
            onDismiss: onDismiss
        )
    }

    /// Convenience wiring for the common case: the coordinator does the writing
    /// (venue resolution, Session tagging, suppression) and the host is only
    /// told when the picker is finished.
    ///
    /// Every path through the picker ends in `onFinish` — which is what keeps
    /// `PlaceFeatureSlots.SelfDismissingCheckIn`'s contract intact: any
    /// resolution dismisses everything.
    public init(
        request: CheckInPickerRequest,
        coordinator: PlaceCoordinator,
        locationService: (any LocationFixProviding)? = nil,
        poiSearch: (any POISearching)? = nil,
        onFinish: @escaping () -> Void = {}
    ) {
        self.init(
            request: request,
            savedVenues: coordinator.savedVenues(),
            locationService: locationService,
            poiSearch: poiSearch,
            onPick: { candidate in
                coordinator.resolvePicker(request, with: candidate)
                onFinish()
            },
            onSuppress: { fix in
                coordinator.suppressAndDismissPicker(request, at: fix)
                onFinish()
            },
            onDismiss: {
                coordinator.dismissPicker(request)
                onFinish()
            }
        )
    }

    public var body: some View {
        content
            .placeNightSurface()
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(PlacePalette.backgroundDeep)
            .presentationCornerRadius(28)
    }
}

// MARK: - The list itself

/// The picker's body, without any presentation chrome — so the check-in sheet
/// can show it in place of its primary content without fighting the detents
/// that sheet has already set.
struct CheckInPickerList: View {

    // MARK: Inputs

    let request: CheckInPickerRequest
    var savedVenues: [VenueSnapshot] = []
    var locationService: (any LocationFixProviding)?
    var poiSearch: (any POISearching)?
    let onPick: (VenueCandidate) -> Void
    var onSuppress: ((LocationFix?) -> Void)?
    let onDismiss: () -> Void

    /// Non-nil when the picker is inside the check-in sheet, which has a
    /// screen to go back to.
    var onBack: (() -> Void)?

    // MARK: State

    @State private var fix: LocationFix?
    @State private var candidates: [VenueCandidate]
    @State private var query = ""
    @State private var isLocating = false
    @State private var isSearching = false
    @State private var resolvedLocation: (any LocationFixProviding)?
    @State private var resolvedPOISearch: (any POISearching)?

    @Environment(\.scenePhase) private var scenePhase

    init(
        request: CheckInPickerRequest,
        savedVenues: [VenueSnapshot] = [],
        locationService: (any LocationFixProviding)? = nil,
        poiSearch: (any POISearching)? = nil,
        onPick: @escaping (VenueCandidate) -> Void,
        onSuppress: ((LocationFix?) -> Void)? = nil,
        onDismiss: @escaping () -> Void,
        onBack: (() -> Void)? = nil
    ) {
        self.request = request
        self.savedVenues = savedVenues
        self.locationService = locationService
        self.poiSearch = poiSearch
        self.onPick = onPick
        self.onSuppress = onSuppress
        self.onDismiss = onDismiss
        self.onBack = onBack
        _fix = State(initialValue: request.fix)
        _candidates = State(initialValue: request.seeds)
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField
            list
        }
        .accessibilityIdentifier(CheckInPickerA11y.root)
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            // A fresh fix on re-activation, and nothing while the picker is in
            // the background: SPEC §2 is one-shot only, never a stream.
            guard phase == .active else { return }
            Task { await refresh() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(PlacePalette.ink2)
                }
                .buttonStyle(.plain)
            }

            Text("Where are you?")
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundStyle(PlacePalette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 8)

            Button("Not now", action: onDismiss)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PlacePalette.ink3)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(PlacePalette.ink3)

            TextField("Search or name this place", text: $query)
                .font(.system(size: 15))
                .foregroundStyle(PlacePalette.ink)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .accessibilityIdentifier(CheckInPickerA11y.search)

            if !query.isEmpty {
                Button {
                    query = ""
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

                ForEach(sections) { section in
                    sectionHeader(section.title)
                    ForEach(section.candidates) { candidate in
                        row(candidate)
                    }
                }

                if let typed = typedNameCandidate {
                    useTypedNameRow(typed)
                }

                if isLocating || isSearching {
                    progressRow
                } else if rows.isEmpty && typedNameCandidate == nil {
                    emptyRow
                }

                suppressRow
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ candidate: VenueCandidate) -> some View {
        Button {
            onPick(candidate)
        } label: {
            CheckInPickerRow(
                candidate: candidate,
                isSuggested: CheckInPickerRanking.isSuggested(candidate, in: request),
                hasFix: fix != nil
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(CheckInPickerA11y.row(index(of: candidate)))
    }

    /// SPEC §2: "a search field for naming a place MapKit doesn't return".
    private func useTypedNameRow(_ candidate: VenueCandidate) -> some View {
        Button {
            onPick(candidate)
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

                    Text("Saves a new venue right here")
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

    /// SPEC §2: "*Not a bar / don't ask here* which writes a `SuppressedPlace`".
    private var suppressRow: some View {
        Button {
            onSuppress?(fix)
        } label: {
            Text("Not a bar / don't ask here")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(PlacePalette.ink3)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .placeGlassCard(cornerRadius: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Nothing to suppress without somewhere to suppress: the marker is a
        // coordinate and a radius.
        .disabled(onSuppress == nil || fix == nil)
        .opacity(onSuppress == nil || fix == nil ? 0.45 : 1)
        .padding(.top, 12)
        .accessibilityIdentifier(CheckInPickerA11y.suppress)
    }

    private var progressRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(isLocating ? "Locating…" : "Looking around…")
                .font(.system(size: 13))
                .foregroundStyle(PlacePalette.ink3)
        }
        .padding(.vertical, 12)
    }

    private var emptyRow: some View {
        Text(query.isEmpty ? "Nothing nearby." : "No match — type a name to save this place.")
            .font(.system(size: 13))
            .foregroundStyle(PlacePalette.ink3)
            .padding(.vertical, 12)
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

    private var sections: [CheckInPickerRanking.Section] {
        CheckInPickerRanking.sections(
            poi: candidates,
            savedVenues: savedVenues,
            fix: fix,
            query: query
        )
    }

    private var rows: [VenueCandidate] {
        CheckInPickerRanking.rows(in: sections)
    }

    private var typedNameCandidate: VenueCandidate? {
        CheckInPickerRanking.typedNameCandidate(for: query, matching: rows, fix: fix)
    }

    /// The flat position of a row, which is what `checkIn.picker.row.<index>`
    /// counts — UI tests see one list, not two sections.
    private func index(of candidate: VenueCandidate) -> Int {
        rows.firstIndex { $0.id == candidate.id } ?? 0
    }

    // MARK: Loading

    /// One-shot fix, then the POI lookup around it.
    ///
    /// Runs on appear and on every return to the foreground. There is
    /// deliberately no continuous stream behind the "live-updating distance" in
    /// SPEC §2 — this app holds When-In-Use only, and SPEC §10 rules out
    /// continuous tracking outside Bar Radar's own tiers.
    private func refresh() async {
        if fix == nil { isLocating = true }
        if let fresh = await locationProvider().oneShotFix() {
            fix = fresh
            candidates = CheckInPickerRanking.remeasured(candidates, against: fresh)
        }
        isLocating = false

        guard let fix else { return }

        isSearching = true
        let found = await poiProvider().nearbyVenues(
            around: fix,
            radiusMeters: CheckInPickerRanking.radiusMeters
        )
        // Whatever the prompt already had stays, so a candidate the user was
        // just looking at cannot vanish because MapKit answered differently.
        candidates = CheckInPickerRanking.unioned(
            found,
            with: CheckInPickerRanking.remeasured(request.seeds, against: fix)
        )
        isSearching = false
    }

    private func locationProvider() -> any LocationFixProviding {
        if let locationService { return locationService }
        if let resolvedLocation { return resolvedLocation }
        let service = LocationService()
        resolvedLocation = service
        return service
    }

    private func poiProvider() -> any POISearching {
        if let poiSearch { return poiSearch }
        if let resolvedPOISearch { return resolvedPOISearch }
        let service = POISearchService()
        resolvedPOISearch = service
        return service
    }
}

// MARK: - Row

/// One picker row: name, category, distance, and the marker on whichever row
/// inference picked (SPEC §2).
struct CheckInPickerRow: View {

    let candidate: VenueCandidate
    var isSuggested: Bool = false
    var hasFix: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: candidate.systemImageName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isSuggested ? PlacePalette.amberBright : PlacePalette.ink3)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(PlacePalette.ink)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(CheckInPickerFormatting.detail(for: candidate, hasFix: hasFix))
                        .font(.system(size: 12.5))
                        .foregroundStyle(PlacePalette.ink3)

                    if isSuggested {
                        Text("Suggested")
                            .font(.system(size: 10.5, weight: .semibold))
                            .textCase(.uppercase)
                            .kerning(0.5)
                            .foregroundStyle(PlacePalette.amberBright)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(PlacePalette.amberBright.opacity(0.14)))
                    }
                }
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
        .placeGlassCard(tint: isSuggested ? PlacePalette.amberBright : nil, cornerRadius: 14)
        .contentShape(Rectangle())
    }
}

// MARK: - Accessibility

/// The identifiers the picker's UI tests drive.
///
/// They live here rather than in `Shared/AccessibilityIdentifiers.swift`
/// because that file belongs to the shell; the strings are the ones SPEC §2's
/// picker work item names, and they are API in exactly the same way.
enum CheckInPickerA11y {

    static let root = "checkIn.picker"
    static let search = "checkIn.picker.search"
    static let suppress = "checkIn.picker.suppress"
    static let useTypedName = "checkIn.picker.useTypedName"

    /// Flat index across both sections, top to bottom.
    static func row(_ index: Int) -> String { "checkIn.picker.row.\(index)" }
}

// MARK: - Entry point

/// Presents the picker whenever `coordinator.pendingPicker` is set — which is
/// what `PlaceCoordinator.presentPickerForCurrentFix()` does, and therefore how
/// a Bar Radar notification tap-through reaches the screen (SPEC §2).
///
/// Mirrors `CheckInPromptModifier`, with two differences that the tap-through
/// forces: the coordinator may be resolved from `PlaceCoordinator.shared`
/// (a notification handler has no view to hand one over), and only the first
/// host to claim the presentation acts, so attaching this twice cannot try to
/// present one request as two sheets.
public struct CheckInPickerModifier: ViewModifier {

    private let explicitCoordinator: PlaceCoordinator?

    @Environment(\.modelContext) private var modelContext

    @State private var fallback: PlaceCoordinator?
    @State private var hostID = UUID()
    @State private var isHost = false

    public init(coordinator: PlaceCoordinator? = nil) {
        self.explicitCoordinator = coordinator
    }

    public func body(content: Content) -> some View {
        content
            .task {
                isHost = PlaceCoordinator.claimPickerHost(hostID)
                guard explicitCoordinator == nil, PlaceCoordinator.shared == nil, fallback == nil else { return }
                // An app that never wired `PlaceFeatureSlots` still gets a
                // working picker — and registering it keeps the notification
                // path pointed at the same instance.
                let coordinator = PlaceCoordinator(modelContext: modelContext)
                PlaceCoordinator.registerShared(coordinator)
                fallback = coordinator
            }
            .onDisappear { PlaceCoordinator.releasePickerHost(hostID) }
            .sheet(item: binding) { request in
                if let coordinator {
                    CheckInPickerSheet(request: request, coordinator: coordinator)
                }
            }
    }

    private var coordinator: PlaceCoordinator? {
        explicitCoordinator ?? PlaceCoordinator.shared ?? fallback
    }

    private var binding: Binding<CheckInPickerRequest?> {
        Binding(
            get: { isHost ? coordinator?.pendingPicker : nil },
            // Dragging the picker away is "Not now" — the same answer the sheet
            // it came from treats a dismissal as (SPEC §2).
            set: { if $0 == nil { coordinator?.dismissPicker() } }
        )
    }
}

public extension View {

    /// Hosts SPEC §2's check-in picker for the whole app.
    ///
    /// - Parameter coordinator: the app's coordinator. Omit it to use whichever
    ///   one `PlaceFeatureSlots` registered — which is what the Bar Radar
    ///   tap-through calls into.
    func checkInPicker(coordinator: PlaceCoordinator? = nil) -> some View {
        modifier(CheckInPickerModifier(coordinator: coordinator))
    }
}

// MARK: - Preview

#Preview("Picker") {
    let fix = LocationFix(latitude: 51.5079, longitude: -0.0877, horizontalAccuracy: 12)
    let anchor = VenueCandidate(
        id: "anchor",
        name: "The Anchor",
        category: .bar,
        latitude: 51.5079,
        longitude: -0.0877,
        distanceMeters: 40,
        mapItemID: "anchor",
        categoryLabel: "Bar"
    )
    let golden = VenueCandidate(
        id: "golden",
        name: "Golden Tap",
        category: .bar,
        latitude: 51.508,
        longitude: -0.088,
        distanceMeters: 95,
        mapItemID: "golden",
        categoryLabel: "Brewery"
    )

    return Color.black.sheet(isPresented: .constant(true)) {
        CheckInPickerSheet(
            request: CheckInPickerRequest(
                origin: .notification,
                fix: fix,
                suggestion: anchor,
                seeds: [anchor, golden]
            ),
            savedVenues: [
                VenueSnapshot(
                    name: "The Old Bell",
                    category: .bar,
                    latitude: 51.5085,
                    longitude: -0.0873,
                    source: .userDefined
                )
            ],
            locationService: MockLocationService(stagedFix: fix),
            poiSearch: MockPOISearchService(nearbyResults: [anchor, golden]),
            onPick: { _ in },
            onSuppress: { _ in },
            onDismiss: {}
        )
    }
}
