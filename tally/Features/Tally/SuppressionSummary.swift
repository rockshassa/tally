import Foundation
import TallyKit

// Every word the suppression surfaces say, and every clock time they say it
// with — pure, view-free, and therefore pinnable by
// `tallyTests/Recovery/SuppressionCardTests.swift` without a host view.
//
// The copy *is* the honesty contract of SPEC §4's recovery layer, so it lives
// in one place where a diff shows up:
//
// * every caption carries the word **modeled** — this is a rendering of
//   published population dose-response, never a measurement;
// * **no percentages, ever**, and no raw model index: the only numbers the
//   chart shows are baseline-relative *display* values
//   (`max(0, raw − baselineThreshold)`), whose zero is the model's own
//   baseline band rather than a biological reading;
// * a time the model produced is approximate — hour-rounded and wearing a
//   tilde — while a time the *user* logged keeps the precision they logged it
//   with;
// * an endpoint the model could not find is said to be missing, never
//   fabricated.

// MARK: - Summary

/// Everything the card, the expanded sheet, and VoiceOver say about one
/// `SuppressionTimeline`.
///
/// Holds the few milestones the copy needs rather than the timeline itself, so
/// a test can state a case — "a returned endpoint on a day that is not today",
/// "history that does not reach back far enough" — directly, instead of
/// searching for an event log that happens to produce it.
struct SuppressionSummary: Equatable {

    // MARK: Parts

    struct Peak: Equatable {

        var date: Date

        /// The baseline-relative value, the same scale the chart plots.
        var display: Double

        /// Set when the curve was pinned at the model's ceiling; `date` is the
        /// first instant of that stretch.
        var plateauEnd: Date?

        init(date: Date, display: Double, plateauEnd: Date? = nil) {
            self.date = date
            self.display = display
            self.plateauEnd = plateauEnd
        }
    }

    /// One of the three compact facts under the chart. They stay readable when
    /// the chart's own annotations collide, which is why they are text and not
    /// just markers.
    struct Fact: Equatable, Identifiable {

        var label: String
        var value: String

        var id: String { label }
    }

    // MARK: Fields

    var now: Date

    /// The episode's first drink — as logged, so this one keeps its recorded
    /// precision.
    var start: Date

    var peak: Peak

    var baselineReturn: SuppressionEndpoint

    var state: SuppressionTimeline.State

    var isComplete: Bool

    /// False when the fetched history may not reach back far enough to prove
    /// `start` really is the episode's first drink.
    var isHistoryComplete: Bool

    init(
        now: Date,
        start: Date,
        peak: Peak,
        baselineReturn: SuppressionEndpoint,
        state: SuppressionTimeline.State,
        isComplete: Bool,
        isHistoryComplete: Bool
    ) {
        self.now = now
        self.start = start
        self.peak = peak
        self.baselineReturn = baselineReturn
        self.state = state
        self.isComplete = isComplete
        self.isHistoryComplete = isHistoryComplete
    }

    init(_ timeline: SuppressionTimeline) {
        self.init(
            now: timeline.now,
            start: timeline.start,
            peak: Peak(
                date: timeline.peak.date,
                display: timeline.peak.display,
                plateauEnd: timeline.peak.plateauEnd
            ),
            baselineReturn: timeline.baselineReturn,
            state: timeline.state,
            isComplete: timeline.isComplete,
            isHistoryComplete: timeline.isHistoryComplete
        )
    }

    // MARK: Fixed copy

    /// Above the chart. Never "your suppression" — the model has no subject.
    static let header = "Modeled fibrinolytic suppression"

    /// The vertical scale. Naming the baseline in the axis is what stops two
    /// episodes of different heights reading as the same magnitude.
    static let yAxisLabel = "Modeled suppression above baseline"

    /// The labelled endpoint where the curve comes to rest.
    static let endpointLabel = "0 · modeled baseline"

    /// Under any chart with a future in it.
    static let forecastFootnote = "Based on logged drinks; assumes no additional drinks"

    /// What zero is, and what it is not.
    static let infoText = """
        Zero on this chart means the model is within its baseline range. \
        It is not a measured biological value.
        """

