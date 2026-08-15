import SwiftUI
import TallyKit

/// The Session snapshot from SPEC §2: *"a rendered card (image or text) with
/// venue, date, counts, spacers, duration, and badges earned."*
///
/// A value type on purpose. `ImageRenderer` needs a view whose content cannot
/// change mid-render, and a snapshot is also the only honest thing to export:
/// the card is a static artifact, since "recipients don't have your data and
/// there's no backend to host a live view" (SPEC §2).
public struct SessionShareSnapshot: Hashable, Sendable, Identifiable {

    public let id: UUID
    public let venueName: String

    /// "Friday, Aug 8 · 2 h 10 m".
    public let dateLine: String

    public let alcoholicCount: Int
    public let nonAlcoholicCount: Int
    public let spacerCount: Int

    /// "1 : 2" — NA : alcoholic, reduced.
    public let ratioText: String

    public let badges: [Badge]
    public let points: Int
    public let note: String?

    public init(
        id: UUID,
        venueName: String,
        dateLine: String,
        alcoholicCount: Int,
        nonAlcoholicCount: Int,
        spacerCount: Int,
        ratioText: String,
        badges: [Badge] = [],
        points: Int = 0,
        note: String? = nil
    ) {
        self.id = id
        self.venueName = venueName
        self.dateLine = dateLine
        self.alcoholicCount = alcoholicCount
        self.nonAlcoholicCount = nonAlcoholicCount
        self.spacerCount = spacerCount
        self.ratioText = ratioText
        self.badges = badges
        self.points = points
        self.note = note
    }

    /// Builds the card's contents from a derived Session. Every number comes off
    /// `DerivedSession` and `ScoringEngine`, so the card can never disagree with
    /// History or the You tab about the same night.
    public static func make(
        session: DerivedSession,
        venue: VenueSnapshot?,
        scoring: ScoringEngine = ScoringEngine(),
        now: Date = Date()
    ) -> SessionShareSnapshot {

        var badges: [Badge] = []
        if scoring.isDesignatedLegend(session, venue: venue) { badges.append(.designatedLegend) }
        if scoring.isPacer(session) { badges.append(.pacer) }

        let name = venue?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return SessionShareSnapshot(
            id: session.id,
            venueName: name.isEmpty ? "A night out" : name,
            dateLine: "\(SessionFormatting.longDate(session.startedAt)) · \(SessionFormatting.duration(session.duration))",
            alcoholicCount: session.alcoholicCount,
            nonAlcoholicCount: session.nonAlcoholicCount,
            spacerCount: session.spacerCount,
            ratioText: TrendsMath.ratioText(
                alcoholic: session.alcoholicCount,
                nonAlcoholic: session.nonAlcoholicCount
            ),
            badges: badges,
            points: scoring.score(session, asOf: now).total,
            note: session.hasNote ? session.note : nil
        )
    }

    /// A stand-in used by previews and by the share sheet before a real Session
    /// is available. Mirrors the mockup's card exactly.
    public static let sample = SessionShareSnapshot(
        id: UUID(),
        venueName: "The Anchor",
        dateLine: "Friday, Aug 8 · 2 h 10 m",
        alcoholicCount: 4,
        nonAlcoholicCount: 2,
        spacerCount: 2,
        ratioText: "1 : 2",
        badges: [.pacer],
        points: 105
    )
}

// MARK: - The card

/// The share-sheet artifact (SPEC §2, `design/ux-mockups.html` "Share card").
///
/// Rendered at a fixed width by `SessionShareRenderer` — it must not depend on
/// the device's size class, dynamic type, or colour scheme, because the export
/// has to look the same wherever it lands.
public struct SessionShareCard: View {

    /// The width `ImageRenderer` lays the card out at. The mockup's card is 300
    /// points wide; 320 keeps a long venue name on one line.
    public static let cardWidth: CGFloat = 320

    private let snapshot: SessionShareSnapshot

