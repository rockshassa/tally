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

    /// SPEC §1: "Tapping the card opens the check-in picker (§2) to assign — or
    /// change — the Session's venue."
    ///
    /// Optional so previews and any host without the `place` slots still draw a
    /// card — an inert one, which is what it was before this existed, and which
    /// is why the headline only promises a tap when there is one to make.
    var onTap: (() -> Void)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if session.isActive(asOf: context.date) {
                if let onTap {
                    Button(action: onTap) {
                        card(now: context.date)
                    }
                    .buttonStyle(.plain)
                    .modifier(
                        SessionCardAccessibility(label: label(now: context.date), isButton: true)
                    )
                } else {
                    card(now: context.date)
                        .modifier(
                            SessionCardAccessibility(label: label(now: context.date), isButton: false)
                        )
                }
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
        .contentShape(Rectangle())
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func label(now: Date) -> String {
        "\(headline). \(detail(now: now))"
    }

    /// SPEC §1: "An untagged card says so ('Session in progress · tap to add
    /// where')" — but only where there is something to tap.
    private var headline: String {
        if let venueName, !venueName.isEmpty {
            "Session · \(venueName)"
        } else if onTap != nil {
            "Session in progress · tap to add where"
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

/// One accessibility element, whether or not the card is a button.
///
/// The identifier lands on whatever the user actually touches — the `Button`
/// when there is one — because `tally.sessionCard` is what the XCUITest suite
/// taps (PLAN Gate 1: these strings are API).
private struct SessionCardAccessibility: ViewModifier {

    let label: String

    /// SPEC §1's tap. The trait and the hint are stated rather than inherited,
    /// because collapsing the card into one element is what makes the two lines
    /// readable — and it would otherwise take the button-ness with it.
    let isButton: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier(A11y.Tally.sessionCard)
            .accessibilityLabel(label)
            .accessibilityAddTraits(isButton ? [.isButton] : [])
            .accessibilityHint(isButton ? "Assign a venue" : "")
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
