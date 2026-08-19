import Foundation
import TallyKit
import UserNotifications

// MARK: - Categories

/// The actionable categories SPEC §2 describes, ready to be handed to
/// `NotificationService.activate(additionalCategories:)`.
///
/// > **On entry:** … fire a local notification: *"Looks like you're at The Anchor
/// > — start a Session?"* with actions:
/// > * **+1 drink** — logs directly from the notification … without launching the
/// >   app.
/// > * **Not drinking tonight** — suppresses all further prompts for this visit.
///
/// The "+1 drink" action deliberately carries **no** `.foreground` option: that
/// is the whole difference between logging a drink and being interrupted by an
/// app launch. iOS runs the app in the background to deliver it, which is where
/// `RadarService.handleAction(_:)` picks it up.
public enum RadarNotificationCategories {

    public static var logDrinkAction: UNNotificationAction {
        UNNotificationAction(
            identifier: RadarIdentifiers.logDrinkAction,
            title: RadarCopy.Action.logDrink,
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "plus.circle")
        )
    }

    public static var notDrinkingAction: UNNotificationAction {
        UNNotificationAction(
            identifier: RadarIdentifiers.notDrinkingAction,
            title: RadarCopy.Action.notDrinking,
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "moon.zzz")
        )
    }

    /// SPEC §2's true-up: "**Looks right** (dismisses)".
    ///
    /// It carries no options and the handler does nothing with it, which is the
    /// design: the alternative to a button that means "yes, that's right" is
    /// reading a swipe-away as agreement, and a swipe-away is what people do to
    /// notifications they have not read.
    public static var looksRightAction: UNNotificationAction {
        UNNotificationAction(
            identifier: RadarIdentifiers.looksRightAction,
            title: RadarCopy.Action.looksRight,
            options: [],
            icon: UNNotificationActionIcon(systemImageName: "checkmark.circle")
        )
    }

    /// SPEC §2: "**'Not a bar / don't ask here'** is a first-class action on
    /// discovery prompts — it writes a `SuppressedPlace` … and that spot goes
    /// permanently quiet."
    public static var notABarAction: UNNotificationAction {
        UNNotificationAction(
            identifier: RadarIdentifiers.notABarAction,
            title: RadarCopy.Action.notABar,
            options: [.destructive],
            icon: UNNotificationActionIcon(systemImageName: "mappin.slash")
        )
    }

    /// SPEC §2: "Per-venue mute (also offered on the arrival notification after
    /// repeated dismissals)."
    public static var muteVenueAction: UNNotificationAction {
        UNNotificationAction(
            identifier: RadarIdentifiers.muteVenueAction,
            title: RadarCopy.Action.muteVenue,
            options: [.destructive],
            icon: UNNotificationActionIcon(systemImageName: "bell.slash")
        )
    }

    /// `.customDismissAction` on every Bar Radar category: dismissals are the
    /// signal SPEC §2's two suppression rules are built on.
    public static var arrival: UNNotificationCategory {
        UNNotificationCategory(
            identifier: TallyNotificationCategory.barRadarArrival.identifier,
            actions: [logDrinkAction, notDrinkingAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }

    /// The same prompt, once this venue has been waved off enough times to be
    /// worth offering a way out of.
    public static var arrivalWithMute: UNNotificationCategory {
        UNNotificationCategory(
            identifier: RadarIdentifiers.mutableVariant(
                of: TallyNotificationCategory.barRadarArrival.identifier
            ),
            actions: [logDrinkAction, notDrinkingAction, muteVenueAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }

    public static var dwell: UNNotificationCategory {
        UNNotificationCategory(
            identifier: TallyNotificationCategory.barRadarDwell.identifier,
            actions: [logDrinkAction, notDrinkingAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }

    /// SPEC §2's mid-Session reminder: *"Still at The Anchor — anything to add?"*
    /// with a **+1 drink** action.
    ///
    /// The same two buttons as the arrival prompt, and deliberately the same
    /// `logDrinkAction`: "+1 drink" means one thing in this app — log it, tag it
    /// to the venue, do not launch anything — and a second identifier for the
    /// same job would be a second code path to keep honest. "Not drinking
    /// tonight" carries its existing meaning too: the rest of this visit goes
    /// quiet, reminders included.
    public static var sessionReminder: UNNotificationCategory {
        UNNotificationCategory(
            identifier: TallyNotificationCategory.sessionReminder.identifier,
            actions: [logDrinkAction, notDrinkingAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }

    /// `.customDismissAction` is not decoration: SPEC §2's "two plain dismissals
    /// at the same spot auto-suppress it" is unimplementable without being told
    /// about the swipe-away.
    public static var discovery: UNNotificationCategory {
        UNNotificationCategory(
            identifier: TallyNotificationCategory.barRadarDiscovery.identifier,
            actions: [logDrinkAction, notABarAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }

    /// SPEC §2's Session true-up: *"Session at The Anchor ended — 4 drinks, 1
    /// water. Look right?"* with **Looks right** and **+1 drink**.
    ///
    /// The same `logDrinkAction` again, for the same reason the mid-Session
    /// reminder reuses it: "+1 drink" means one thing in this app. What differs
    /// is *when* the drink lands — the true-up's payload carries the Session's
    /// close moment, and `RadarService` stamps the retro-log with that rather
    /// than with the tap (SPEC §2: "timestamped at close").
    ///
    /// No "Not drinking tonight": the Session is over, and there is nothing left
    /// to silence.
    public static var trueUp: UNNotificationCategory {
        UNNotificationCategory(
            identifier: TallyNotificationCategory.sessionTrueUp.identifier,
            actions: [looksRightAction, logDrinkAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }

    public static var all: Set<UNNotificationCategory> {
        [arrival, arrivalWithMute, dwell, discovery, sessionReminder, trueUp]
    }
}

// MARK: - Scheduling seam

/// The slice of `UNUserNotificationCenter` Bar Radar uses.
///
/// Separate from the `nudge` stream's seam on purpose. Bar Radar is the one
/// family of notifications SPEC §5 exempts from quiet hours —
///
/// > Quiet hours apply to every category except the Bar Radar ones — bar hours
/// > *are* quiet hours, and those prompts are the feature.
///
/// — and the cleanest way to guarantee that exemption is to never route these
/// requests through anything that could suppress them. Nothing on this path
/// consults `QuietHours`.
@MainActor
public protocol RadarNotifying: AnyObject {

    /// Whether the system will deliver anything at all right now.
    func canDeliver() async -> Bool

    func deliver(_ request: UNNotificationRequest) async
    func cancel(identifiers: [String])
    func pendingIdentifiers() async -> [String]
}

/// The live implementation.
@MainActor
public final class LiveRadarNotifier: RadarNotifying {

    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func canDeliver() async -> Bool {
        PermissionStatus(await center.notificationSettings().authorizationStatus).isUsable
    }

    public func deliver(_ request: UNNotificationRequest) async {
        // A rejected request must not take the geofence handler down with it —
        // the auto check-in has already happened either way.
        try? await center.add(request)
    }

    public func cancel(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    public func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }
}

/// Fixture notifier: records instead of delivering.
@MainActor
public final class MockRadarNotifier: RadarNotifying {

    public var isAuthorized = true
    public private(set) var delivered: [UNNotificationRequest] = []
    public private(set) var cancelled: [String] = []

    public init() {}

    public func canDeliver() async -> Bool { isAuthorized }

    public func deliver(_ request: UNNotificationRequest) async {
        delivered.removeAll { $0.identifier == request.identifier }
        delivered.append(request)
    }

    public func cancel(identifiers: [String]) {
        cancelled.append(contentsOf: identifiers)
        delivered.removeAll { identifiers.contains($0.identifier) }
    }

    public func pendingIdentifiers() async -> [String] { delivered.map(\.identifier) }

    public func reset() {
        delivered.removeAll()
        cancelled.removeAll()
    }
}

// MARK: - Requests

/// Turns a `RadarPrompt` into the request the system will deliver.
public enum RadarNotificationBuilder {

    /// - Parameter fireDate: `nil` delivers as soon as the system can, which is
    ///   what a geofence entry — and an exit-close true-up — wants. The dwell
    ///   follow-up, the mid-Session reminder, and the timeout-close true-up pass
    ///   their own dates.
    public static func request(for prompt: RadarPrompt, fireDate: Date? = nil, now: Date = Date()) -> UNNotificationRequest {

        let content = UNMutableNotificationContent()

        switch prompt.kind {
        case .arrival:
            content.title = RadarCopy.Arrival.title(prompt.placeName)
            content.body = RadarCopy.Arrival.body
        case .dwell:
            content.title = RadarCopy.Dwell.title(prompt.placeName)
            content.body = RadarCopy.Dwell.body
        case .discovery:
            content.title = RadarCopy.Discovery.title(prompt.placeName)
            content.body = RadarCopy.Discovery.body
        case .sessionReminder:
            content.title = RadarCopy.SessionReminder.title(prompt.placeName)
            content.body = RadarCopy.SessionReminder.body
        case .trueUp:
            content.title = RadarCopy.TrueUp.title(prompt.placeName)
            content.body = RadarCopy.TrueUp.body(
                alcoholic: prompt.trueUp?.alcoholicCount ?? 0,
                nonAlcoholic: prompt.trueUp?.nonAlcoholicCount ?? 0
            )
        }

        content.sound = .default
        content.categoryIdentifier = prompt.notificationCategoryIdentifier
        // One thread per venue keeps a night's prompts collapsed together rather
        // than stacked down the lock screen.
        content.threadIdentifier = prompt.venueID?.uuidString ?? prompt.category.identifier
        content.userInfo = RadarActionPayload(prompt: prompt).userInfo

        var trigger: UNNotificationTrigger?
        if let fireDate {
            let interval = fireDate.timeIntervalSince(now)
            // An interval trigger survives the app being suspended, which a
            // 45-minute follow-up has to.
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, interval), repeats: false)
        }

        return UNNotificationRequest(
            identifier: prompt.requestIdentifier,
            content: content,
            trigger: trigger
        )
    }
}
