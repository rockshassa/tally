import Foundation
import SwiftUI
import TallyKit
import WidgetKit

// The widget's slice of SPEC §4's recovery context: a mini suppression curve
// under the medium family's 7-day sparkline, plus the one line of copy that
// makes it honest.
//
// Since Wave 5 the *shape* is not decided here at all. `SuppressionTimeline`
// (TallyKit) owns episode boundaries, milestones, and the baseline crossing, so
// the widget and the Tally card cannot disagree about them for the same events
// and the same clock — which is exactly what the design asks for. What lives in
// this file is drawing and phrasing: decimation down to something a 150×24-point
// strip can stroke, and the compact copy.
//
// The three rules the app card obeys still hold here:
// * the surface says **"modeled"** — the label above the curve carries it, and
//   VoiceOver hears the full "Modeled fibrinolytic suppression: …" sentence;
// * **amber only**. Never green, and never draining the whole curve to neutral
//   just because the clock has reached baseline: the design is explicit that an
//   episode's earlier progression stays legible;
// * **no number** — the curve is unlabelled and unscaled on purpose.
//
// The copy is duplicated from `tally/Features/Tally/SuppressionCurveCard.swift`
// rather than shared: the widget is a separate target and the shared home
// (`TallyKit`) is deliberately view-free and locale-free. The app-side copy is
// the one under test; this one is kept to the same vocabulary by hand.

// MARK: - Snapshot

/// Everything the widget needs about the modeled curve, computed once in the
/// timeline provider so the view stays a pure drawing.
///
/// A thin wrapper over `SuppressionTimeline`: it adds the decimated sample list
/// and the compact phrasing, and nothing else. Every milestone question — where
/// the episode starts, where it peaks, when it returns — is answered by the
/// timeline, never recomputed here.
struct SuppressionSnapshot: Hashable, Sendable {

    /// The shared timeline this snapshot draws.
    let timeline: SuppressionTimeline

    /// `timeline.samples` thinned for stroking — see `decimated(_:limit:)`.
    let drawSamples: [SuppressionTimeline.Sample]

    /// At widget scale the curve is about 150 points wide, so more than a
    /// couple of samples per point is pure cost. 64 keeps every milestone and
    /// still leaves roughly one vertex every two points.
    static let drawingLimit = 64

    /// Head-room floor, on the display scale, so a single-drink episode rests
    /// in proportion instead of being magnified into a horizon-filling ridge.
    static let minimumScale: Double = 12

    init(timeline: SuppressionTimeline, drawingLimit: Int = SuppressionSnapshot.drawingLimit) {
        self.timeline = timeline
        self.drawSamples = Self.decimated(timeline, limit: drawingLimit)
    }

    // MARK: Derivation

    /// `nil` whenever the shared builder has nothing to show: recovery surfaces
    /// have zero footprint on an empty log, an NA-only log, or once a completed
    /// episode has passed its retention window (SPEC §4).
    ///
    /// - Parameter historyStart: the earliest timestamp the caller actually
    ///   fetched, forwarded so `isHistoryComplete` is honest rather than
    ///   optimistic.
    static func make(
        now: Date,
        events: [DrinkEventSnapshot],
        model: FibrinolysisModel = FibrinolysisModel(),
        historyStart: Date? = nil
    ) -> SuppressionSnapshot? {
        SuppressionTimeline.make(
            now: now,
            events: events,
            model: model,
            historyStart: historyStart
        )
        .map { SuppressionSnapshot(timeline: $0) }
    }

    /// Thins `samples` to at most `limit` points **by dropping**, never by
    /// resampling: every point that survives is a value the model actually
    /// produced, so the stroked curve cannot invent a shape between milestones.
    ///
    /// The anchors the design names — episode start, now, the overall peak (and
    /// the far end of a capped plateau), the baseline crossing, and both ends of
    /// the plotted range — are always kept, whatever the stride works out to.
    /// That is what makes the widget's Now dot sit on the same instant as the
    /// card's, and the tail rest on zero at the same place.
    static func decimated(
        _ timeline: SuppressionTimeline,
        limit: Int = SuppressionSnapshot.drawingLimit
    ) -> [SuppressionTimeline.Sample] {
        let samples = timeline.samples
        guard limit > 0, samples.count > limit else { return samples }

        var anchors = Set<Int>()
        func keep(_ date: Date?) {
            guard let date else { return }
            anchors.insert(secondKey(date))
        }
        keep(timeline.range.lowerBound)
        keep(timeline.range.upperBound)
        keep(timeline.start)
        keep(timeline.peak.date)
        keep(timeline.peak.plateauEnd)
        keep(timeline.nowValue?.date)
        keep(timeline.baselineReturn.date)

        // Widen the stride until the survivors fit. Anchors are few (at most
        // seven), so this settles in one or two passes.
        var stride = max(1, Int((Double(samples.count) / Double(limit)).rounded(.up)))
        while stride < samples.count {
            let kept = samples.indices.filter {
                $0 % stride == 0 || anchors.contains(secondKey(samples[$0].date))
            }
            if kept.count <= limit { return kept.map { samples[$0] } }
            stride += 1
        }
        return samples.indices
            .filter { $0 == 0 || anchors.contains(secondKey(samples[$0].date)) }
            .map { samples[$0] }
    }

