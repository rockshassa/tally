import SwiftData
import SwiftUI
import TallyKit
import UIKit

/// Turning a Session into a shareable image (SPEC §2).
///
/// `ImageRenderer` rather than a screenshot: the card is laid out at a fixed
/// width and at the display's scale, so the export looks the same whatever
/// device made it.
@MainActor
public enum SessionShareRenderer {

    /// Renders the card. Returns `nil` only if the renderer itself fails, which
    /// the caller treats as "no share this time" rather than an error state.
    public static func image(for snapshot: SessionShareSnapshot, scale: CGFloat = 3) -> UIImage? {
        let renderer = ImageRenderer(
            content: SessionShareCard(snapshot: snapshot)
                .frame(width: SessionShareCard.cardWidth)
        )
        renderer.scale = max(scale, 1)
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// The plain-text half of SPEC §2's "image or text" — used as the share
    /// sheet's subject line and by anything that cannot take an image.
    public static func text(for snapshot: SessionShareSnapshot) -> String {
        var line = "\(snapshot.venueName) · \(snapshot.dateLine) — "
        line += "\(snapshot.alcoholicCount) drinks, \(snapshot.nonAlcoholicCount) non-alc"
        if snapshot.spacerCount > 0 {
            line += ", \(snapshot.spacerCount) spacer\(snapshot.spacerCount == 1 ? "" : "s")"
        }
        if let badge = snapshot.badges.first {
            line += " · \(badge.title)"
        }
        return line
    }
}

// MARK: - The entry point the integrator mounts

/// The share affordance for one Session (SPEC §2).
///
/// ## Where it goes
///
/// `SessionDetailView`'s action stack, next to Add note and Pin — the mockup's
/// "Share card" row. The detail screen is owned by the `place` workstream, so
/// this button is written to drop in without that file changing shape:
///
/// ```swift
/// SessionShareButton(session: session, venue: model.venue(for: session)) { touched in
///     model.materialize(touched)   // keeps HistoryModel's caches in step
///     model.reload()
/// }
/// ```
///
/// ## Materialize-on-touch
///
/// SPEC §2: *"Sharing materializes the Session."* Tapping the button persists
/// the record **before** the card is rendered, through `EventStore.materialize`
/// — the one sanctioned path — so the shared night can never dangle if a later
/// event edit re-keys the derivation. Pass `onMaterialize` to route that through
/// `HistoryModel` instead, which does the same write and refreshes the screen.
public struct SessionShareButton<Label: View>: View {

    private let session: DerivedSession
    private let venue: VenueSnapshot?
    private let scoring: ScoringEngine
    private let onMaterialize: ((DerivedSession) -> Void)?
    private let label: () -> Label

    @Environment(\.modelContext) private var modelContext
    @Environment(\.displayScale) private var displayScale

    @State private var prepared: PreparedShare?

    public init(
        session: DerivedSession,
        venue: VenueSnapshot? = nil,
        scoring: ScoringEngine = ScoringEngine(),
        onMaterialize: ((DerivedSession) -> Void)? = nil,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.session = session
        self.venue = venue
        self.scoring = scoring
        self.onMaterialize = onMaterialize
        self.label = label
    }

    public var body: some View {
        Button(action: prepare) { label() }
            .buttonStyle(.plain)
            .accessibilityIdentifier(TrendsA11y.ShareCard.button)
            .sheet(item: $prepared) { share in
                SessionSharePreviewSheet(share: share)
            }
    }

    private func prepare() {
        // SPEC §2: sharing is a touch, and a touch materializes.
        if let onMaterialize {
            onMaterialize(session)
        } else {
            try? EventStore.materialize(session, in: modelContext)
        }

        let snapshot = SessionShareSnapshot.make(
            session: session,
            venue: venue,
            scoring: scoring
        )
        guard let image = SessionShareRenderer.image(for: snapshot, scale: displayScale) else { return }
        prepared = PreparedShare(snapshot: snapshot, image: image)
    }
}

// MARK: - Default label

public extension SessionShareButton where Label == SessionShareButtonLabel {

    /// The drop-in version: `SessionShareButton(session:venue:)` wearing the
    /// same glass row as the rest of `SessionDetailView`'s actions.
    init(
        session: DerivedSession,
        venue: VenueSnapshot? = nil,
        scoring: ScoringEngine = ScoringEngine(),
        title: String = "Share card",
        onMaterialize: ((DerivedSession) -> Void)? = nil
    ) {
        self.init(
            session: session,
            venue: venue,
            scoring: scoring,
            onMaterialize: onMaterialize
        ) {
            SessionShareButtonLabel(title: title)
        }
    }
}

/// The mockup's "Share card" action row.
public struct SessionShareButtonLabel: View {

    let title: String

    public init(title: String = "Share card") {
        self.title = title
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
        }
        .foregroundStyle(TallyColor.ink)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TallyColor.glass)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TallyColor.line, lineWidth: 1)
        )
    }
}

// MARK: - Prepared share

/// A rendered card waiting for the share sheet.
struct PreparedShare: Identifiable {

    let snapshot: SessionShareSnapshot
    let image: UIImage

    var id: UUID { snapshot.id }
}

// MARK: - Preview sheet

/// Shows the exact artifact before it leaves the device, then hands it to
/// `ShareLink`. Seeing the card first is the point — a share sheet that fires
/// straight from a tap gives no chance to check what is about to be sent.
struct SessionSharePreviewSheet: View {

    let share: PreparedShare

    @Environment(\.dismiss) private var dismiss

    private var image: Image { Image(uiImage: share.image) }

    var body: some View {
        VStack(spacing: 18) {
            Text("Share this Session")
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundStyle(TallyColor.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            image
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: SessionShareCard.cardWidth)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: Color.black.opacity(0.45), radius: 18, y: 10)
                .accessibilityLabel("Preview of the Session card")

            Text("A static image — recipients don't have your data, and nothing about this night leaves the device unless you send it.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundStyle(TallyColor.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            ShareLink(
                item: image,
                subject: Text(share.snapshot.venueName),
                message: Text(SessionShareRenderer.text(for: share.snapshot)),
                preview: SharePreview(share.snapshot.venueName, image: image)
            ) {
                Text("Share…")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TallyColor.backgroundDeep)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(TallyColor.amberBright)
                    )
            }
            .accessibilityIdentifier(TrendsA11y.ShareCard.shareLink)

            Button("Done") { dismiss() }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(TallyColor.inkSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .accessibilityIdentifier(TrendsA11y.ShareCard.done)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(TallyColor.pageGradient.ignoresSafeArea())
        .presentationBackground(TallyColor.backgroundDeep)
        .presentationCornerRadius(28)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(TrendsA11y.ShareCard.sheet)
    }
}

// MARK: - Previews

#Preview("Share sheet") {
    SessionSharePreviewSheet(
        share: PreparedShare(
            snapshot: .sample,
            image: SessionShareRenderer.image(for: .sample) ?? UIImage()
        )
    )
    .preferredColorScheme(.dark)
}
