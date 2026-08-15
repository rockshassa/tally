import SwiftUI

/// The buttons the whole product is built around (SPEC §1).
///
/// Tap logs one drink. Long-press opens the retro-log sheet. The two gestures
/// share one control on purpose — SPEC §1 puts retro-logging behind a hold of
/// the same button, so there is never a second thing to aim at.
struct DrinkButton: View {

    enum Prominence {
        /// The amber +1 alcoholic button — the product.
        case primary
        /// The smaller aqua +1 NA button.
        case secondary

        var height: CGFloat {
            switch self {
            case .primary: TallyMetrics.primaryButtonHeight
            case .secondary: TallyMetrics.secondaryButtonHeight
            }
        }

        var titleFont: Font {
            switch self {
            case .primary: .system(size: 26, weight: .semibold, design: .rounded)
            case .secondary: .system(size: 18, weight: .semibold, design: .rounded)
            }
        }

        var plusFont: Font {
            switch self {
            case .primary: .system(size: 40, weight: .light, design: .rounded)
            case .secondary: .system(size: 26, weight: .light, design: .rounded)
            }
        }
    }

    let title: String
    let tint: TallyDrinkTint
    let prominence: Prominence
    let identifier: String
    let accessibilityLabel: String
    let action: () -> Void
    let longPressAction: () -> Void

    @State private var isPressed = false

    /// When the hold last fired. A long press also ends in a release, which the
    /// button reads as a tap — so a tap arriving on the heels of a hold is the
    /// tail of that hold, not a second drink. A timestamp rather than a flag
    /// because the release order of the two gestures is not guaranteed, and a
    /// flag that never got cleared would swallow the *next* real tap.
    @State private var lastLongPressAt: Date = .distantPast

    private static let longPressSwallowWindow: TimeInterval = 0.8

    var body: some View {
        Button {
            guard Date().timeIntervalSince(lastLongPressAt) > Self.longPressSwallowWindow else { return }
            action()
        } label: {
            HStack(spacing: 10) {
                Text("+")
                    .font(prominence.plusFont)
                Text(title)
                    .font(prominence.titleFont)
            }
            .foregroundStyle(Color.black.opacity(0.86))
            .frame(maxWidth: .infinity)
            .frame(height: prominence.height)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(TallyColor.buttonGradient(for: tint))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: TallyColor.tint(for: tint).opacity(0.35), radius: isPressed ? 6 : 18, y: 6)
            .scaleEffect(isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.16), value: isPressed)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.55)
                .onEnded { _ in
                    lastLongPressAt = Date()
                    longPressAction()
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Double tap to log one. Touch and hold to log at an earlier time.")
    }
}

/// The quiet minus beside each button (SPEC §1: undo removes the most recent
/// event of that type today, and no-ops at zero).
struct UndoButton: View {

    let tint: TallyDrinkTint
    let diameter: CGFloat
    let identifier: String
    let accessibilityLabel: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("−")
                .font(.system(size: diameter * 0.42, weight: .medium, design: .rounded))
                .foregroundStyle(isEnabled ? TallyColor.brightTint(for: tint) : TallyColor.inkTertiary)
                .frame(width: diameter, height: diameter)
                .background(
                    Circle().fill(TallyColor.glassStrong)
                )
                .overlay(
                    Circle().stroke(TallyColor.line, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        // Deliberately still hittable at zero: SPEC §1 calls it a no-op, not a
        // disabled control, and a dead button is harder to explain than a
        // button that politely does nothing.
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(accessibilityLabel)
    }
}