    /// Whole-second identity, matching how the timeline de-duplicates its own
    /// plotted instants — an anchor and the grid tick it lands on are one point.
    private static func secondKey(_ date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate.rounded())
    }

    // MARK: Timeline pass-throughs

    var now: Date { timeline.now }
    var range: ClosedRange<Date> { timeline.range }
    var isComplete: Bool { timeline.isComplete }
    var baselineReturn: SuppressionEndpoint { timeline.baselineReturn }

    /// The Now sample to draw, which a completed episode does not have: the
    /// design replaces the rule with the "Returned ~…" caption instead of
    /// leaving a marker standing on a finished curve.
    var activeNow: SuppressionTimeline.Sample? {
        isComplete ? nil : timeline.nowValue
    }

    // MARK: Copy

    /// The state word, in the app card's vocabulary. "Rise ahead" covers the
    /// model's absorption delay, where the curve is flat at zero but a rise is
    /// still coming — the one reading that must never look like a finished
    /// recovery.
    var stateWord: String {
        switch timeline.state {
        case .riseAhead: "Rise ahead"
        case .rising: "Rising"
        case .easing: "Easing"
        case .atBaseline: "At modeled baseline"
        }
    }

    /// One line — *"Easing · baseline ~1 pm"* — because the medium widget's
    /// right-hand column is about 150 points wide.
    ///
    /// A completed episode drops the state word for the design's own phrasing,
    /// *"Returned ~1 pm"*: "At modeled baseline · returned ~1 pm" says the same
    /// thing twice and is the one caption that would not fit.
    func caption(calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch timeline.baselineReturn {
        case .projected(let date):
            let time = SuppressionWidgetTime.approximate(
                date, relativeTo: now, compact: true, calendar: calendar, locale: locale
            )
            return "\(stateWord) · baseline \(time)"
        case .returned(let date):
            let time = SuppressionWidgetTime.approximate(
                date, relativeTo: now, compact: true, calendar: calendar, locale: locale
            )
            return "Returned \(time)"
        case .unavailable:
            // No fabricated endpoint, and no filler either — the state word is
            // the whole of what is known.
            return stateWord
        }
    }

    /// The full sentence — start, peak, state, return — so the honesty rule and
    /// the whole episode survive the trip to VoiceOver, where the one-line
    /// caption's elisions would lose both endpoints.
    func accessibilityLabel(calendar: Calendar = .current, locale: Locale = .current) -> String {
        func approximate(_ date: Date) -> String {
            SuppressionWidgetTime.approximate(
                date, relativeTo: now, compact: false, calendar: calendar, locale: locale
            )
        }

        var parts: [String] = []

        // The design forbids calling a drink "first" when the fetch window
        // cannot prove it was.
        let origin = SuppressionWidgetTime.exact(
            timeline.start, relativeTo: now, calendar: calendar, locale: locale
        )
        parts.append(
            timeline.isHistoryComplete
                ? "first drink \(origin)"
                : "available history from \(origin)"
        )

        let peak = timeline.peak
        parts.append("\(peak.date <= now ? "peaked" : "peak") \(approximate(peak.date))")

        parts.append(stateWord.lowercased())

        switch timeline.baselineReturn {
        case .projected(let date):
            parts.append("baseline \(approximate(date))")
        case .returned(let date):
            parts.append("returned to modeled baseline \(approximate(date))")
        case .unavailable:
            parts.append("return time unavailable")
        }

        return "Modeled fibrinolytic suppression: " + parts.joined(separator: ", ")
    }

    // MARK: Geometry

    /// The top of the plotted scale, on the display (baseline-relative) scale.
    /// Taken from the episode's overall peak, so the curve does not rescale
    /// just because the clock advanced past it.
    var upperBound: Double {
        max(timeline.peak.display, Self.minimumScale)
    }

    /// Where `date` sits across the plotted range, 0…1. Positions are taken
    /// from the *clock*, never from the sample index: the timeline's samples are
    /// deliberately uneven — milestones are inserted between grid ticks — so
    /// index-spacing them would bend the time axis and slide the Now rule off
    /// the Now dot.
    func fraction(of date: Date) -> Double {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        guard span > 0 else { return 0 }
        return min(max(date.timeIntervalSince(range.lowerBound) / span, 0), 1)
    }

    /// Where the now-marker sits across the plotted window, 0…1.
    var nowFraction: Double { fraction(of: now) }

    func point(
        date: Date,
        display: Double,
        in size: CGSize,
        inset: CGFloat
    ) -> CGPoint {
        let usableWidth = max(size.width - inset * 2, 1)
        let usableHeight = max(size.height - inset * 2, 1)
        let height = upperBound > 0 ? min(max(display / upperBound, 0), 1) : 0
        return CGPoint(
            x: inset + usableWidth * fraction(of: date),
            y: inset + usableHeight * (1 - height)
        )
    }

    func points(in size: CGSize, inset: CGFloat) -> [CGPoint] {
        drawSamples.map { point(date: $0.date, display: $0.display, in: size, inset: inset) }
    }
}

