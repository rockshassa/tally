import XCTest

/// The suite PLAN Gate 1 names — *"launch → log → undo → History → back"* — and
/// which every later gate re-runs.
///
/// **Target setup (integrator):** these files are written but not yet wired.
/// `tallyUITests` needs a UI-testing bundle target added to `tally.xcodeproj`
/// with `TEST_TARGET_NAME = tally`; Wave 1 agents are not allowed to touch
/// `project.pbxproj`, so the target is the integrator's one-time step. Nothing
/// else here needs changing when it lands.
///
/// Two rules these tests follow, so they stay green in later waves:
/// * **Never depend on device state.** Every launch asks for a throwaway
///   in-memory store and an explicit onboarding state through launch arguments
///   (`LaunchArguments` in the app target).
/// * **Never provoke a system dialog.** The onboarding test always takes the
///   "Not now" path, so the one iOS location prompt is never spent — which is
///   also exactly the SPEC §9 behaviour being asserted.
final class TallyUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() {
        app = nil
        super.tearDown()
    }

    // MARK: - Launch helpers

    private enum Arg {
        static let inMemoryStore = "-tally-uitest-in-memory-store"
        static let skipOnboarding = "-tally-uitest-skip-onboarding"
        static let resetOnboarding = "-tally-uitest-reset-onboarding"
    }

    /// Launches straight onto the counter with an empty store.
    private func launchOnCounter() {
        app.launchArguments = [Arg.inMemoryStore, Arg.skipOnboarding]
        app.launch()
        XCTAssertTrue(
            logDrinkButton.waitForExistence(timeout: 10),
            "The counter should be the first thing after launch (SPEC §9)."
        )
    }

    /// Launches into the first-run flow with an empty store.
    private func launchOnFirstRun() {
        app.launchArguments = [Arg.inMemoryStore, Arg.resetOnboarding]
        app.launch()
    }

    // MARK: - Elements

    private var logDrinkButton: XCUIElement { app.buttons["tally.logDrinkButton"] }
    private var logNonAlcoholicButton: XCUIElement { app.buttons["tally.logNonAlcoholicButton"] }
    private var undoDrinkButton: XCUIElement { app.buttons["tally.undoDrinkButton"] }
    private var undoNonAlcoholicButton: XCUIElement { app.buttons["tally.undoNonAlcoholicButton"] }
    private var todayCountsHeader: XCUIElement { app.buttons["tally.todayCountsHeader"] }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Reads a tally off the screen. The count Texts carry the number as their
    /// accessibility *value*; the label is the human description.
    private func count(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> Int {
        let text = element(identifier)
        XCTAssertTrue(text.waitForExistence(timeout: 5), "Missing count \(identifier)", file: file, line: line)

        if let value = text.value as? String, let number = Int(value) { return number }
        if let number = Int(text.label) { return number }

        XCTFail("Count \(identifier) is not a number (value: \(String(describing: text.value)), label: \(text.label))",
                file: file, line: line)
        return -1
    }

    private var alcoholicCount: Int { count("tally.alcoholicCount") }
    private var nonAlcoholicCount: Int { count("tally.nonAlcoholicCount") }

    /// The counts animate, so assert with a short poll rather than a bare read.
    private func waitForCount(
        _ identifier: String,
        toEqual expected: Int,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = count(identifier, file: file, line: line)
        while last != expected, Date() < deadline {
            usleep(150_000)
            last = count(identifier, file: file, line: line)
        }
        XCTAssertEqual(last, expected, "\(identifier) should be \(expected)", file: file, line: line)
    }

    // MARK: - SPEC §1 — a tap increments

    func testLoggingADrinkIncrementsTheCount() {
        launchOnCounter()

        XCTAssertEqual(alcoholicCount, 0, "A fresh store starts at zero.")

        logDrinkButton.tap()
        waitForCount("tally.alcoholicCount", toEqual: 1)

        logDrinkButton.tap()
        waitForCount("tally.alcoholicCount", toEqual: 2)

        XCTAssertEqual(nonAlcoholicCount, 0, "Alcoholic taps must not touch the NA tally.")
    }

    func testLoggingANonAlcoholicDrinkIncrementsItsOwnCount() {
        launchOnCounter()

        logNonAlcoholicButton.tap()
        waitForCount("tally.nonAlcoholicCount", toEqual: 1)

        XCTAssertEqual(alcoholicCount, 0, "NA taps must not touch the alcoholic tally.")
    }

    /// SPEC §1–2: the live Session card appears once a Session is running.
    func testLoggingShowsTheLiveSessionCard() {
        launchOnCounter()

        logDrinkButton.tap()

        let card = element("tally.sessionCard")
        XCTAssertTrue(card.waitForExistence(timeout: 5), "A logged drink opens a Session, so the card should appear.")
    }

    // MARK: - SPEC §1 — undo

    func testUndoRemovesTheMostRecentDrinkAndNoOpsAtZero() {
        launchOnCounter()

        logDrinkButton.tap()
        logDrinkButton.tap()
        waitForCount("tally.alcoholicCount", toEqual: 2)

        undoDrinkButton.tap()
        waitForCount("tally.alcoholicCount", toEqual: 1)

        undoDrinkButton.tap()
        waitForCount("tally.alcoholicCount", toEqual: 0)

        // "No-op at zero" — the button stays there and politely does nothing.
        undoDrinkButton.tap()
        waitForCount("tally.alcoholicCount", toEqual: 0)
    }

    func testUndoIsPerDrinkType() {
        launchOnCounter()

        logDrinkButton.tap()
        logNonAlcoholicButton.tap()
        waitForCount("tally.alcoholicCount", toEqual: 1)
        waitForCount("tally.nonAlcoholicCount", toEqual: 1)

        undoNonAlcoholicButton.tap()
        waitForCount("tally.nonAlcoholicCount", toEqual: 0)
        XCTAssertEqual(alcoholicCount, 1, "Undoing an NA drink must leave the alcoholic tally alone.")
    }

    // MARK: - SPEC §9 — History lives behind the today count

    func testHistoryOpensFromTheTodayCountAndReturns() {
        launchOnCounter()

        XCTAssertTrue(todayCountsHeader.waitForExistence(timeout: 5))
        todayCountsHeader.tap()

        let history = element("history.screen")
        XCTAssertTrue(history.waitForExistence(timeout: 5), "The today count should push History.")

        // The back button is whatever the pushed screen's navigation bar offers —
        // `place` owns that screen's title, so do not hard-code it.
        let backButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5), "History should be pushed, not presented.")
        backButton.tap()

        XCTAssertTrue(logDrinkButton.waitForExistence(timeout: 5), "Back should land on the counter again.")
    }

    // MARK: - SPEC §1 — retro-log

    func testHoldingAButtonOpensTheRetroLogSheet() {
        launchOnCounter()

        logDrinkButton.press(forDuration: 1.0)

        let confirm = app.buttons["retroLog.confirmButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "A hold should offer logging at an earlier time.")

        // The hold itself must not have logged anything.
        app.buttons["retroLog.cancelButton"].tap()
        waitForCount("tally.alcoholicCount", toEqual: 0)

        logDrinkButton.press(forDuration: 1.0)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        waitForCount("tally.alcoholicCount", toEqual: 1)
    }

    // MARK: - SPEC §9 — first run

    func testFirstRunIsThreeScreensEndingOnTheCounter() {
        launchOnFirstRun()

        let welcomeContinue = app.buttons["onboarding.welcome.continueButton"]
        XCTAssertTrue(welcomeContinue.waitForExistence(timeout: 10), "Screen 1: what Tally is.")
        welcomeContinue.tap()

        // Screen 2: the in-app primer, always ahead of the system dialog.
        let notNow = app.buttons["onboarding.location.notNowButton"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 5), "Screen 2: the location primer, with a Not now.")
        XCTAssertTrue(app.buttons["onboarding.location.grantButton"].exists)
        notNow.tap()

        // Screen 3: the Home-setup slot — the real HomeSetupView since Gate 1,
        // skippable via its "Not now" per SPEC §9.
        let skipHome = app.buttons["homeSetup.skipButton"]
        XCTAssertTrue(skipHome.waitForExistence(timeout: 5), "Screen 3: Set Home, skippable.")
        skipHome.tap()

        XCTAssertTrue(logDrinkButton.waitForExistence(timeout: 5), "First run ends on the counter.")
    }

    func testFirstRunIsSkippableFromTheFirstScreen() {
        launchOnFirstRun()

        let skip = app.buttons["onboarding.skipButton"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "Skip is on every onboarding screen.")
        skip.tap()

        XCTAssertTrue(
            logDrinkButton.waitForExistence(timeout: 5),
            "Skipping goes straight to the counter — it never sits behind a permission wall."
        )
    }

    // MARK: - SPEC §9 — the tab shell

    func testTabShellHasTallyTrendsAndYou() {
        launchOnCounter()

        XCTAssertTrue(app.tabBars.buttons["Trends"].exists)
        XCTAssertTrue(app.tabBars.buttons["You"].exists)

        // Wave 2 replaced the placeholders with the real screens.
        app.tabBars.buttons["Trends"].tap()
        XCTAssertTrue(element("trends.screen").waitForExistence(timeout: 5))

        app.tabBars.buttons["You"].tap()
        XCTAssertTrue(element("you.screen").waitForExistence(timeout: 5))

        app.tabBars.buttons["Tally"].tap()
        XCTAssertTrue(logDrinkButton.waitForExistence(timeout: 5))
    }
}
