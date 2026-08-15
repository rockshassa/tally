import SwiftUI
import TallyKit

/// The live Session card (SPEC §1, §2): *"Session at The Anchor — 3 drinks ·
/// 1 spacer · 1 h 40 m"*.
///
/// Shown only while the Session is still accepting drinks. The elapsed time is
/// driven by a `TimelineView`, which also means the card retires itself the
/// moment the Session closes — three hours after the last drink, or at a Bar
/// Radar exit, whichever came first (SPEC §2) — without anything else needing
/// to notice.
struct LiveSessionCard: View {

    let session: DerivedSession

    /// Resolved by the caller from the venue store; `nil` until a check-in
    /// happens (SPEC §2 step 4: coordinates only, assign a venue later).
    let venueName: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if session.isActive(asOf: context.date) {
                card(now: context.date)
            }
        }
    }

    private func card(now: Date) -> some View {
        HStack(spacing: 12) {
            PulseDot()

            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TallyColor.ink)

                Text(detail(now: now))
                    .font(.caption)
                    .foregroundStyle(TallyColor.inkSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .tallyGlassCard(strong: true)
        .accessibilityIdentifier(A11y.Tally.sessionCard)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(headline). \(detail(now: now))")
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var headline: String {
        if let venueName, !venueName.isEmpty {
            "Session · \(venueName)"
        } else {
            "Session in progress"
        }
    }

    private func detail(now: Date) -> String {
        var parts: [String] = [pluralized(session.alcoholicCount, "drink")]

        if session.nonAlcoholicCount > 0 {
            parts.append("\(session.nonAlcoholicCount) NA")
        }
        if session.spacerCount > 0 {
            parts.append(pluralized(session.spacerCount, "spacer"))
        }
        parts.append(Self.elapsed(from: session.startedAt, to: now))

        return parts.joined(separator: " · ")
    }

    private func pluralized(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// "1 h 40 m" — the format the mockups and SPEC §2 use.
    static func elapsed(from start: Date, to now: Date) -> String {
        let totalMinutes = max(0, Int(now.timeIntervalSince(start) / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours) h \(minutes) m" : "\(minutes) m"
    }
}

/// The "still going" indicator from the mockups.
private struct PulseDot: View {

    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(TallyColor.amberBright)
            .frame(width: 8, height: 8)
            .shadow(color: TallyColor.amberBright.opacity(0.8), radius: isPulsing ? 6 : 2)
            .opacity(isPulsing ? 0.55 : 1)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
            .accessibilityHidden(true)
    }
}