// MARK: - Time

/// Approximate clock times, rounded to the hour and tilde-marked because the
/// model is an order-of-magnitude fit, not a measurement — and day-aware,
/// because an episode routinely outlives the day it started on.
///
/// A hand-rolled twin of the app's `SuppressionTime`. Same vocabulary, same
/// rounding, same calendar relationships; the widget target simply cannot see
/// the app's copy, and `TallyKit` is view-free by design.
enum SuppressionWidgetTime {

    /// *"~1 pm"*, *"~1 pm tomorrow"*, *"~13:00 Saturday"*, or — past a week —
    /// *"~1 pm Sat 27 Sep"*.
    ///
    /// - Parameter compact: the widget's 8-point caption drops the periods and
    ///   abbreviates weekday names; the spoken form keeps both in full.
    static func approximate(
        _ date: Date,
        relativeTo now: Date,
        compact: Bool,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let rounded = roundedToHour(date, calendar: calendar)
        let hour = calendar.component(.hour, from: rounded)

        var text: String
        if uses12HourClock(locale) {
            let hour12 = hour % 12 == 0 ? 12 : hour % 12
            let marker = hour < 12 ? (compact ? "am" : "a.m.") : (compact ? "pm" : "p.m.")
            text = "~\(hour12) \(marker)"
        } else {
            text = "~\(hour):00"
        }

        if let day = dayWord(rounded, relativeTo: now, compact: compact, calendar: calendar, locale: locale) {
            text += " \(day)"
        }
        return text
    }

    /// A logged drink keeps its recorded precision — only forecasts are
    /// approximate — but it still needs the day word once an episode spans one.
    static func exact(
        _ date: Date,
        relativeTo now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        var text = date.formatted(
            Date.FormatStyle(
                date: .omitted,
                time: .shortened,
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        )
        if let day = dayWord(date, relativeTo: now, compact: false, calendar: calendar, locale: locale) {
            text += " \(day)"
        }
        return text
    }

    /// The day qualifier, from the actual calendar relationship rather than an
    /// elapsed-hour threshold — "tomorrow" at 23:30 means the next calendar day,
    /// not "more than eighteen hours away". `nil` means today, which the copy
    /// leaves implicit.
    static func dayWord(
        _ date: Date,
        relativeTo now: Date,
        compact: Bool,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        let offset = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0

        var style = Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )

        switch offset {
        case 0:
            return nil
        case 1:
            return "tomorrow"
        case -1:
            return "yesterday"
        case -6...6:
            // Inside a week a weekday name is unambiguous on its own.
            style = style.weekday(compact ? .abbreviated : .wide)
            return date.formatted(style)
        default:
            // Beyond that it is not, so the date comes too.
            style = style.weekday(.abbreviated).day().month(.abbreviated)
            return date.formatted(style)
        }
    }

