import AppIntents
import Foundation
import SwiftData

#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - AppEnum conformance

extension DrinkType: AppEnum {

    public static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Drink Type")
    }

    public static var caseDisplayRepresentations: [DrinkType: DisplayRepresentation] {
        [
            .alcoholic: DisplayRepresentation(title: "Alcoholic", subtitle: "Beer, wine, spirits"),
            .nonAlcoholic: DisplayRepresentation(title: "Non-alcoholic", subtitle: "Water, soda, NA beer")
        ]
    }
}

// MARK: - Errors

public enum TallyIntentError: Error, CustomLocalizedStringResourceConvertible {
    case storeUnavailable

    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .storeUnavailable: "Tally couldn't open its store."
        }
    }
}

// MARK: - LogDrinkIntent

/// The one-tap log, shared by the app, the widget, and the watch (SPEC §1, §6, §7).
///
/// Deliberately does *not* wait on a location fix: SPEC §6 is explicit that the
/// count must never wait on GPS. Widget- and watch-originated events land with
/// `source` set accordingly and no coordinates, and the app offers venue
/// reconciliation on next open.
public struct LogDrinkIntent: AppIntent {

    public static let title: LocalizedStringResource = "Log a Drink"

    public static let description = IntentDescription(
        "Adds one drink to today's tally.",
        categoryName: "Logging"
    )

    // `openAppWhenRun` is left at its `false` default on purpose: logging is the
    // whole point, so a widget or notification tap must never bounce the user
    // into the app (SPEC §2, §6).

    @Parameter(title: "Drink", default: DrinkType.alcoholic)
    public var drink: DrinkType

    public init() {}

    public init(drink: DrinkType) {
        self.init()
        self.drink = drink
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let container: ModelContainer
        do {
            container = try TallyRuntime.container()
        } catch {
            throw TallyIntentError.storeUnavailable
        }

        let context = ModelContext(container)
        try EventStore.logDrink(
            type: drink,
            timestamp: Date(),
            source: TallyRuntime.eventSource,
            in: context
        )

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif

        let dialog: IntentDialog = drink == .alcoholic
            ? "Logged a drink."
            : "Logged a non-alcoholic drink."
        return .result(dialog: dialog)
    }
}

// MARK: - Today's counts

/// Small read helper the widget and watch complications share, so "today's
/// counts" means the same thing everywhere (SPEC §6, §7).
public struct TodayCounts: Hashable, Sendable {

    public let alcoholic: Int
    public let nonAlcoholic: Int

    public init(alcoholic: Int = 0, nonAlcoholic: Int = 0) {
        self.alcoholic = alcoholic
        self.nonAlcoholic = nonAlcoholic
    }

    public static let zero = TodayCounts()

    public static func load(
        on date: Date = Date(),
        calendar: Calendar = .current,
        in context: ModelContext
    ) throws -> TodayCounts {
        let events = try EventStore.events(onDayContaining: date, calendar: calendar, in: context)
        return TodayCounts(
            alcoholic: events.reduce(into: 0) { $0 += ($1.type == .alcoholic ? 1 : 0) },
            nonAlcoholic: events.reduce(into: 0) { $0 += ($1.type == .nonAlcoholic ? 1 : 0) }
        )
    }
}