    /// The honest answer when the crossing walk hit its computation limit.
    /// Never a fabricated time, and never silence that reads as "no return".
    static let unavailableReturn = "Return not modeled"

    // MARK: State

    /// The four words SPEC §4 allows. `riseAhead` is the model's absorption
    /// delay — a flat opening segment that must never read as recovery already
    /// completed.
    var stateText: String {
        switch state {
        case .riseAhead: "Rise ahead"
        case .rising: "Rising"
        case .easing: "Easing"
        case .atBaseline: "At modeled baseline"
        }
    }

    // MARK: The three facts

    func facts(calendar: Calendar = .current, locale: Locale = .current) -> [Fact] {
        [
            firstDrinkFact(calendar: calendar, locale: locale),
            peakFact(calendar: calendar, locale: locale),
            baselineFact(calendar: calendar, locale: locale)
        ]
    }

    /// A logged time, at the precision it was logged with — the one time on the
    /// card the model did not invent.
    ///
    /// The label turns into **Available history** when the fetched log may not
    /// reach back far enough: claiming a first drink we cannot prove is the
    /// same class of lie as a fabricated endpoint.
    private func firstDrinkFact(calendar: Calendar, locale: Locale) -> Fact {
        Fact(
            label: isHistoryComplete ? "First drink" : "Available history",
            value: SuppressionTime.exact(start, relativeTo: now, calendar: calendar, locale: locale)
        )
    }

    /// Past or future — the episode's overall maximum stays on the card either
    /// way, which is the whole point of plotting the episode rather than a
    /// rolling window.
    private func peakFact(calendar: Calendar, locale: Locale) -> Fact {
        Fact(
            label: peak.date <= now ? "Peaked" : "Peak",
            value: SuppressionTime.approximate(peak.date, relativeTo: now, calendar: calendar, locale: locale)
        )
    }

    private func baselineFact(calendar: Calendar, locale: Locale) -> Fact {
        switch baselineReturn {
        case .returned(let date):
            Fact(
                label: "Returned",
                value: SuppressionTime.approximate(date, relativeTo: now, calendar: calendar, locale: locale)
            )
        case .projected(let date):
            Fact(
                label: "Baseline",
                value: SuppressionTime.approximate(date, relativeTo: now, calendar: calendar, locale: locale)
            )
        case .unavailable:
            Fact(label: "Baseline", value: Self.unavailableReturn)
        }
    }

    // MARK: Footnotes

    /// The forecast disclaimer, shown whenever part of the curve is still
    /// ahead of the clock. A finished episode makes no promises, so it carries
    /// none.
    var footnote: String? {
        isComplete ? nil : Self.forecastFootnote
    }

    /// Replaces the Now rule once the episode is over: the clock has left the
    /// plotted range, so "now" has nothing to point at.
    func completionText(calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard isComplete, case .returned(let date) = baselineReturn else { return nil }
        let time = SuppressionTime.approximate(date, relativeTo: now, calendar: calendar, locale: locale)
        return "Returned to modeled baseline \(time)"
    }

    /// A capped peak is an interval, not an instant, and the expanded view says
    /// so rather than marking an arbitrary point inside it.
    func plateauText(calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let end = peak.plateauEnd else { return nil }
        let from = SuppressionTime.approximate(peak.date, relativeTo: now, calendar: calendar, locale: locale)
        let to = SuppressionTime.approximate(end, relativeTo: now, calendar: calendar, locale: locale)
        return "Modeled at its ceiling from \(from) to \(to)"
    }

    // MARK: Readouts

    /// One inspected point in the expanded chart: the display value, and the
    /// instant the finger is on.
    ///
    /// The value is the baseline-relative one — the same number the y-axis is
    /// labelled with — and it is spelled out as "above baseline" so it cannot
    /// be read as a percentage or as a measurement.
    static func readout(
        display: Double,
        at date: Date,
        relativeTo now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let value = Int(display.rounded())
        let time = SuppressionTime.exact(date, relativeTo: now, calendar: calendar, locale: locale)
        return "Modeled \(value) above baseline · \(time)"
    }

