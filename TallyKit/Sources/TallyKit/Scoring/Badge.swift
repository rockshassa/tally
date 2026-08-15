import Foundation

/// Badges from SPEC §3. Derived, never persisted.
///
/// Design rule from SPEC §3 holds throughout: mechanics only ever reward NA
/// drinks and moderation — nothing here awards anything for alcohol.
public enum Badge: String, CaseIterable, Codable, Hashable, Sendable {

    /// Alternated all night: every consecutive pair of alcoholic drinks in a
    /// Session had at least one NA drink between them.
    case pacer

    /// A Session at a bar with zero alcoholic drinks.
    case designatedLegend

    /// A 7-day ratio-goal streak.
    case hydrationWeek

    case drySpell3
    case drySpell7
    case drySpell30

    public var title: String {
        switch self {
        case .pacer: "Pacer"
        case .designatedLegend: "Designated Legend"
        case .hydrationWeek: "Hydration Week"
        case .drySpell3: "Dry Spell · 3"
        case .drySpell7: "Dry Spell · 7"
        case .drySpell30: "Dry Spell · 30"
        }
    }

    public var detail: String {
        switch self {
        case .pacer: "Alternated all night."
        case .designatedLegend: "A whole night out, nothing alcoholic."
        case .hydrationWeek: "Seven days straight hitting your ratio."
        case .drySpell3: "Three dry days in a row."
        case .drySpell7: "Seven dry days in a row."
        case .drySpell30: "Thirty dry days in a row."
        }
    }

    /// SF Symbol suggestion for the badge case on the You tab (SPEC §3).
    public var systemImageName: String {
        switch self {
        case .pacer: "metronome"
        case .designatedLegend: "star.circle"
        case .hydrationWeek: "drop.circle"
        case .drySpell3, .drySpell7, .drySpell30: "sun.max"
        }
    }

    /// Dry-day threshold for the Dry Spell family; `nil` for the others.
    public var dryDayThreshold: Int? {
        switch self {
        case .drySpell3: 3
        case .drySpell7: 7
        case .drySpell30: 30
        default: nil
        }
    }
}

/// A badge plus when it was first earned, and — for Session badges — which
/// Session earned it.
public struct BadgeAward: Identifiable, Hashable, Sendable {

    public let badge: Badge
    public let earnedAt: Date
    public let sessionID: UUID?

    public var id: Badge { badge }

    public init(badge: Badge, earnedAt: Date, sessionID: UUID? = nil) {
        self.badge = badge
        self.earnedAt = earnedAt
        self.sessionID = sessionID
    }

    static func isOrderedBefore(_ lhs: BadgeAward, _ rhs: BadgeAward) -> Bool {
        if lhs.earnedAt != rhs.earnedAt { return lhs.earnedAt < rhs.earnedAt }
        return lhs.badge.rawValue < rhs.badge.rawValue
    }
}
