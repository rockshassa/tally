import XCTest

/// PLAN Gate 2, the Trends half: *"Trends renders without crashing on an empty
/// store, a single event, and a 90-day fixture"*, and the XCUITest extension
/// *"Trends renders"*.
///
/// **Target setup (integrator):** as with `TallyUITests`, this file is written
/// but not yet wired — `tallyUITests` still needs its UI-testing bundle target
/// in `tally.xcodeproj` (`TEST_TARGET_NAME = tally`). Wave 2 agents may not
/// touch `project.pbxproj`, so that stays the integrator's one-time step.
///
/// The same two rules as the Wave 1 suite hold here:
/// * **never depend on device state** — every launch takes a throwaway
///   in-memory store through `LaunchArguments`;
/// * **never provoke a system dialog** — nothing in this file touches location,
///   notifications, or Health.
///
/// A third rule is specific to Trends: **assert that a section exists, never
/// what a bar is worth.** Chart geometry is not addressable from XCUITest, and
/// a test that pinned pixel values would fail the first time the palette moved.
/// The numbers are the unit suite's job; this file is about the screen coming up
/// with every section on it.
final class TrendsUITests: XCTestCase {

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

    private func launch() {
        app.launchArguments = [Arg.inMemoryStore, Arg.skipOnboarding]
        app.launch()
        XCTAssertTrue(
            logDrinkButton.waitForExistence(timeout: 10),
            "The counter should be the first thing after launch (SPEC §9)."
        )
    }

    private func openTrends() {
        app.tabBars.buttons["Trends"].tap()
        XCTAssertTrue(
            element(Id.screen).waitForExistence(timeout: 10),
            "The Trends tab should show the Trends screen (SPEC §4)."
        )
    }

    // MARK: - Elements

    private enum Id {
        static let screen = "trends.screen"
        static let empty = "trends.empty"
        static let insightsSlot = "trends.insightsSlot"

        static let granularityPicker = "trends.granularityPicker"
        static let day = "trends.granularity.day"
        static let week = "trends.granularity.week"
        static let month = "trends.granularity.month"

        static let drinksChart = "trends.drinksChart"
        static let statTiles = "trends.statTiles"
        static let ratioChart = "trends.ratioChart"
        static let venueChart = "trends.venueChart"
        static let heatmap = "trends.heatmap"
        static let sessionStats = "trends.sessionStats"
    }

    private var logDrinkButton: XCUIElement { app.buttons["tally.logDrinkButton"] }
    private var logNonAlcoholicButton: XCUIElement { app.buttons["tally.logNonAlcoholicButton"] }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Scrolls the Trends tab until `identifier` is on screen, or gives up.
    @discardableResult
    private func scrollTo(_ identifier: String, attempts: Int = 8) -> Bool {
        let target = element(identifier)
        var remaining = attempts
        while remaining > 0 {
            if target.exists, target.isHittable { return true }
            app.swipeUp()
            remaining -= 1
        }
        return target.exists
    }

    private func assertVisible(
        _ identifier: String,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        scrollTo(identifier)
        XCTAssertTrue(element(identifier).exists, message, file: file, line: line)
    }

    // MARK: - SPEC §4 — the empty store

    /// PLAN Gate 2's first case: nothing logged at all.
    func testTrendsRendersOnAnEmptyStore() {
        launch()
        openTrends()

        XCTAssertTrue(
            element(Id.empty).waitForExistence(timeout: 5),
            "An empty log should say so rather than draw axes over nothing."
        )
        XCTAssertTrue(
            element(Id.granularityPicker).exists,
            "The Day/Week/Month control belongs to the screen, not to the data."
        )
    }

    // MARK: - SPEC §4 — one event

    /// PLAN Gate 2's second case: a single logged drink must not produce a
    /// degenerate chart, and every section still has to come up.
    func testTrendsRendersEverySectionAfterOneDrink() {
        launch()
        logDrinkButton.tap()
        openTrends()

        XCTAssertTrue(
            element(Id.drinksChart).waitForExistence(timeout: 5),
            "SPEC §4: the stacked bar chart of drinks per day."
        )
        XCTAssertFalse(
            element(Id.empty).exists,
            "One logged drink is data — the empty state should be gone."
        )

        assertVisible(Id.statTiles, "SPEC §4: this week, 7-day average, streaks, top venue.")
        assertVisible(Id.ratioChart, "SPEC §4: NA : alcoholic over time.")
        assertVisible(Id.venueChart, "SPEC §4: the by-venue breakdown.")
        assertVisible(Id.heatmap, "SPEC §4: the hour by weekday heatmap.")
        assertVisible(Id.sessionStats, "SPEC §4: the Session stats block.")
    }

    // MARK: - SPEC §4 — the segmented control

    func testGranularitySwitchingKeepsTheChartOnScreen() {
        launch()
        logDrinkButton.tap()
        logNonAlcoholicButton.tap()
        openTrends()

        XCTAssertTrue(element(Id.drinksChart).waitForExistence(timeout: 5))

        for option in [Id.week, Id.month, Id.day] {
            let button = element(option)
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing granularity option \(option).")
            button.tap()
            XCTAssertTrue(
                element(Id.drinksChart).waitForExistence(timeout: 5),
                "Re-bucketing must never drop the chart (option \(option))."
            )
        }
    }

    // MARK: - SPEC §4 — the Wave 3 slot

    /// The insights slot is empty until Wave 3 mounts HealthKit cards in it, so
    /// this asserts only that the screen above the charts still comes up — the
    /// day M10 lands, its own tests assert the cards.
    func testInsightsSlotIsMountedAboveTheCharts() {
        launch()
        logDrinkButton.tap()
        openTrends()

        XCTAssertTrue(
            element(Id.screen).exists,
            "The insights slot renders as EmptyView until Wave 3; the screen must not care."
        )
    }

    // MARK: - SPEC §4 — dense data

    /// Logging enough drinks to open several Sessions exercises the deriver,
    /// the venue breakdown's untagged row, and the spacer math in one pass.
    func testTrendsSurvivesRepeatedLogging() {
        launch()

        for _ in 0..<6 {
            logDrinkButton.tap()
            logNonAlcoholicButton.tap()
        }

        openTrends()

        XCTAssertTrue(element(Id.drinksChart).waitForExistence(timeout: 5))
        assertVisible(Id.sessionStats, "A Session with spacers should still produce Session stats.")

        // Back to the counter and in again: reload must not wedge the screen.
        app.tabBars.buttons["Tally"].tap()
        XCTAssertTrue(logDrinkButton.waitForExistence(timeout: 5))
        app.tabBars.buttons["Trends"].tap()
        XCTAssertTrue(element(Id.drinksChart).waitForExistence(timeout: 5))
    }
}