    public init(snapshot: SessionShareSnapshot) {
        self.snapshot = snapshot
    }

    public init(
        session: DerivedSession,
        venue: VenueSnapshot?,
        scoring: ScoringEngine = ScoringEngine(),
        now: Date = Date()
    ) {
        self.init(snapshot: .make(session: session, venue: venue, scoring: scoring, now: now))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            stats
            if let note = snapshot.note {
                Text("\u{201C}\(note)\u{201D}")
                    .font(.system(size: 12, design: .serif))
                    .italic()
                    .foregroundStyle(TallyColor.amberBright)
                    .lineLimit(2)
            }
            footer
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(width: Self.cardWidth, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(TrendsA11y.ShareCard.card)
        .accessibilityLabel("Session card")
        .accessibilityValue(accessibilitySummary)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 9) {
            // SPEC's app mark: the five-stroke tally character 正.
            Text("\u{6B63}")
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(TallyColor.amberBright)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.venueName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(TallyColor.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(snapshot.dateLine)
                    .font(.system(size: 11))
                    .foregroundStyle(TallyColor.inkSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var stats: some View {
        HStack(alignment: .top, spacing: 16) {
            stat(
                value: "\(snapshot.alcoholicCount)",
                label: "Drinks",
                swatch: TallyColor.amber
            )
            stat(
                value: "\(snapshot.spacerCount)",
                label: "Spacers",
                swatch: TallyColor.aqua
            )
            stat(
                value: snapshot.ratioText,
                label: "NA ratio",
                swatch: nil
            )
            Spacer(minLength: 0)
        }
    }

    private func stat(value: String, label: String, swatch: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 24, weight: .bold).monospacedDigit())
                .foregroundStyle(TallyColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            HStack(spacing: 4) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(swatch)
                        .frame(width: 7, height: 7)
                }
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .textCase(.uppercase)
                    .kerning(0.7)
                    .foregroundStyle(TallyColor.inkSecondary)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            HStack(spacing: 8) {
                if snapshot.badges.isEmpty {
                    Label("+\(snapshot.points) pts", systemImage: "drop.circle")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 9.5, weight: .bold))
                        .textCase(.uppercase)
                        .kerning(0.5)
                        .foregroundStyle(TallyColor.aquaBright)
                } else {
                    ForEach(snapshot.badges, id: \.self) { badge in
                        Label(badge.title, systemImage: badge.systemImageName)
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 9.5, weight: .bold))
                            .textCase(.uppercase)
                            .kerning(0.5)
                            .foregroundStyle(TallyColor.amberBright)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Text("Tally")
                    .font(.system(size: 10, weight: .bold))
                    .textCase(.uppercase)
                    .kerning(1.2)
                    .foregroundStyle(TallyColor.inkTertiary)
            }
        }
    }

    private var cardBackground: some View {
        ZStack {
            Color(hex: 0x12161F)
            RadialGradient(
                colors: [Color(hex: 0x232C3E), Color(hex: 0x12161F).opacity(0)],
                center: UnitPoint(x: 0.2, y: 0),
                startRadius: 0,
                endRadius: 260
            )
        }
    }

    private var accessibilitySummary: String {
        var parts = [
            snapshot.venueName,
            snapshot.dateLine,
            "\(snapshot.alcoholicCount) alcoholic",
            "\(snapshot.nonAlcoholicCount) non-alcoholic",
            "\(snapshot.spacerCount) spacers",
            "ratio \(snapshot.ratioText)"
        ]
        if snapshot.badges.isEmpty {
            parts.append("\(snapshot.points) points")
        } else {
            parts.append(contentsOf: snapshot.badges.map(\.title))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Previews

#Preview("Share card") {
    ZStack {
        TallyColor.pageGradient.ignoresSafeArea()
        SessionShareCard(snapshot: .sample)
    }
    .preferredColorScheme(.dark)
}
