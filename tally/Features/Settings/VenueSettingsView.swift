import SwiftData
import SwiftUI
import TallyKit

// MARK: - Venue list

/// SPEC §9 Venues: *"saved venue list — rename, recategorize, per-venue Bar
/// Radar mute."*
///
/// Home is excluded here: it has its own row in Settings that opens the map
/// screen, because a pin is not something you edit in a text field.
struct VenueListView: View {

    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\Venue.name, order: .forward)])
    private var venues: [Venue]

    private var editable: [Venue] {
        venues.filter { $0.category != .home }
    }

    var body: some View {
        List {
            if editable.isEmpty {
                Section {
                    Text("No venues yet. They're saved when you check in somewhere, or when Tally recognises a bar you're in.")
                        .font(.system(size: 13))
                        .foregroundStyle(TallyColor.inkSecondary)
                        .settingsRowBackground()
                }
            } else {
                Section {
                    ForEach(editable) { venue in
                        NavigationLink {
                            VenueEditorView(venue: venue)
                        } label: {
                            row(for: venue)
                        }
                        .settingsRowBackground()
                        .accessibilityIdentifier(SettingsA11y.Venues.row(venue.name))
                    }
                } footer: {
                    SettingsSectionFootnote(
                        text: "Muting a venue keeps it out of Bar Radar. Home is never a Bar Radar target."
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .settingsSurface()
        .navigationTitle("Venues")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(SettingsA11y.Venues.list)
    }

    private func row(for venue: Venue) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(for: venue.category))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(venue.muted ? TallyColor.inkTertiary : TallyColor.amberBright)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(venue.name.isEmpty ? "Unnamed venue" : venue.name)
                    .font(.system(size: 15))
                    .foregroundStyle(TallyColor.ink)
                Text(venue.category.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(TallyColor.inkSecondary)
            }

            Spacer(minLength: 8)

            if venue.muted {
                Image(systemName: "bell.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(TallyColor.inkTertiary)
                    .accessibilityLabel("Muted")
            }
        }
    }

    private func symbol(for category: VenueCategory) -> String {
        switch category {
        case .bar: "wineglass"
        case .restaurant: "fork.knife"
        case .home: "house"
        case .other: "mappin"
        }
    }
}

// MARK: - Venue editor

/// Rename, recategorize, mute (SPEC §9). Writes straight through to the model —
/// there is nothing derived here to keep in step.
struct VenueEditorView: View {

    @Bindable var venue: Venue

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        List {
            Section {
                TextField("Name", text: $venue.name)
                    .font(.system(size: 15))
                    .foregroundStyle(TallyColor.ink)
                    .submitLabel(.done)
                    .settingsRowBackground()
                    .accessibilityIdentifier(SettingsA11y.Venues.nameField)

                Picker("Category", selection: categoryBinding) {
                    ForEach(VenueCategory.allCases, id: \.self) { category in
                        Text(category.displayName).tag(category)
                    }
                }
                .font(.system(size: 15))
                .foregroundStyle(TallyColor.ink)
                .settingsRowBackground()
                .accessibilityIdentifier(SettingsA11y.Venues.categoryPicker)
            } header: {
                SettingsSectionHeader(title: "Venue")
            }

            Section {
                Toggle("Mute Bar Radar here", isOn: $venue.muted)
                    .font(.system(size: 15))
                    .foregroundStyle(TallyColor.ink)
                    .tint(TallyColor.amberBright)
                    .settingsRowBackground()
                    .accessibilityIdentifier(SettingsA11y.Venues.muteToggle)
            } footer: {
                SettingsSectionFootnote(
                    text: "A muted venue never triggers an arrival or dwell prompt. Drinks logged here are still tagged with it."
                )
            }

            Section {
                LabeledContent("Radius") {
                    Text("\(Int(venue.radiusMeters.rounded())) m")
                        .foregroundStyle(TallyColor.inkSecondary)
                }
                .font(.system(size: 15))
                .foregroundStyle(TallyColor.ink)
                .settingsRowBackground()

                LabeledContent("Source") {
                    Text(venue.source == .mapKitPOI ? "Map lookup" : "Added by you")
                        .foregroundStyle(TallyColor.inkSecondary)
                }
                .font(.system(size: 15))
                .foregroundStyle(TallyColor.ink)
                .settingsRowBackground()
            }
        }
        .listStyle(.insetGrouped)
        .settingsSurface()
        .navigationTitle(venue.name.isEmpty ? "Venue" : venue.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { try? modelContext.save() }
    }

    private var categoryBinding: Binding<VenueCategory> {
        Binding(
            get: { venue.category },
            set: { venue.category = $0 }
        )
    }
}

// MARK: - Suppressed places

/// SPEC §9 Venues: *"suppressed-places list with un-suppress."*
///
/// These are the spots the discovery tier was told to forget (SPEC §2, "Not a
/// bar / don't ask here"). Un-suppressing deletes the marker, which is all it
/// ever was.
struct SuppressedPlacesView: View {

    @Environment(\.modelContext) private var modelContext

    @Query(sort: [SortDescriptor(\SuppressedPlace.createdAt, order: .reverse)])
    private var places: [SuppressedPlace]

    var body: some View {
        List {
            if places.isEmpty {
                Section {
                    Text("Nothing suppressed. Choosing \"Not a bar\" on a discovery prompt adds the spot here.")
                        .font(.system(size: 13))
                        .foregroundStyle(TallyColor.inkSecondary)
                        .settingsRowBackground()
                }
            } else {
                Section {
                    ForEach(places) { place in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name ?? "Unnamed place")
                                    .font(.system(size: 15))
                                    .foregroundStyle(TallyColor.ink)
                                Text(coordinateLabel(place))
                                    .font(.system(size: 12).monospacedDigit())
                                    .foregroundStyle(TallyColor.inkSecondary)
                            }

                            Spacer(minLength: 8)

                            Button("Un-suppress") { unsuppress(place) }
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(TallyColor.aquaBright)
                                .buttonStyle(.plain)
                        }
                        .settingsRowBackground()
                    }
                } footer: {
                    SettingsSectionFootnote(
                        text: "Un-suppressing lets Bar Radar's discovery tier consider the spot again."
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .settingsSurface()
        .navigationTitle("Suppressed places")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(SettingsA11y.Venues.suppressedList)
    }

    private func coordinateLabel(_ place: SuppressedPlace) -> String {
        let latitude = place.latitude.formatted(.number.precision(.fractionLength(4)))
        let longitude = place.longitude.formatted(.number.precision(.fractionLength(4)))
        return "\(latitude), \(longitude)"
    }

    private func unsuppress(_ place: SuppressedPlace) {
        modelContext.delete(place)
        try? modelContext.save()
    }
}
