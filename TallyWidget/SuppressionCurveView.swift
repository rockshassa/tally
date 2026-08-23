import Foundation
import SwiftUI
import TallyKit

// The widget's slice of SPEC §4's recovery context: a mini suppression curve
// under the medium family's 7-day sparkline, plus the one line of copy that
// makes it honest.
//
// The same three rules the app card obeys hold here:
// * the surface says **"modeled"** — the label above the curve carries it, and
//   VoiceOver hears the full "Modeled fibrinolytic suppression: …" sentence;
// * **amber only**, dropping to neutral ink at baseline. Never green;
// * **no number** — the curve is unlabelled and unscaled on purpose.
//
// Everything below is duplicated in spirit (not in code) by
// `tally/Features/Tally/SuppressionCurveCard.swift`. It cannot be shared: the
// widget is a separate target and `TallyKit` — where the shared home would be —
// is frozen. The model itself *is* shared; only the phrasing is copied, and the
// app-side copy is the one under test.

// MARK: - Snapshot

struct SuppressionSample: Hashable, Sendable {
    let date: Date
    let index: Double
}

/// Everything the widget needs about the modeled curve, computed once in the
/// timeline provider so the view stays a pure drawing.
struct SuppressionSnapshot: Hashable, Sendable {

    enum Phase: String, Hashable, Sendable {
        case baseline
        case rising
        case falling
    }

    /// The anchor this snapshot was computed for.
    let now: Date

    /// Oldest first, spanning `lookBack` behind `now` to `lookAhead` ahead.
    let samples: [SuppressionSample]

    let index: Double
    let isAboveBaseline: Bool
    let phase: Phase
    let peakDate: Date?
    let baselineReturn: Date?

    // MARK: Window

    /// Shorter than the app card's: at 24 points tall there is no room for a
    /// full day of shape, and the next half-day is the part that is actionable.
    static let lookBack: TimeInterval = 3 * 3600
    static let lookAhead: TimeInterval = 12 * 3600
    static let step: TimeInterval = 30 * 60

    /// Pulses older than this contribute nothing readable — and trimming keeps
    /// the model from weighing every event in the store against every other.
    static let relevanceWindow: TimeInterval = 60 * 3600
    static let recentIntakeWindow: TimeInterval = 24 * 3600

    private static let risingEpsilon = 0.5

    // MARK: Derivation

    /// `nil` when SPEC §4's zero-footprint rule applies: nothing drunk in the
    /// trailing 24 h and a curve sitting at baseline.
    static func make(
        now: Date,
        events: [DrinkEventSnapshot],
        model: FibrinolysisModel = FibrinolysisModel()
    ) -> SuppressionSnapshot? {
        let cutoff = now.addingTimeInterval(-(lookBack + relevanceWindow))
        let relevant = events.filter { $0.type == .alcoholic && $0.timestamp >= cutoff }

        let index = model.suppressionIndex(at: now, events: relevant)
        let isAboveBaseline = index > model.configuration.baselineThreshold
        let projected = model.projectedPeak(after: now, events: relevant)

        let phase: Phase
        if let projected, projected.date > now, projected.index > index + risingEpsilon {
            phase = .rising
        } else if isAboveBaseline {
            phase = .falling
        } else {
            phase = .baseline
        }

        let intakeCutoff = now.addingTimeInterval(-recentIntakeWindow)
        let hasRecentIntake = relevant.contains { $0.timestamp >= intakeCutoff }
        guard hasRecentIntake || phase != .baseline else { return nil }

        let samples = model.curve(
            from: now.addingTimeInterval(-lookBack),
            to: now.addingTimeInterval(lookAhead),
            step: step,
            events: relevant
        )
        .map { SuppressionSample(date: $0.date, index: $0.index) }

        return SuppressionSnapshot(
            now: now,
            samples: samples,
            index: index,
            isAboveBaseline: isAboveBaseline,
            phase: phase,
            peakDate: phase == .rising ? projected?.date : nil,
            baselineReturn: model.baselineReturn(after: now, events: relevant)
        )
    }

    // MARK: Copy

    /// The level word, matching the app card's vocabulary. "rising" covers the
    /// model's 45-minute absorption delay, where the curve is climbing but the
    /// index has not cleared baseline yet.
    var level: String {
        switch phase {
        case .baseline: "At baseline"
        case .rising: isAboveBaseline ? "Elevated" : "Rising"
        case .falling: "Elevated"
        }
    }

