import XCTest

/// The You tab (SPEC §3) — PLAN Gate 2's *"You tab shows"* line of the extended
/// XCUITest suite.
///
/// **Target setup (integrator):** like `TallyUITests`, these files are written
/// but not yet wired — `tallyUITests` still needs a UI-testing bundle target
/// with `TEST_TARGET_NAME = tally`. These tests also assume the You tab hosts
/// `YouScreen` rather than `YouPlaceholderView`; until the integrator swaps the
/// placeholder out in `RootTabView`, they fail by design.
///
/// Same two rules as the Wave 1 suite: never depend on device state (every
/// launch takes a throwaway in-memory store), and never provoke a system dialog
/// (these tests only ever touch the You tab, so no location prompt is spent).
///
/// What is deliberately *not* asserted here: exact point totals. Those are
/// `ScoringEngine`'s contract and are covered by its unit tests; asserting them
/// through the UI would make a scoring-rule change break two suites for one
/// reason. This suite asserts the screen exists, is wired to the log, and moves
/// when the log moves.
final class YouUITests: XCTestCase {

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
    }

    private func launchOnCounter() {
        app.launchArguments = [Arg.inMemoryStore, Arg.skipOnboarding]
        app.launch()
        XCTAssertTrue(
            logDrinkButton.waitForExistence(timeout: 10),
            "The counter should be the first thing after launch (SPEC §9)."
        )
    }

    private func openYouTab() {
        let tab = app.tabBars.buttons["You"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "The shell has a You tab (SPEC §9).")
        tab.tap()
    }

    // MARK: - Elements

    private var logDrinkButton: XCUIElement { app.buttons["tally.logDrinkButton"] }
    private var logNonAlcoholicButton: XCUIElement { app.buttons["tally.logNonAlcoholicButton"] }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Reads a points figure off the hero. The numbers carry their value as the
    /// accessibility *value*; the label is the human description.
    private func points(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> Int {
        let text = element(identifier)
        XCTAssertTrue(text.waitForExistence(timeout: 5), "Missing \(identifier)", file: file, line: line)

        if let value = text.value as? String, let number = Int(value) { return number }
        if let number = Int(text.label) { return number }

        XCTFail(
            "\(identifier) is not a number (value: \(String(describing: text.value)), label: \(text.label))",
            file: file, line: line
        )
        return -1
    }

    /// The hero animates, so poll rather than reading once.
    private func waitForPoints(
        _ identifier: String,
        toEqual expected: Int,
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        var last = points(identifier, file: file, line: line)
        while last != expected, Date() < deadline {
            usleep(150_000)
            last = points(identifier, file: file, line: line)
        }
        XCTAssertEqual(last, expected, "\(identifier) should be \(expected)", file: file, line: line)
    }

    // MARK: - SPEC §3 — the screen renders

    /// Hero, streak ring, and badge case, on an empty store — the You tab must
    /// be a complete screen before anything has ever been logged.
    func testYouTabRendersHeroRingAndBadgeCase() {
        launchOnCounter()
        openYouTab()

        XCTAssertTrue(element("you.screen").waitForExistence(timeout: 5), "The You tab should render.")
        XCTAssertTrue(element("you.hero").waitForExistence(timeout: 5), "SPEC §3: points hero.")
        XCTAssertTrue(element("you.streakRing").waitForExistence(timeout: 5), "SPEC §3: current streak ring.")
        XCTAssertTrue(element("you.badgeCase").waitForExistence(timeout: 5), "SPEC §3: badge case.")
    }

    /// A fresh store scores zero, and says why in a sentence rather than showing
    /// an empty screen.
    func testEmptyStoreShowsZeroPointsAndExplainsSpacers() {
        launchOnCounter()
        openYouTab()

        XCTAssertEqual(points("you.points.allTime"), 0, "A fresh store has no points.")
        XCTAssertTrue(
            element("you.emptyState").waitForExistence(timeout: 5),
            "At zero points the screen should explain how points are earned."
        )
    }

    /// The badge case doubles as the rule book: every badge in the game has a
    /// tile, locked ones included (SPEC §3).
    func testBadgeCaseListsEveryBadgeIncludingLockedOnes() {
        launchOnCounter()
        openYouTab()

        for badge in ["pacer", "designatedLegend", "hydrationWeek", "drySpell3", "drySpell7", "drySpell30"] {
            XCTAssertTrue(
                element("you.badge.\(badge)").waitForExistence(timeout: 5),
                "The badge case should show \(badge), earned or not."
            )
        }
    }

    // MARK: - SPEC §3 — recomputed from the log, live

    /// The whole point of deriving rather than storing: a drink logged on the
    /// Tally tab moves the score on the You tab without a relaunch.
    func testLoggingANonAlcoholicDrinkAddsPointsWithoutRelaunch() {
        launchOnCounter()

        openYouTab()
        XCTAssertEqual(points("you.points.allTime"), 0)

        app.tabBars.buttons["Tally"].tap()
        XCTAssertTrue(logNonAlcoholicButton.waitForExistence(timeout: 5))
        logNonAlcoholicButton.tap()

        openYouTab()
        // SPEC §3: +10 per NA drink. The one point value worth asserting through
        // the UI, because it is the link between a tap and the score.
        waitForPoints("you.points.allTime", toEqual: 10)
    }

    /// The design rule, asserted: an alcoholic drink earns nothing.
    func testLoggingAnAlcoholicDrinkEarnsNoPoints() {
        launchOnCounter()

        logDrinkButton.tap()
        logDrinkButton.tap()

        openYouTab()
        waitForPoints("you.points.allTime", toEqual: 0)
        XCTAssertTrue(
            element("you.emptyState").waitForExistence(timeout: 5),
            "SPEC §3: nothing ever awards points for alcohol, so the score is still zero."
        )
    }

    /// The weekly ratio bar appears once there is something to pace this week.
    func testRatioGoalBarAppearsOnceTheWeekHasDrinks() {
        launchOnCounter()
        openYouTab()

        XCTAssertFalse(
            element("you.ratioGoalBar").exists,
            "With nothing logged this week there is no ratio to show."
        )

        app.tabBars.buttons["Tally"].tap()
        XCTAssertTrue(logDrinkButton.waitForExistence(timeout: 5))
        logDrinkButton.tap()

        openYouTab()
        XCTAssertTrue(
            element("you.ratioGoalBar").waitForExistence(timeout: 5),
            "SPEC §3: this week's ratio goal, once the week has drinks in it."
        )
    }

    // MARK: - Navigation

    /// Leaving and returning must not lose the tab or the numbers.
    func testYouTabSurvivesTabSwitching() {
        launchOnCounter()

        openYouTab()
        XCTAssertTrue(element("you.screen").waitForExistence(timeout: 5))

        app.tabBars.buttons["Tally"].tap()
        XCTAssertTrue(logDrinkButton.waitForExistence(timeout: 5))

        openYouTab()
        XCTAssertTrue(element("you.hero").waitForExistence(timeout: 5))
    }
}
