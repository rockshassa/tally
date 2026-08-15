import SwiftData
import SwiftUI
import TallyKit

/// One outing, opened up (SPEC §2): the drink timeline, what it scored, and the
/// three things you can do to it — note, pin, and name the place.
///
/// Notes and pins **materialize** the Session before writing (SPEC §2
/// materialize-on-touch), which is handled by `HistoryModel` so there is exactly
/// one code path that can create a `Session` record.
public struct SessionDetailView: View {

    // MARK: Inputs

    private let sessionID: UUID
    private let injectedModel: HistoryModel?
    private let locationService: (any LocationFixProviding)?
    private let poiSearch: (any POISearching)?
    private let permissions: (any PermissionsService)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// One sheet slot, not three: stacking several `.sheet` modifiers on a
    /// single view is the classic way to get a presentation that silently
    /// refuses to appear.
    private enum DetailSheet: Identifiable {
        case note
        case venue
        case event(UUID)

        var id: String {
            switch self {
            case .note: "note"
            case .venue: "venue"
            case .event(let id): "event-\(id.uuidString)"
            }
        }
    }

    @State private var model: HistoryModel?
    @State private var activeSheet: DetailSheet?
    @State private var noteDraft = ""
    @State private var locationAuthorization: LocationAuthorization = .notDetermined
    @State private var resolvedPermissions: (any PermissionsService)?

    public init(
        sessionID: UUID,
        model: HistoryModel? = nil,
        locationService: (any LocationFixProviding)? = nil,
        poiSearch: (any POISearching)? = nil,
        permissions: (any PermissionsService)? = nil
    ) {
        self.sessionID = sessionID
        self.injectedModel = model
        self.locationService = locationService
        self.poiSearch = poiSearch
        self.permissions = permissions
    }

    // MARK: Body

