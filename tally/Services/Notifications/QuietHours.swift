import Foundation

/// The quiet-hours window (SPEC §5, §9), as a value type with no opinions about
/// storage or notifications.
///
/// Stored as minutes from local midnight rather than `Date`s: a window is a
/// property of the clock, not of a day, and minutes survive time-zone changes,
/// DST, and a device crossing the date line without becoming nonsense.
public struct QuietHours: Hashable, Sendable {

    public var isEnabled: Bool
    public var startMinutes: Int
    public var endMinutes: Int

    public init(isEnabled: Bool, startMinutes: Int, endMinutes: Int) {
        self.isEnabled = isEnabled
        self.startMinutes = QuietHours.clamp(startMinutes)
        self.endMinutes = QuietHours.clamp(endMinutes)
    }

    /// SPEC §9 names no default; see `TallyDefaults.Fallback` for why this one is
    /// midnight-to-08:00 rather than the more usual 22:00 start.
    public static let `default` = QuietHours(
        isEnabled: TallyDefaults.Fallback.quietHoursEnabled,
        startMinutes: TallyDefaults.Fallback.quietHoursStartMinutes,
        endMinutes: TallyDefaults.Fallback.quietHoursEndMinutes
    )

    public static func clamp(_ minutes: Int) -> Int {
        min(max(minutes, 0), 24 * 60 - 1)
    }

    /// A window that wraps past midnight — the common case for this app.
    public var wrapsMidnight: Bool { endMinutes <= startMinutes }

    /// Zero-length windows silence nothing, which is the honest reading of
    /// "quiet from 9 to 9".
    public var isEffective: Bool { isEnabled && startMinutes != endMinutes }

    // MARK: - Membership

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard isEffective else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return contains(minuteOfDay: minutes)
    }

    public func contains(minuteOfDay minutes: Int) -> Bool {
        guard isEffective else { return false }
        if wrapsMidnight {
            return minutes >= startMinutes || minutes < endMinutes
        }
        return minutes >= startMinutes && minutes < endMinutes
    }

    // MARK: - Shifting

    /// The moment a notification proposed for `date` should actually be
    /// delivered: `date` itself when it falls outside the window, otherwise the
    /// next end-of-window.
    ///
    /// Deferring rather than dropping is deliberate. A digest computed on Sunday
    /// is still true on Monday morning; silently discarding it would make the
    /// category look broken.
    public func deliveryDate(for date: Date, calendar: Calendar = .current) -> Date {
        guard contains(date, calendar: calendar) else { return date }
        return nextEnd(after: date, calendar: calendar) ?? date
    }

    private func nextEnd(after date: Date, calendar: Calendar = .current) -> Date? {
        let hour = endMinutes / 60
        let minute = endMinutes % 60
        return calendar.nextDate(
            after: date,
            matching: DateComponents(hour: hour, minute: minute),
            matchingPolicy: .nextTime
        )
    }

    // MARK: - Formatting

    public static func formatted(minuteOfDay minutes: Int, calendar: Calendar = .current) -> String {
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        let reference = calendar.date(from: components) ?? Date()
        return reference.formatted(date: .omitted, time: .shortened)
    }

    public var summary: String {
        guard isEffective else { return "Off" }
        return "\(Self.formatted(minuteOfDay: startMinutes)) – \(Self.formatted(minuteOfDay: endMinutes))"
    }

    // MARK: - Date bridging (for SwiftUI's time pickers)

    /// SwiftUI has no minute-of-day picker, so Settings binds `DatePicker`s to
    /// today's date at the stored minute and converts back on write.
    public static func date(fromMinuteOfDay minutes: Int, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .minute, value: clamp(minutes), to: start) ?? start
    }

    public static func minuteOfDay(from date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return clamp((components.hour ?? 0) * 60 + (components.minute ?? 0))
    }
}