    // MARK: VoiceOver

    /// Start, peak, current state, and return — the four things the design
    /// asks VoiceOver to be able to say without touching the chart.
    func voiceOverSummary(calendar: Calendar = .current, locale: Locale = .current) -> String {
        var sentences = [sentence("\(Self.header). \(stateText)")]
        for fact in facts(calendar: calendar, locale: locale) {
            sentences.append(sentence("\(fact.label) \(fact.value)"))
        }
        if let plateau = plateauText(calendar: calendar, locale: locale) {
            sentences.append(sentence(plateau))
        }
        return sentences.joined(separator: " ")
    }

    /// Ends a spoken clause without doubling a full stop that "9:00 p.m." or
    /// "~1 p.m." already brought with it.
    private func sentence(_ text: String) -> String {
        text.hasSuffix(".") ? text : text + "."
    }
}

// MARK: - Time

/// Clock times for the recovery surfaces.
///
/// Two kinds, deliberately spelled differently:
///
/// * `approximate` — anything the *model* produced (peak, return). Rounded to
///   the hour and prefixed with a tilde, because an order-of-magnitude fit to
///   population data cannot support minutes.
/// * `exact` — anything the *user* logged. Kept at the precision it was
///   recorded with.
///
/// Both are day-aware from real calendar relationships (`today`, `tomorrow`,
/// `yesterday`, a weekday, or a weekday and date) rather than from an
/// elapsed-hours threshold, so an episode spanning several days never says
/// "~1 p.m." about a time two days out — and a 23- or 25-hour day across a
/// daylight-saving transition is still one day.
enum SuppressionTime {

    /// Beyond this many days either side, a bare weekday repeats itself, so the
    /// date is spelled out.
    static let weekdayHorizon = 6

    // MARK: Times

    /// *"~2 a.m."*, *"~1 p.m. tomorrow"*, *"~13:00 Saturday"*.
    static func approximate(
        _ date: Date,
        relativeTo now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        // Rounded first: 11:40 p.m. rounds into the next day, and the day word
        // has to describe where the rounded time actually lands.
        let rounded = roundedToHour(date, calendar: calendar)
        return join(
            "~" + clock(rounded, showsMinutes: false, calendar: calendar, locale: locale),
            day: dayWord(for: rounded, relativeTo: now, calendar: calendar, locale: locale)
        )
    }

    /// *"11:05 p.m."*, *"11:05 p.m. yesterday"*, *"23:05 Saturday"*.
    static func exact(
        _ date: Date,
        relativeTo now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        join(
            clock(date, showsMinutes: true, calendar: calendar, locale: locale),
            day: dayWord(for: date, relativeTo: now, calendar: calendar, locale: locale)
        )
    }

    private static func join(_ time: String, day: String?) -> String {
        guard let day else { return time }
        return "\(time) \(day)"
    }

    /// The wall clock, in the reader's own cycle.
    static func clock(
        _ date: Date,
        showsMinutes: Bool,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)

