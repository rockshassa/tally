import CoreLocation
import MapKit
import SwiftData
import SwiftUI
import TallyKit

/// "Set Home" — onboarding screen 3 (SPEC §9), and the same screen again from
/// Settings → Venues later (SPEC §9).
///
/// SPEC §2: Home is *user-defined*, never inferred — "inferring where someone
/// sleeps is a privacy footgun". Drinks inside this circle are tagged with no
/// prompt at all.
///
/// A plain view with explicit callbacks: pass `onSkip` to get the skippable
/// onboarding treatment, omit it for the Settings presentation.
public struct HomeSetupView: View {

    // MARK: Inputs

    private let initialCoordinate: CLLocationCoordinate2D?
    private let locationService: (any LocationFixProviding)?
    private let onSave: (Venue) -> Void
    private let onSkip: (() -> Void)?

    // MARK: State

    @Environment(\.modelContext) private var modelContext

    @State private var coordinate: CLLocationCoordinate2D
    @State private var radiusMeters: Double
    @State private var cameraPosition: MapCameraPosition
    @State private var isLocating = false
    @State private var hasResolvedInitialPin = false
    @State private var resolvedLocationService: (any LocationFixProviding)?

    /// Fallback centre when there's no fix and no saved Home yet: mid-Atlantic
    /// would be absurd, so start on a wide view of the user's region-neutral
    /// default and let them pan.
    private static let fallbackCoordinate = CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)

    public init(
        initialCoordinate: CLLocationCoordinate2D? = nil,
        initialRadiusMeters: Double = VenueCategory.home.defaultRadiusMeters,
        locationService: (any LocationFixProviding)? = nil,
        onSave: @escaping (Venue) -> Void = { _ in },
        onSkip: (() -> Void)? = nil
    ) {
        self.initialCoordinate = initialCoordinate
        self.locationService = locationService
        self.onSave = onSave
        self.onSkip = onSkip

        let start = initialCoordinate ?? Self.fallbackCoordinate
        _coordinate = State(initialValue: start)
        _radiusMeters = State(initialValue: initialRadiusMeters)
        _cameraPosition = State(
            initialValue: .region(
                MKCoordinateRegion(center: start, latitudinalMeters: 600, longitudinalMeters: 600)
            )
        )
    }

    // MARK: Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            map
            controls
        }
        .placeNightSurface()
        .task { await resolveInitialPin() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set your home")
                .font(.system(size: 28, weight: .semibold, design: .serif))
                .foregroundStyle(PlacePalette.ink)

            Text("Drinks inside this circle get tagged as Home, with no check-in prompt. Tally never guesses where you live — this pin is the only way it knows.")
                .font(.system(size: 14))
                .foregroundStyle(PlacePalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                MapCircle(center: coordinate, radius: radiusMeters)
                    .foregroundStyle(PlacePalette.amberBright.opacity(0.14))
                    .stroke(PlacePalette.amberBright.opacity(0.65), lineWidth: 1.5)

                Annotation("Home", coordinate: coordinate) {
                    pin
                }
                .annotationTitles(.hidden)
            }
            .mapStyle(.standard(elevation: .flat))
            .onTapGesture { point in
                guard let tapped = proxy.convert(point, from: .local) else { return }
                withAnimation(.snappy(duration: 0.2)) { coordinate = tapped }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(PlacePalette.line, lineWidth: 1)
        )
        .overlay(alignment: .bottomLeading) { mapHint }
        .padding(.horizontal, 22)
    }

    private var pin: some View {
        ZStack {
            Circle()
                .fill(PlacePalette.amberBright)
                .frame(width: 22, height: 22)
                .shadow(color: PlacePalette.amberBright.opacity(0.5), radius: 8)
            Image(systemName: "house.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(PlacePalette.backgroundDeep)
        }
    }

    private var mapHint: some View {
        Text("Tap the map to move the pin")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(PlacePalette.ink2)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(PlacePalette.backgroundDeep.opacity(0.85)))
            .padding(12)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {

            HStack {
                Text("Radius")
                    .font(.system(size: 13, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(PlacePalette.ink3)
                Spacer()
                Text("\(Int(radiusMeters.rounded())) m")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(PlacePalette.ink)
            }

            Slider(value: $radiusMeters, in: 25...300, step: 5)
                .tint(PlacePalette.amberBright)

            if canUseCurrentLocation {
                Button {
                    Task { await useCurrentLocation() }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: isLocating ? "location.fill" : "location")
                        Text(isLocating ? "Locating…" : "Use my current location")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PlacePalette.aquaBright)
                }
                .buttonStyle(.plain)
                .disabled(isLocating)
            }

            Button(action: save) {
                Text("Save home")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(PlacePalette.amberBright)
                    )
                    .foregroundStyle(PlacePalette.backgroundDeep)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("homeSetup.saveButton")

            if let onSkip {
                Button("Not now", action: onSkip)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PlacePalette.ink3)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("homeSetup.skipButton")
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 24)
    }

    // MARK: Behavior

    private var canUseCurrentLocation: Bool {
        activeLocationService?.authorization.allowsOneShotFix ?? false
    }

    private var activeLocationService: (any LocationFixProviding)? {
        locationService ?? resolvedLocationService
    }

    /// Pre-fills from the saved Home first (this screen doubles as the editor),
    /// then from the current fix "when permitted" (SPEC §9 screen 3).
    private func resolveInitialPin() async {
        guard !hasResolvedInitialPin else { return }
        hasResolvedInitialPin = true

        if resolvedLocationService == nil, locationService == nil {
            resolvedLocationService = LocationService()
        }

        if initialCoordinate == nil, let existing = try? VenueWriter.home(in: modelContext) {
            radiusMeters = existing.radiusMeters
            move(to: CLLocationCoordinate2D(latitude: existing.latitude, longitude: existing.longitude))
            return
        }

        guard initialCoordinate == nil else { return }
        await useCurrentLocation()
    }

    private func useCurrentLocation() async {
        guard let service = activeLocationService, service.authorization.allowsOneShotFix else { return }
        isLocating = true
        defer { isLocating = false }
        guard let fix = await service.oneShotFix() else { return }
        move(to: fix.coordinate)
    }

    private func move(to newCoordinate: CLLocationCoordinate2D) {
        coordinate = newCoordinate
        cameraPosition = .region(
            MKCoordinateRegion(center: newCoordinate, latitudinalMeters: 600, longitudinalMeters: 600)
        )
    }

    private func save() {
        guard let venue = try? VenueWriter.saveHome(
            coordinate: coordinate,
            radiusMeters: radiusMeters,
            in: modelContext
        ) else { return }
        onSave(venue)
    }
}

#Preview("Home setup") {
    HomeSetupView(onSkip: {})
        .modelContainer(for: [DrinkEvent.self, Venue.self, TallyKit.Session.self, SuppressedPlace.self], inMemory: true)
}
