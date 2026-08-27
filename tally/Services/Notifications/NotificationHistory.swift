import Foundation

// MARK: - Category

/// The category a record belongs to.
///
/// A string rather than a bare `TallyNotificationCategory`, because SPEC §5's
/// history has to hold what was *sent*: the Bar Radar family delivers down its
/// own path (`RadarNotifying`) and a future emitter may label something this
/// enum has never heard of. An unknown label has to survive a decode and render
/// as itself rather than take the whole log down with it.
nonisolated public struct NotificationRecordCategory: Hashable, Sendable, Codable {

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ category: TallyNotificationCategory) {
        self.rawValue = category.rawValue
    }

    /// The SPEC §5 category, when this is one of them.
    public var known: TallyNotificationCategory? { TallyNotificationCategory(rawValue: rawValue) }

    /// The badge text the history list draws.
    public var displayName: String { known?.title ?? Self.humanized(rawValue) }

    public var systemImageName: String { known?.systemImageName ?? "bell" }

    /// The Bar Radar family (SPEC §5: the categories quiet hours never touch,
    /// delivered directly rather than scheduled).
    public var isRadarFamily: Bool {
        switch known {
        case .barRadarArrival, .barRadarDwell, .barRadarDiscovery, .sessionReminder, .sessionTrueUp: true
        default: false
        }
    }

    /// `camelCaseLabel` → "Camel case label", for a label with no enum case.
    static func humanized(_ raw: String) -> String {
        var words: [String] = []
        var current = ""
        for character in raw {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(character).lowercased()
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        guard let first = words.first else { return raw }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }

    // Encoded as a plain string: the log is read by future builds, and one
    // string is the shape least likely to need a migration.

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Suppression reasons

/// Why something was deliberately **not** sent.
///
/// > SPEC §5: "…with the suppression reason when something was deliberately
/// > **not** sent (quiet hours, category off, weekly cap, one-per-visit)."
///
/// `other` is the escape hatch, and it carries its own note so a reason nobody
/// anticipated still reads as a sentence in the history rather than as a raw
/// enum case.
nonisolated public enum NotificationSuppressionReason: Hashable, Sendable, Codable {

    /// SPEC §5's window. `until` is when the notification was held *to* — a
    /// postponed delivery — and `nil` when the category's policy is `.drop` and
    /// nothing was sent at all.
    case quietHours(until: Date?)

    case categoryOff
    case weeklyCap
    case onePerVisit
    case cooldown
    case notAuthorized
    case other(note: String)

    /// The stable discriminator, and what the JSON holds.
    public var kind: String {
        switch self {
        case .quietHours: "quietHours"
        case .categoryOff: "categoryOff"
        case .weeklyCap: "weeklyCap"
        case .onePerVisit: "onePerVisit"
        case .cooldown: "cooldown"
        case .notAuthorized: "notAuthorized"
        case .other: "other"
        }
    }

    /// Whether this reason exists *because of* something that already went out.
    ///
    /// Load-bearing: a rate limit must never overwrite the record of the
    /// notification it is rate-limiting — see `NotificationHistory.decision(…)`.
    public var isRateLimit: Bool {
        switch self {
        case .weeklyCap, .onePerVisit, .cooldown, .other: true
        case .quietHours, .categoryOff, .notAuthorized: false
        }
    }

    /// The reason, spelled out, exactly as the history row shows it.
    public var displayText: String {
        switch self {
        case .quietHours(let until):
            if let until {
                return "Quiet hours — held until \(until.formatted(date: .omitted, time: .shortened))"
            }
            return "Quiet hours — not sent"
        case .categoryOff: return "Category off"
        case .weeklyCap: return "Weekly cap reached"
        case .onePerVisit: return "One per visit — already sent"
        case .cooldown: return "Cooldown — one went out recently"
        case .notAuthorized: return "Notifications off at the system level"
        case .other(let note): return note
        }
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case kind
        case until
        case note
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "quietHours": self = .quietHours(until: try container.decodeIfPresent(Date.self, forKey: .until))
        case "categoryOff": self = .categoryOff
        case "weeklyCap": self = .weeklyCap
        case "onePerVisit": self = .onePerVisit
        case "cooldown": self = .cooldown
        case "notAuthorized": self = .notAuthorized
        case "other": self = .other(note: try container.decodeIfPresent(String.self, forKey: .note) ?? "")
        // A reason written by a newer build decodes as itself rather than
        // throwing, which would cost the whole log.
        default: self = .other(note: try container.decodeIfPresent(String.self, forKey: .note) ?? kind)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if case .quietHours(let until) = self { try container.encodeIfPresent(until, forKey: .until) }
        if case .other(let note) = self { try container.encode(note, forKey: .note) }
    }
}

// MARK: - Outcomes

/// What became of one notification.
///
/// > SPEC §5: "…and what the user did with it (ignored, dismissed, an action
/// > tapped, or opened)."
///
/// "Ignored" is the absence of the other three: a notification nobody touches
/// produces no callback of any kind, so it rests at `.scheduled` or `.delivered`
/// forever, which is the honest record of what the app knows.
nonisolated public enum NotificationOutcome: Hashable, Sendable, Codable {

    case scheduled
    case delivered
    case suppressed(NotificationSuppressionReason)
    case actionTaken(identifier: String)
    case opened
    case dismissed

    public var kind: String {
        switch self {
        case .scheduled: "scheduled"
        case .delivered: "delivered"
        case .suppressed: "suppressed"
        case .actionTaken: "actionTaken"
        case .opened: "opened"
        case .dismissed: "dismissed"
        }
    }

    public var suppressionReason: NotificationSuppressionReason? {
        if case .suppressed(let reason) = self { return reason }
        return nil
    }

    public var isSuppression: Bool { suppressionReason != nil }

    /// A decision the app re-makes every time it looks: it can be revised, and
    /// two of them in a row about the same request are one fact, not two.
    public var isStanding: Bool {
        switch self {
        case .scheduled, .suppressed: true
        case .delivered, .actionTaken, .opened, .dismissed: false
        }
    }

    /// Something that actually reached the user.
    public var isInteraction: Bool { !isStanding }

    public var actionIdentifier: String? {
        if case .actionTaken(let identifier) = self { return identifier }
        return nil
    }

    /// The outcome, as the history row shows it.
    public var displayText: String {
        switch self {
        case .scheduled: "Scheduled"
        case .delivered: "Delivered"
        case .suppressed(let reason): reason.displayText
        case .actionTaken(let identifier): "Tapped \(Self.actionLabel(identifier))"
        case .opened: "Opened"
        case .dismissed: "Dismissed"
        }
    }

    /// `tally.radar.action.logDrink` → "log drink".
    ///
    /// Derived rather than looked up: the actions belong to the features that
    /// define them (SPEC §2's "+1 drink", "Not drinking tonight"), and a table
    /// here would be a second place for those titles to live and drift.
    static func actionLabel(_ identifier: String) -> String {
        let tail = identifier.split(separator: ".").last.map(String.init) ?? identifier
        return NotificationRecordCategory.humanized(tail).lowercased()
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
        case action
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "scheduled": self = .scheduled
        case "delivered": self = .delivered
        case "suppressed":
            self = .suppressed(
                try container.decodeIfPresent(NotificationSuppressionReason.self, forKey: .reason)
                    ?? .other(note: "Suppressed")
            )
        case "actionTaken":
            self = .actionTaken(identifier: try container.decodeIfPresent(String.self, forKey: .action) ?? "")
        case "opened": self = .opened
        case "dismissed": self = .dismissed
        default: self = .delivered
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if case .suppressed(let reason) = self { try container.encode(reason, forKey: .reason) }
        if case .actionTaken(let identifier) = self { try container.encode(identifier, forKey: .action) }
    }
}

// MARK: - Record

/// One line of SPEC §5's notification history.
///
/// > Every notification the app schedules or delivers is recorded on-device —
/// > category, title/body as sent, timestamp, venue if any, and what the user
/// > did with it.
///
/// `title`/`body` hold the copy **as sent**, which is why they are captured from
/// the composed `UNNotificationContent` rather than rebuilt for display. The one
/// exception is a suppression decided before anything was composed — a discovery
/// prompt stopped by the weekly cap never had copy — where `title` falls back to
/// the category's own name and `body` is empty.
nonisolated public struct NotificationRecord: Identifiable, Hashable, Sendable, Codable {

    public var id: UUID
    public var category: NotificationRecordCategory

    /// The `UNNotificationRequest` identifier. The key an outcome update matches
    /// on, which is what makes scheduled → delivered → tapped one row.
    public var requestIdentifier: String?

    public var title: String
    public var subtitle: String?
    public var body: String

    /// SPEC §5: "venue if any". The Bar Radar family fills it in; nothing in the
    /// §5 stream has a place attached.
    public var venueName: String?

    public var scheduledAt: Date?
    public var deliveredAt: Date?

    public var outcome: NotificationOutcome

    /// When this row entered the log. The retention key — never revised, so a
    /// record cannot outlive the 30-day window by being touched.
    public var recordedAt: Date

    /// Last time the outcome moved.
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        category: NotificationRecordCategory,
        requestIdentifier: String? = nil,
        title: String,
        subtitle: String? = nil,
        body: String = "",
        venueName: String? = nil,
        scheduledAt: Date? = nil,
        deliveredAt: Date? = nil,
        outcome: NotificationOutcome,
        recordedAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.category = category
        self.requestIdentifier = requestIdentifier
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.venueName = venueName
        self.scheduledAt = scheduledAt
        self.deliveredAt = deliveredAt
        self.outcome = outcome
        self.recordedAt = recordedAt
        self.updatedAt = updatedAt ?? recordedAt
    }

    /// The moment this record is *about*: when it landed, or when it is due, or
    /// failing both, when the decision was made. What the list sorts and groups
    /// on, and the time each row prints.
    public var occurredAt: Date { deliveredAt ?? scheduledAt ?? recordedAt }

    public var isSuppressed: Bool { outcome.isSuppression }
}