    /// One clause only — *"Elevated · baseline ~1 pm"* — because the medium
    /// widget's right-hand column is about 150 points wide.
    var caption: String {
        var parts = [level]
        if phase == .rising, let peakDate {
            parts.append("peaks \(SuppressionWidgetTime.approximate(peakDate, compact: true))")
        } else if let baselineReturn {
            parts.append("baseline \(SuppressionWidgetTime.approximate(baselineReturn, compact: true))")
        }
        return parts.joined(separator: " · ")
    }

    /// The full sentence, so the honesty rule survives the trip to VoiceOver.
    var accessibilityLabel: String {
        var parts = ["Modeled fibrinolytic suppression: \(level.lowercased())"]
        if phase == .rising, let peakDate {
            parts.append("peaks \(SuppressionWidgetTime.approximate(peakDate, compact: false))")
        }
        if let baselineReturn {
            parts.append("baseline \(SuppressionWidgetTime.approximate(baselineReturn, compact: false))")
        }
        return parts.joined(separator: ", ")
    }

    /// Where the now-marker sits across the plotted window, 0...1.
    var nowFraction: Double {
        guard let first = samples.first?.date, let last = samples.last?.date else { return 0 }
        let span = last.timeIntervalSince(first)
        guard span > 0 else { return 0 }
        return min(max(now.timeIntervalSince(first) / span, 0), 1)
    }
}

// MARK: - Time

/// Approximate clock times, rounded to the hour and tilde-marked because the
/// model is an order-of-magnitude fit, not a measurement.
enum SuppressionWidgetTime {

    /// `compact` drops the periods — *"~1 pm"* — for the widget's 8-point type;
    /// the spoken form keeps them.
    static func approximate(
        _ date: Date,
        compact: Bool,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let rounded = roundedToHour(date, calendar: calendar)
        let hour = calendar.component(.hour, from: rounded)

        guard uses12HourClock(locale) else { return "~\(hour):00" }

        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let marker = hour < 12 ? (compact ? "am" : "a.m.") : (compact ? "pm" : "p.m.")
        return "~\(hour12) \(marker)"
    }

    static func roundedToHour(_ date: Date, calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute], from: date)
        let minute = components.minute ?? 0
        components.minute = 0
        guard let floored = calendar.date(from: components) else { return date }
        guard minute >= 30 else { return floored }
        return calendar.date(byAdding: .hour, value: 1, to: floored) ?? floored
    }

    static func uses12HourClock(_ locale: Locale = .current) -> Bool {
        let template = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? "h"
        return template.contains("h") || template.contains("K")
    }
}

// MARK: - Mini curve

/// The suppression curve at widget scale — plain `Path`s, exactly like
/// `SparklineView`, for the same reason: at 150×24 points there is no axis, no
/// legend, and nothing to interact with.
struct SuppressionMiniCurve: View {

    let snapshot: SuppressionSnapshot

    /// Head-room so a flat baseline run rests on the floor instead of being
    /// magnified into a horizon-filling ridge.
    private var upperBound: Double {
        max(snapshot.samples.map(\.index).max() ?? 0, 12)
    }

    private var tint: Color {
        snapshot.isAboveBaseline ? TallyPalette.amberBright : TallyPalette.ink3
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let inset: CGFloat = 2
            let values = snapshot.samples.map(\.index)

            ZStack {
                Path.sparklineArea(values: values, upperBound: upperBound, in: size, inset: inset)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.34), tint.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                Path.sparkline(values: values, upperBound: upperBound, in: size, inset: inset)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                // Now-marker: a dashed hairline plus the one bright dot, so the
                // "hours after the drink" shape reads at a glance.
                let x = inset + (size.width - inset * 2) * snapshot.nowFraction
                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
                .stroke(
                    TallyPalette.ink3.opacity(0.75),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                )

                if let point = Path.sparklinePoints(
                    values: values,
                    upperBound: upperBound,
                    in: size,
                    inset: inset
                ).nearest(toX: x) {
                    Circle()
                        .fill(tint)
                        .frame(width: 4, height: 4)
                        .position(point)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private extension Array where Element == CGPoint {
    func nearest(toX x: CGFloat) -> CGPoint? {
        self.min { abs($0.x - x) < abs($1.x - x) }
    }
}

// MARK: - Column block

/// The label + curve + caption stack the medium widget slots under its
/// sparkline.
struct SuppressionWidgetBlock: View {

    let snapshot: SuppressionSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Modeled suppression")
                .font(.system(size: 8, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.5)
                .foregroundStyle(TallyPalette.ink3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            SuppressionMiniCurve(snapshot: snapshot)
                .frame(maxWidth: .infinity)
                .frame(height: 24)

            Text(snapshot.caption)
                .font(.system(size: 8.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(TallyPalette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.accessibilityLabel)
    }
}