    public var body: some View {
        ScrollView {
            if let model, let session = model.session(id: sessionID) {
                content(session: session, model: model)
            }
        }
        .scrollIndicators(.hidden)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .placeNightSurface()
        .task { await prepare() }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .note: noteEditor
            case .venue: venueAssignment
            case .event(let id): eventEditor(eventID: id)
            }
        }
        // Deleting the first drink re-keys an unmaterialized Session (its ID is
        // that event's UUID, SPEC §2), and deleting the last one removes the
        // outing outright. Either way this screen no longer has a subject.
        .onChange(of: sessionStillExists) { _, exists in
            if !exists { dismiss() }
        }
    }

    private var sessionStillExists: Bool {
        guard let model, model.hasLoaded else { return true }
        return model.session(id: sessionID) != nil
    }

    private var navigationTitle: String {
        guard let model, let session = model.session(id: sessionID) else { return "Session" }
        return SessionFormatting.venueName(for: session, venues: model.venues)
    }

    @ViewBuilder
    private func content(session: DerivedSession, model: HistoryModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            header(session: session, model: model)
            timeline(session: session)
            summary(session: session, model: model)
            actions(session: session, model: model)

            if session.venueID == nil {
                untaggedFooter(session: session)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 32)
    }

    // MARK: Header

    private func header(session: DerivedSession, model: HistoryModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SessionFormatting.venueName(for: session, venues: model.venues))
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundStyle(session.venueID == nil ? PlacePalette.ink2 : PlacePalette.ink)

            HStack(spacing: 0) {
                Text("\(SessionFormatting.longDate(session.startedAt)) · \(SessionFormatting.timeRange(from: session.startedAt, to: session.endedAt))")
                    .font(.system(size: 13))
                    .foregroundStyle(PlacePalette.ink3)
            }

            if let note = session.note, session.hasNote {
                Text("\u{201C}\(note)\u{201D}")
                    .font(.system(size: 14, design: .serif))
                    .italic()
                    .foregroundStyle(PlacePalette.amberBright)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    // MARK: Timeline

    private func timeline(session: DerivedSession) -> some View {
        let spacerIDs = Set(session.spacerEventIDs)

        return VStack(spacing: 0) {
            ForEach(Array(session.events.enumerated()), id: \.element.id) { index, event in
                Button {
                    activeSheet = .event(event.id)
                } label: {
                    SessionTimelineRow(
                        event: event,
                        isSpacer: spacerIDs.contains(event.id),
                        isFirst: index == 0,
                        isLast: index == session.events.count - 1
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Summary

    private func summary(session: DerivedSession, model: HistoryModel) -> some View {
        HStack(alignment: .top, spacing: 0) {
            summaryCell(
                key: "Session",
                value: session.alcoholicCount == 0
                    ? "\(session.nonAlcoholicCount) non-alc"
                    : "\(session.alcoholicCount) · \(session.spacerCount) spacers"
            )
            summaryCell(key: "Duration", value: SessionFormatting.duration(session.duration))
            summaryCell(
                key: "Points",
                value: "+\(model.score(for: session).total)",
                tint: PlacePalette.aquaBright
            )
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .placeGlassCard()
    }

    private func summaryCell(key: String, value: String, tint: Color = PlacePalette.ink) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(PlacePalette.ink3)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private func actions(session: DerivedSession, model: HistoryModel) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                actionButton(
                    title: session.hasNote ? "Edit note" : "Add note",
                    systemImage: "square.and.pencil"
                ) {
                    noteDraft = session.note ?? ""
                    activeSheet = .note
                }

                actionButton(
                    title: session.pinned ? "Pinned" : "Pin",
                    systemImage: session.pinned ? "mappin.circle.fill" : "mappin",
                    tint: session.pinned ? PlacePalette.amberBright : PlacePalette.ink
                ) {
                    model.togglePin(on: session)
                    model.reload()
                }
            }

            actionButton(
                title: session.venueID == nil ? "Assign a venue" : "Change venue",
                systemImage: "mappin.and.ellipse"
            ) {
                activeSheet = .venue
            }

            // SPEC §2: sharing materializes the Session first (materialize-on-touch).
            SessionShareButton(session: session, venue: model.venue(for: session)) { touched in
                _ = model.materialize(touched)
                model.reload()
            }
        }
    }

    private func actionButton(
        title: String,
        systemImage: String,
        tint: Color = PlacePalette.ink,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13.5, weight: .medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .placeGlassCard(cornerRadius: 14)
        }
        .buttonStyle(.plain)
    }

    /// SPEC §9 etiquette: "a feature explains what it's missing only where that
    /// feature lives… never as an interrupting popup."
    @ViewBuilder
    private func untaggedFooter(session: DerivedSession) -> some View {
        if locationAuthorization.needsSystemSettings {
            Button {
                activePermissions?.openSystemSettings()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "location.slash").font(.system(size: 12))
                    Text("Enable location to tag venues automatically")
                        .font(.system(size: 12.5))
                    Spacer()
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
                }
                .foregroundStyle(PlacePalette.ink3)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .placeGlassCard(cornerRadius: 12)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Sheets

    private var noteEditor: some View {
        SessionNoteEditor(
            note: $noteDraft,
            onSave: {
                if let model, let session = model.session(id: sessionID) {
                    model.setNote(noteDraft, on: session)
                    model.reload()
                }
                activeSheet = nil
            },
            onCancel: { activeSheet = nil }
        )
    }

    @ViewBuilder
    private var venueAssignment: some View {
        if let model, let session = model.session(id: sessionID) {
            VenueAssignmentView(
                session: session,
                savedVenues: model.savedVenues(),
                locationService: locationService,
                poiSearch: poiSearch,
                onAssign: { candidate in
                    model.assignVenue(candidate, to: session)
                    activeSheet = nil
                },
                onClear: session.venueID == nil ? nil : {
                    model.clearVenue(from: session)
                    activeSheet = nil
                },
                onCancel: { activeSheet = nil }
            )
        }
    }

    @ViewBuilder
    private func eventEditor(eventID: UUID) -> some View {
        if let model,
           let session = model.session(id: sessionID),
           let event = session.events.first(where: { $0.id == eventID }) {
            SessionEventEditSheet(
                event: event,
                onSave: { newTimestamp in
                    model.updateTimestamp(newTimestamp, forEventWith: eventID)
                    activeSheet = nil
                },
                onDelete: {
                    model.deleteEvent(id: eventID)
                    activeSheet = nil
                },
                onCancel: { activeSheet = nil }
            )
        }
    }

    // MARK: Plumbing

    private var activePermissions: (any PermissionsService)? {
        permissions ?? resolvedPermissions
    }

    private func prepare() async {
        if model == nil {
            model = injectedModel ?? HistoryModel(modelContext: modelContext)
        }
        model?.reload()

        if permissions == nil, resolvedPermissions == nil {
            resolvedPermissions = LivePermissionsService()
        }
        locationAuthorization = activePermissions?.locationAuthorization() ?? .notDetermined
    }
}

// MARK: - Timeline row

/// One drink on the rail: time, the type-coded dot, its label, and — for
/// spacers — the points it earned inline (SPEC §3, mockups).
struct SessionTimelineRow: View {

    let event: DrinkEventSnapshot
    let isSpacer: Bool
    let isFirst: Bool
    let isLast: Bool

    /// +10 per NA drink, +25 more when it's a spacer (SPEC §3). Alcohol never
    /// scores — that is the design rule, not an omission.
    private var points: Int? {
        guard event.type == .nonAlcoholic else { return nil }
        return isSpacer ? 35 : 10
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {

            Text(SessionFormatting.time(event.timestamp))
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(PlacePalette.ink3)
                .frame(width: 52, alignment: .leading)

            rail

            VStack(alignment: .leading, spacing: 1) {
                Text(event.type == .alcoholic ? "Drink" : "Water · NA")
                    .font(.system(size: 14.5))
                    .foregroundStyle(PlacePalette.ink)
                if isSpacer {
                    Text("Spacer")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(PlacePalette.aqua)
                } else if event.source != .app {
                    Text(event.source.displayName)
                        .font(.system(size: 11.5))
                        .foregroundStyle(PlacePalette.ink3)
                }
            }

            Spacer(minLength: 6)

            if let points {
                Text("+\(points)")
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(PlacePalette.aquaBright)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private var rail: some View {
        ZStack {
            Rectangle()
                .fill(PlacePalette.line)
                .frame(width: 1)
                .padding(.top, isFirst ? 14 : 0)
                .padding(.bottom, isLast ? 14 : 0)

            Circle()
                .fill(PlacePalette.tint(for: event.type))
                .frame(width: 9, height: 9)
        }
        .frame(width: 12, height: 34)
    }
}

// MARK: - Note editor

/// SPEC §2: "any Session in History can be given a note… either action
/// materializes it." Deliberately one field and two buttons.
struct SessionNoteEditor: View {

    @Binding var note: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Note")
                .font(.system(size: 22, weight: .semibold, design: .serif))
                .foregroundStyle(PlacePalette.ink)

            TextField("Dave's birthday", text: $note, axis: .vertical)
                .font(.system(size: 16, design: .serif))
                .foregroundStyle(PlacePalette.ink)
                .lineLimit(1...4)
                .padding(14)
                .placeGlassCard(cornerRadius: 14)

            Text("Adding a note saves this Session permanently, so the name sticks to the night.")
                .font(.system(size: 12))
                .foregroundStyle(PlacePalette.ink3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PlacePalette.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .placeGlassCard(cornerRadius: 14)

                Button("Save", action: onSave)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PlacePalette.backgroundDeep)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(PlacePalette.amberBright)
                    )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .placeNightSurface()
        .presentationDetents([.height(340)])
        .presentationBackground(PlacePalette.backgroundDeep)
        .presentationCornerRadius(28)
    }
}

// MARK: - Event editor

/// Timestamp correction and delete for one logged drink (SPEC §1's undo
/// semantics, applied retroactively from History).
struct SessionEventEditSheet: View {

    let event: DrinkEventSnapshot
    let onSave: (Date) -> Void
    let onDelete: () -> Void
    let onCancel: () -> Void

    @State private var timestamp: Date
    @State private var confirmingDelete = false

    init(
        event: DrinkEventSnapshot,
        onSave: @escaping (Date) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.event = event
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _timestamp = State(initialValue: event.timestamp)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            HStack(spacing: 8) {
                PlaceDrinkSwatch(type: event.type, size: 10)
                Text(event.type == .alcoholic ? "Drink" : "Water · NA")
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(PlacePalette.ink)
                Spacer()
                if event.source != .app {
                    PlaceChip(text: event.source.displayName)
                }
            }

            DatePicker("Logged at", selection: $timestamp)
                .datePickerStyle(.compact)
                .font(.system(size: 14))
                .foregroundStyle(PlacePalette.ink2)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .placeGlassCard(cornerRadius: 14)

            Text("Moving a drink can move it into — or out of — a different Session, since Sessions are computed from the times you logged.")
                .font(.system(size: 12))
                .foregroundStyle(PlacePalette.ink3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PlacePalette.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .placeGlassCard(cornerRadius: 14)

                Button("Save") { onSave(timestamp) }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PlacePalette.backgroundDeep)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(PlacePalette.amberBright)
                    )
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Text("Delete this drink")
                    .font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(red: 0.85, green: 0.35, blue: 0.35))
            .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .placeNightSurface()
        .presentationDetents([.height(400)])
        .presentationBackground(PlacePalette.backgroundDeep)
        .presentationCornerRadius(28)
        .confirmationDialog("Delete this drink?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("It disappears from your counts, trends, and this Session.")
        }
    }
}
