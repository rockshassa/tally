import SwiftUI
import TallyKit

/// The medium widget's 7-day sparkline (SPEC §6).
///
/// Drawn with plain `Path`s rather than Swift Charts: at 130×44 points there is
/// no axis, no legend, and no interaction to justify the dependency — just an
/// amber alcoholic series with a soft fill and a thinner aqua NA series over it,
/// so the widget keeps the app's two-hue code instead of collapsing both kinds
/// of drink into one ambiguous line.
struct SparklineView: View {

    let history: [DayTotal]

    /// Head-room so a flat run of equal days doesn't render as a line pinned to
    /// the top edge.
    private var upperBound: Double {
        max(Double(history.map(\.total).max() ?? 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let inset: CGFloat = 3

            ZStack {
                // Alcoholic — amber, filled.
                Path.sparklineArea(
                    values: history.map { Double($0.alcoholic) },
                    upperBound: upperBound,
                    in: size,
                    inset: inset
                )
                .fill(DrinkType.alcoholic.chartTint.opacity(0.18))

                Path.sparkline(
                    values: history.map { Double($0.alcoholic) },
                    upperBound: upperBound,
                    in: size,
                    inset: inset
                )
                .stroke(
                    DrinkType.alcoholic.chartTint,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )

                // Non-alcoholic — aqua, thinner, unfilled.
                Path.sparkline(
                    values: history.map { Double($0.nonAlcoholic) },
                    upperBound: upperBound,
                    in: size,
                    inset: inset
                )
                .stroke(
                    DrinkType.nonAlcoholic.chartTint,
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
                )

                // Today's dot, the mockups' one bright accent.
                if let point = Path.sparklinePoints(
                    values: history.map { Double($0.alcoholic) },
                    upperBound: upperBound,
                    in: size,
                    inset: inset
                ).last {
                    Circle()
                        .fill(DrinkType.alcoholic.tint)
                        .frame(width: 5, height: 5)
                        .position(point)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Last 7 days")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let alcoholic = history.map(\.alcoholic).reduce(0, +)
        let nonAlcoholic = history.map(\.nonAlcoholic).reduce(0, +)
        return "\(alcoholic) alcoholic, \(nonAlcoholic) non-alcoholic over 7 days"
    }
}

// MARK: - Geometry

/// Internal rather than file-private since SPEC §4's modeled suppression curve
/// (`SuppressionMiniCurve`) plots on the same three primitives — one polyline
/// helper for the whole extension, so the two mini-charts cannot drift apart.
extension Path {

    static func sparklinePoints(
        values: [Double],
        upperBound: Double,
        in size: CGSize,
        inset: CGFloat
    ) -> [CGPoint] {
        guard !values.isEmpty, size.width > 0, size.height > 0 else { return [] }
        let usableWidth = max(size.width - inset * 2, 1)
        let usableHeight = max(size.height - inset * 2, 1)
        let step = values.count > 1 ? usableWidth / CGFloat(values.count - 1) : 0

        return values.enumerated().map { index, value in
            let fraction = upperBound > 0 ? min(max(value / upperBound, 0), 1) : 0
            return CGPoint(
                x: inset + step * CGFloat(index),
                y: inset + usableHeight * (1 - CGFloat(fraction))
            )
        }
    }

    static func sparkline(
        values: [Double],
        upperBound: Double,
        in size: CGSize,
        inset: CGFloat
    ) -> Path {
        let points = sparklinePoints(values: values, upperBound: upperBound, in: size, inset: inset)
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }

    static func sparklineArea(
        values: [Double],
        upperBound: Double,
        in size: CGSize,
        inset: CGFloat
    ) -> Path {
        let points = sparklinePoints(values: values, upperBound: upperBound, in: size, inset: inset)
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: size.height))
        path.addLine(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.addLine(to: CGPoint(x: last.x, y: size.height))
        path.closeSubpath()
        return path
    }
}
