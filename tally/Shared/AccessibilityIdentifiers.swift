import Foundation

/// Every accessibility identifier the UI tests drive, in one place.
///
/// The XCUITest suite in `tallyUITests/` is re-run at every wave gate
/// (PLAN Gate 1), so these strings are effectively API: rename one and the
/// suite breaks. Later waves should add cases rather than repurpose them.
enum A11y {

    // MARK: Tab shell

    enum Tab {
        static let tally = "tab.tally"
        static let trends = "tab.trends"
        static let you = "tab.you"
    }

    // MARK: Tally screen (SPEC §1)

    enum Tally {
        static let screen = "tally.screen"

        /// Tappable header — SPEC §9: History lives behind the today count.
        static let todayCountsHeader = "tally.todayCountsHeader"
        static let alcoholicCount = "tally.alcoholicCount"
        static let nonAlcoholicCount = "tally.nonAlcoholicCount"

        static let logDrinkButton = "tally.logDrinkButton"
        static let logNonAlcoholicButton = "tally.logNonAlcoholicButton"
        static let undoDrinkButton = "tally.undoDrinkButton"
        static let undoNonAlcoholicButton = "tally.undoNonAlcoholicButton"

        static let sessionCard = "tally.sessionCard"
    }

    // MARK: Retro-log sheet (SPEC §1)

    enum RetroLog {
        static let sheet = "retroLog.sheet"
        static let datePicker = "retroLog.datePicker"
        static let confirmButton = "retroLog.confirmButton"
        static let cancelButton = "retroLog.cancelButton"
    }

    // MARK: History slot (owned by the `place` agent, hosted here)

    enum History {
        static let screen = "history.screen"
        static let backButton = "history.backButton"
    }

    // MARK: Onboarding (SPEC §9)

    enum Onboarding {
        static let flow = "onboarding.flow"
        static let skipButton = "onboarding.skipButton"

        static let welcomePage = "onboarding.welcome"
        static let welcomeContinueButton = "onboarding.welcome.continueButton"

        /// Primer prefix — the primer builds `\(prefix).grantButton` etc.
        static let locationPrimer = "onboarding.location"
        static let locationGrantButton = "onboarding.location.grantButton"
        static let locationNotNowButton = "onboarding.location.notNowButton"

        static let homeSetupPage = "onboarding.homeSetup"
        static let homeSetupDoneButton = "onboarding.homeSetup.doneButton"
    }

    // MARK: Wave 2 placeholders

    enum Placeholder {
        static let trends = "placeholder.trends"
        static let you = "placeholder.you"
        static let history = "placeholder.history"
        static let homeSetup = "placeholder.homeSetup"
    }
}

/// Suffixes appended by `PermissionPrimer` to its `identifierPrefix`.
enum A11yPrimerSuffix {
    static let root = ".primer"
    static let title = ".title"
    static let grantButton = ".grantButton"
    static let notNowButton = ".notNowButton"
}