// MARK: - Filter

/// SPEC §5's history is "a debugging and calibration surface", and the question
/// it gets asked is usually one of two: what did I get, and what did I not get.
nonisolated public enum NotificationHistoryFilter: String, CaseIterable, Identifiable, Sendable {

    case all
    case delivered
    case suppressed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .delivered: "Delivered"
        case .suppressed: "Suppressed"
        }
    }

    public func matches(_ record: NotificationRecord) -> Bool {
        switch self {
        case .all: true
        case .delivered: !record.isSuppressed
        case .suppressed: record.isSuppressed
        }
    }

    /// What the empty list says under this filter.
    public var emptyMessage: String {
        switch self {
        case .all:
            "Nothing yet. Every notification Tally schedules, delivers, or holds back shows up here."
        case .delivered:
            "Nothing delivered yet."
        case .suppressed:
            "Nothing held back yet. Quiet hours, a category you turned off, or a rate limit would show up here."
        }
    }
}

// MARK: - Day grouping

/// One day of history, newest record first (SPEC §5: "grouped by day").
nonisolated public struct NotificationHistoryDay: Identifiable, Hashable, Sendable {

    /// Start of the local day.
    public let date: Date
    public let records: [NotificationRecord]

    public var id: Date { date }

    public init(date: Date, records: [NotificationRecord]) {
        self.date = date
        self.records = records
    }

    public func title(asOf now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if
            let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

// MARK: - Store

/// SPEC §5's notification history, as an append-only log.
///
/// > **Notification history.** Every notification the app schedules or delivers
/// > is recorded on-device … It is a debugging and calibration surface — the log
/// > is derived from a rolling 30-day store, never synced, and cleared by
/// > erase-all.
///
/// **Where it lives.** One JSON blob under one key in the App Group suite
/// (`TallyDefaults`), for the same reason `RadarStore` is there: a geofence can
/// wake the app in the background hours after it was last used, and a record
/// written by that process has to be the same record the UI reads. Never
/// CloudKit, never a file the exporter walks — SPEC §10's "never synced" is
/// enforced by never putting it anywhere that syncs.
///
/// **Bounded twice.** Records older than `retention` are dropped on every write,
/// and the log is capped at `maxRecords` newest — a debugging surface must not
/// be able to grow without limit on a device that never opens Settings.
///
/// **Isolation.** Deliberately not `@MainActor` and free of UIKit/SwiftUI: the
/// notification-centre delegate is `nonisolated`, and the type has to stay
/// usable from the widget and watch processes that share the App Group. The
/// lock is what buys that.
nonisolated public final class NotificationHistory: @unchecked Sendable {

    /// One log per process. Two would each prune the other's writes away.
    public static let shared = NotificationHistory()

    // MARK: Tunables

    public static let storageKey = TallyDefaults.Keys.notificationHistory

    /// SPEC §5: "a rolling 30-day store".
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// The hard stop. Thirty days of an unusually busy phone is well under this;
    /// the cap exists so a pathological loop cannot fill the App Group.
    public static let maxRecords = 500

    /// How close two deliveries of one request have to be to be the same
    /// delivery, seen twice.
    ///
    /// The Bar Radar path records a prompt as it hands it over, and the
    /// notification-centre delegate records it again from `willPresent` when the
    /// app happens to be open — one banner, two observers, moments apart. Two
    /// deliveries an hour apart are a different matter: SPEC §2 allows a second
    /// mid-Session reminder under the same identifier, and that one is news.
    public static let deliveryEchoWindow: TimeInterval = 90

    // MARK: Storage

    private let read: @Sendable (String) -> Data?
    private let write: @Sendable (Data?, String) -> Void
    private let lock = NSLock()

    /// Defaults to the App Group suite. The closures exist so a test — or a
    /// preview — can drive a log without touching the process's real defaults.
    public init(
        read: @escaping @Sendable (String) -> Data? = { TallyDefaults.object(forKey: $0) as? Data },
        write: @escaping @Sendable (Data?, String) -> Void = { TallyDefaults.set($0, forKey: $1) }
    ) {
        self.read = read
        self.write = write
    }

    /// An in-memory log, for tests and previews.
    public static func ephemeral() -> NotificationHistory {
        let box = Box()
        return NotificationHistory(
            read: { box.value(forKey: $0) },
            write: { data, key in box.set(data, forKey: key) }
        )
    }

    private final class Box: @unchecked Sendable {

        private let lock = NSLock()
        private var values: [String: Data] = [:]

        func value(forKey key: String) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        func set(_ data: Data?, forKey key: String) {
            lock.lock()
            defer { lock.unlock() }
            if let data { values[key] = data } else { values.removeValue(forKey: key) }
        }
    }

    // MARK: - Reads

    /// Everything in the log, oldest first — the stored order.
    public func allRecords() -> [NotificationRecord] {
        lock.lock()
        defer { lock.unlock() }
        return load()
    }

    /// Newest first, filtered.
    public func records(
        matching filter: NotificationHistoryFilter = .all,
        asOf now: Date = Date()
    ) -> [NotificationRecord] {
        Self.pruned(allRecords(), asOf: now)
            .filter(filter.matches)
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    /// SPEC §5's list, ready to draw: reverse-chronological, grouped by day.
    public func groupedByDay(
        matching filter: NotificationHistoryFilter = .all,
        asOf now: Date = Date(),
        calendar: Calendar = .current
    ) -> [NotificationHistoryDay] {
        Self.grouped(records(matching: filter, asOf: now), calendar: calendar)
    }

    /// Whether the log holds anything at all, whatever the current filter says.
    public func isEmpty(asOf now: Date = Date()) -> Bool {
        Self.pruned(allRecords(), asOf: now).isEmpty
    }

    // MARK: - Writes

    /// Appends `record`, or folds it into the row it continues.
    ///
    /// - Returns: the record as it now stands in the log, which is the merged one
    ///   when a merge happened.
    @discardableResult
    public func record(_ record: NotificationRecord, now: Date = Date()) -> NotificationRecord {
        lock.lock()
        defer { lock.unlock() }

        var records = load()
        let result = Self.merging(record, into: &records, now: now)
        save(Self.pruned(records, asOf: now))
        return result
    }

    /// A notification handed to the system with a fire date.
    ///
    /// - Parameter heldByQuietHoursUntil: when quiet hours (SPEC §5) moved the
    ///   delivery, the moment it was moved to. The record then reads as a
    ///   suppression — "held until 09:00" — because that is the question this
    ///   surface exists to answer: not "did it arrive" but "why not when I
    ///   expected it".
    @discardableResult
    public func recordScheduled(
        category: NotificationRecordCategory,
        requestIdentifier: String?,
        title: String,
        subtitle: String? = nil,
        body: String = "",
        venueName: String? = nil,
        scheduledAt: Date,
        heldByQuietHoursUntil: Date? = nil,
        now: Date = Date()
    ) -> NotificationRecord {
        record(
            NotificationRecord(
                category: category,
                requestIdentifier: requestIdentifier,
                title: title,
                subtitle: subtitle,
                body: body,
                venueName: venueName,
                scheduledAt: scheduledAt,
                outcome: heldByQuietHoursUntil.map { .suppressed(.quietHours(until: $0)) } ?? .scheduled,
                recordedAt: now
            ),
            now: now
        )
    }

    /// A notification handed to the system for immediate delivery — the Bar Radar
    /// path (SPEC §2), which has no fire date to wait on.
    @discardableResult
    public func recordDelivered(
        category: NotificationRecordCategory,
        requestIdentifier: String?,
        title: String,
        subtitle: String? = nil,
        body: String = "",
        venueName: String? = nil,
        deliveredAt: Date = Date(),
        now: Date = Date()
    ) -> NotificationRecord {
        record(
            NotificationRecord(
                category: category,
                requestIdentifier: requestIdentifier,
                title: title,
                subtitle: subtitle,
                body: body,
                venueName: venueName,
                deliveredAt: deliveredAt,
                outcome: .delivered,
                recordedAt: now
            ),
            now: now
        )
    }

    /// Something the app decided not to send, and why.
    @discardableResult
    public func recordSuppressed(
        _ reason: NotificationSuppressionReason,
        category: NotificationRecordCategory,
        requestIdentifier: String?,
        title: String,
        subtitle: String? = nil,
        body: String = "",
        venueName: String? = nil,
        now: Date = Date()
    ) -> NotificationRecord {
        record(
            NotificationRecord(
                category: category,
                requestIdentifier: requestIdentifier,
                title: title,
                subtitle: subtitle,
                body: body,
                venueName: venueName,
                outcome: .suppressed(reason),
                recordedAt: now
            ),
            now: now
        )
    }

    /// What the user did with one, from the notification-centre delegate.
    ///
    /// Creates a row when nothing matches `requestIdentifier`: a notification
    /// scheduled by a build that predates this log — or by an emitter that does
    /// not record — is still worth a line the moment it is answered.
    @discardableResult
    public func recordOutcome(
        _ outcome: NotificationOutcome,
        requestIdentifier: String,
        category: NotificationRecordCategory,
        title: String,
        subtitle: String? = nil,
        body: String = "",
        venueName: String? = nil,
        at date: Date = Date(),
        now: Date = Date()
    ) -> NotificationRecord {
        record(
            NotificationRecord(
                category: category,
                requestIdentifier: requestIdentifier,
                title: title,
                subtitle: subtitle,
                body: body,
                venueName: venueName,
                deliveredAt: date,
                outcome: outcome,
                recordedAt: now
            ),
            now: now
        )
    }

    /// SPEC §5/§10: the log is "cleared by erase-all". Also the Clear history row.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        write(nil, Self.storageKey)
    }

    // MARK: - Pure operations

    /// SPEC §5's rolling window, plus the hard cap.
    ///
    /// Retention is measured on `recordedAt` rather than `occurredAt`: a
    /// notification scheduled for next Sunday must not be immune to pruning, and
    /// an outcome landing on an old row must not resurrect it.
    public static func pruned(_ records: [NotificationRecord], asOf now: Date) -> [NotificationRecord] {
        let kept = records.filter { now.timeIntervalSince($0.recordedAt) <= retention }
        guard kept.count > maxRecords else { return kept }
        return Array(kept.suffix(maxRecords))
    }

    /// Reverse-chronological, grouped by local day.
    public static func grouped(
        _ records: [NotificationRecord],
        calendar: Calendar = .current
    ) -> [NotificationHistoryDay] {

        var order: [Date] = []
        var buckets: [Date: [NotificationRecord]] = [:]

        for record in records.sorted(by: { $0.occurredAt > $1.occurredAt }) {
            let day = calendar.startOfDay(for: record.occurredAt)
            if buckets[day] == nil {
                buckets[day] = []
                order.append(day)
            }
            buckets[day]?.append(record)
        }

        return order.map { NotificationHistoryDay(date: $0, records: buckets[$0] ?? []) }
    }

    /// What a new record does to the log.
    public enum MergeDecision: Hashable, Sendable {

        /// A new row.
        case append

        /// The same notification, further along: fold it into the existing row.
        case merge

        /// Nothing worth writing — see `decision(existing:new:)`.
        case skip
    }

    /// The rule that keeps one notification to one row.
    ///
    /// Three things it has to get right, in order of how easy they are to get
    /// wrong:
    ///
    /// 1. **A rate limit never overwrites what it limited.** "One per visit" is
    ///    true *because* a prompt already went out, and writing "not sent" over
    ///    the record of that prompt would make the log lie about the one thing it
    ///    exists to explain.
    /// 2. **Standing decisions collapse.** The digest is rewritten on every
    ///    foreground and the true-up is re-projected on every logged drink; each
    ///    is one fact about one notification, not fifty.
    /// 3. **Interactions advance.** Scheduled → delivered → tapped is one row
    ///    (SPEC §5: "what the user did with it"), so the outcome moves rather
    ///    than duplicating.
    ///
    /// - Parameter interval: how long ago the existing record was last touched.
    ///   Only the delivered-twice case reads it — see `deliveryEchoWindow`.
    public static func decision(
        existing: NotificationOutcome,
        new: NotificationOutcome,
        separatedBy interval: TimeInterval = .greatestFiniteMagnitude
    ) -> MergeDecision {

        if let reason = new.suppressionReason {
            // (1)
            if reason.isRateLimit, !existing.isSuppression { return .skip }
            // (2)
            return existing.isStanding ? .merge : .append
        }

        if new.isStanding { return existing.isStanding ? .merge : .append }

        // Two deliveries are two events — SPEC §2 allows a second mid-Session
        // reminder under the same identifier, and collapsing them would hide it.
        // Unless they are moments apart, in which case they are one delivery
        // that two observers both wrote down.
        if new == .delivered, existing == .delivered {
            return interval <= deliveryEchoWindow ? .merge : .append
        }

        // (3)
        if existing.isStanding || existing == .delivered { return .merge }
        return .append
    }

    /// Applies `decision(existing:new:)` to the log.
    @discardableResult
    static func merging(
        _ new: NotificationRecord,
        into records: inout [NotificationRecord],
        now: Date
    ) -> NotificationRecord {

        guard
            let identifier = new.requestIdentifier,
            let index = records.lastIndex(where: { $0.requestIdentifier == identifier })
        else {
            records.append(new)
            return new
        }

        let separation = abs(new.recordedAt.timeIntervalSince(records[index].updatedAt))

        switch decision(existing: records[index].outcome, new: new.outcome, separatedBy: separation) {
        case .append:
            records.append(new)
            return new

        case .skip:
            return records[index]

        case .merge:
            var merged = records[index]
            merged.outcome = new.outcome
            merged.category = new.category
            // The copy as *sent* wins over the copy as re-derived: an outcome
            // arriving from the delegate carries the content the user saw, and a
            // suppression decided before composition carries none at all.
            if !new.title.isEmpty { merged.title = new.title }
            if !new.body.isEmpty { merged.body = new.body }
            if let subtitle = new.subtitle { merged.subtitle = subtitle }
            if let venueName = new.venueName { merged.venueName = venueName }
            if let scheduledAt = new.scheduledAt { merged.scheduledAt = scheduledAt }
            if let deliveredAt = new.deliveredAt { merged.deliveredAt = deliveredAt }
            merged.updatedAt = now
            records[index] = merged
            return merged
        }
    }

    // MARK: - Coding

    private func load() -> [NotificationRecord] {
        guard let data = read(Self.storageKey) else { return [] }
        return (try? JSONDecoder().decode([NotificationRecord].self, from: data)) ?? []
    }

    private func save(_ records: [NotificationRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        write(data, Self.storageKey)
    }
}