        guard uses12HourClock(locale) else {
            return showsMinutes ? String(format: "%d:%02d", hour, minute) : "\(hour):00"
        }

        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let period = hour < 12 ? "a.m." : "p.m."
        return showsMinutes
            ? String(format: "%d:%02d %@", hour12, minute, period)
            : "\(hour12) \(period)"
    }

    // MARK: Days

    /// `nil` for today; otherwise the shortest unambiguous way to name the day.
    ///
    /// Derived from calendar *days* — `startOfDay` to `startOfDay` — so a
    /// daylight-saving day of 23 or 25 hours is still exactly one day away, and
    /// 1 a.m. tomorrow is "tomorrow" even though it is two hours out.
    static func dayWord(
        for date: Date,
        relativeTo now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String? {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0

        switch days {
        case 0:
            return nil
        case 1:
            return "tomorrow"
        case -1:
            return "yesterday"
        case -weekdayHorizon...weekdayHorizon:
            return format(date, .dateTime.weekday(.wide), calendar: calendar, locale: locale)
        default:
            return format(
                date,
                .dateTime.weekday(.abbreviated).month(.abbreviated).day(),
                calendar: calendar,
                locale: locale
            )
        }
    }

    /// Formats in the *given* calendar's time zone rather than the process's,
    /// so a fixed-zone calendar in a test means what it says.
    private static func format(
        _ date: Date,
        _ style: Date.FormatStyle,
        calendar: Calendar,
        locale: Locale
    ) -> String {
        var style = style
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    // MARK: Rounding

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

    // MARK: X axis

    /// One label on the chart's time axis.
    struct AxisTick: Equatable, Identifiable {

        let date: Date

        /// The hour, or — at a midnight crossing — the day it opens.
        let text: String

        let isDayBoundary: Bool

        var id: Date { date }
    }

    /// Between `minimumTicks` and `maximumTicks` labels spanning `range`, on
    /// wall-clock boundaries, with the day named where the range crosses
    /// midnight.
    static let minimumTicks = 4
    static let maximumTicks = 6

    /// Strides, in hours, that read as round numbers on a clock. A multi-day
    /// episode walks up to whole days rather than labelling 37-hour intervals.
    private static let strides = [1, 2, 3, 4, 6, 8, 12, 24, 48, 72, 96, 168]

    /// The x-axis labels for a plotted range.
    ///
    /// Computed from the range itself — not from a fixed 6-hour stride — because
    /// the episode decides the span: eighteen hours and eight days are both
    /// ordinary, and both need four to six readable labels.
    static func axisTicks(
        in range: ClosedRange<Date>,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [AxisTick] {
        var chosen: [AxisTick] = []
        for stride in strides {
            let candidate = ticks(every: stride, in: range, calendar: calendar, locale: locale)
            // Coarser strides can only drop labels, so an empty one means the
            // previous stride was already as sparse as the range allows.
            if candidate.isEmpty { break }
            chosen = candidate
            if candidate.count <= maximumTicks { break }
        }
        // Only reachable for a range too short to contain one hour boundary,
        // which an episode cannot be: even a single drink spans its own decay.
        return chosen.isEmpty ? endpoints(of: range, calendar: calendar, locale: locale) : chosen
    }

    private static func endpoints(
        of range: ClosedRange<Date>,
        calendar: Calendar,
        locale: Locale
    ) -> [AxisTick] {
        [range.lowerBound, range.upperBound].map {
            AxisTick(
                date: $0,
                text: clock($0, showsMinutes: true, calendar: calendar, locale: locale),
                isDayBoundary: false
            )
        }
    }

    private static func ticks(
        every hours: Int,
        in range: ClosedRange<Date>,
        calendar: Calendar,
        locale: Locale
    ) -> [AxisTick] {
        var dates: [Date] = []
        var day = calendar.startOfDay(for: range.lowerBound)
        let guardRail = calendar.startOfDay(for: range.upperBound)

        while day <= guardRail {
            if hours >= 24 {
                dates.append(day)
            } else {
                for hour in Swift.stride(from: 0, to: 24, by: hours) {
                    // `bySettingHour` skips a wall-clock hour that a spring-forward
                    // deleted instead of inventing one.
                    if let mark = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) {
                        dates.append(mark)
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: max(1, hours / 24), to: day) else { break }
            day = next
        }

        // A spring-forward hour does not exist on the clock, and `bySettingHour`
        // answers with the next one that does — which can collide with the
        // stride's own next mark.
        var seen = Set<Int>()

        return dates
            .filter { range.contains($0) }
            .filter { seen.insert(Int($0.timeIntervalSinceReferenceDate.rounded())).inserted }
            .map { date in
                let isMidnight = calendar.component(.hour, from: date) == 0
                    && calendar.component(.minute, from: date) == 0
                return AxisTick(
                    date: date,
                    text: isMidnight
                        ? format(date, .dateTime.weekday(.abbreviated), calendar: calendar, locale: locale)
                        : clock(date, showsMinutes: false, calendar: calendar, locale: locale),
                    isDayBoundary: isMidnight
                )
            }
    }
}