    /// Rounds through `Calendar` rather than by dividing the epoch, so a
    /// half-hour time zone lands on the wall-clock hour and not on :30.
    static func roundedToHour(_ date: Date, calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.era, .year, .month, .day, .hour, .minute], from: date)
        let minute = components.minute ?? 0
        components.minute = 0
        guard let floored = calendar.date(from: components) else { return date }
        guard minute >= 30 else { return floored }
        return calendar.date(byAdding: .hour, value: 1, to: floored) ?? floored
    }

    static func uses12HourClock(_ locale: Locale = .current) -> Bool {
        // `hourCycle` answers directly. Do *not* pattern-match the "j" skeleton:
        // French resolves to `HH 'h'` — 24-hour, with a quoted "h" literal for
        // "13 h 45" — so any substring test for "h" reports the wrong clock.
        switch locale.hourCycle {
        case .oneToTwelve, .zeroToEleven: true
        case .zeroToTwentyThree, .oneToTwentyFour: false
        @unknown default: false
        }
    }
}

// MARK: - Mini curve

/// The full episode at widget scale — plain `Path`s, exactly like
/// `SparklineView`, for the same reason: at 150×24 points there is no axis, no
/// legend, and nothing to interact with.
///
/// It plots the same range the Tally card does: first drink to modeled return,
/// both endpoints on screen. Time passing moves the Now marker along the curve
/// instead of sliding the beginning of it offscreen.
struct SuppressionMiniCurve: View {

    let snapshot: SuppressionSnapshot

    private static let inset: CGFloat = 2

    private var tint: Color { TallyPalette.amberBright }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let inset = Self.inset
            let points = snapshot.points(in: size, inset: inset)
            let split = splitIndex

            ZStack {
                Self.area(points, in: size)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.34), tint.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // Elapsed time solid, forecast dashed — both modeled, but only
                // one of them has already happened.
                Self.line(points, through: split)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                if let split {
                    Self.line(points, from: split)
                        .stroke(
                            tint.opacity(0.85),
                            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round, dash: [2.5, 2.5])
                        )
                }

                // Now-marker: a dashed hairline plus the one bright dot, so the
                // "hours after the drink" shape reads at a glance. A completed
                // episode has none — the caption says "Returned ~…" instead.
                if let sample = snapshot.activeNow {
                    let marker = snapshot.point(
                        date: sample.date,
                        display: sample.display,
                        in: size,
                        inset: inset
                    )

                    Path { path in
                        path.move(to: CGPoint(x: marker.x, y: 0))
                        path.addLine(to: CGPoint(x: marker.x, y: size.height))
                    }
                    .stroke(
                        TallyPalette.ink3.opacity(0.75),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                    )

                    Circle()
                        .fill(tint)
                        .frame(width: 4, height: 4)
                        .position(marker)
                }
            }
        }
        .accessibilityHidden(true)
    }

    /// Index of the Now sample in `drawSamples`; `nil` when there is no live
    /// Now to split on, in which case the whole curve strokes solid.
    private var splitIndex: Int? {
        guard let sample = snapshot.activeNow else { return nil }
        guard let index = snapshot.drawSamples.firstIndex(where: { $0.date >= sample.date }) else { return nil }
        // Nothing ahead of it means nothing to dash.
        return index < snapshot.drawSamples.count - 1 ? index : nil
    }

    /// Everything up to and including `end` — the whole curve when there is no
    /// split. The dashed half starts *on* the same point, so the two strokes
    /// meet instead of leaving a gap at Now.
    private static func line(_ points: [CGPoint], through end: Int?) -> Path {
        guard let end, end < points.count else { return polyline(points) }
        return polyline(Array(points[...end]))
    }

    private static func line(_ points: [CGPoint], from start: Int) -> Path {
        guard start < points.count else { return Path() }
        return polyline(Array(points[start...]))
    }

    private static func polyline(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }

    private static func area(_ points: [CGPoint], in size: CGSize) -> Path {
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

// MARK: - Column block

/// The label + curve + caption stack the medium widget slots under its
/// sparkline.
struct SuppressionWidgetBlock: View {

    let snapshot: SuppressionSnapshot

    @Environment(\.calendar) private var calendar
    @Environment(\.locale) private var locale

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

            Text(snapshot.caption(calendar: calendar, locale: locale))
                .font(.system(size: 8.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(TallyPalette.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.accessibilityLabel(calendar: calendar, locale: locale))
    }
}

// MARK: - Previews

// The active episode (Now rule, forecast caption) previews from
// `TallyCounterWidget.swift`. This is its counterpart: an episode that finished
// inside its retention window, where the rule disappears and the caption reads
// "Returned ~…" — the one state whose layout the active preview cannot show.

#Preview("Medium · recovery, returned", as: .systemMedium) {
    TallyCounterWidget()
} timeline: {
    TallyWidgetEntry.completedRecoverySample()
}
