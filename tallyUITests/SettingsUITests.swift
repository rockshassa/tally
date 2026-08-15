import XCTest

/// PLAN Gate 2: *"§9: every Settings value round-trips (change → kill app →
/// relaunch → persisted)"* and *"XCUITest extended: … Settings toggles flip."*
///
/// **Target setup (integrator):** as with `TallyUITests`, this file is written
/// but not yet compiled — `tallyUITests` still needs a UI-testing bundle target
/// with `TEST_TARGET_NAME = tally`, and Wave 2 agents may not touch
/// `project.pbxproj`.
///
/// **Reaching Settings.** `SettingsScreen` is hosted by the You tab's gear,
/// which the `play` stream draws and the integrator points at this screen. The
/// contract is the accessibility identifier `settings.gearButton`
/// (`SettingsA11y.gearButton`). Until that lands, every test here skips with a
/// message naming the missing step rather than failing — a red suite for an
/// un-wired seam would be noise, not signal.
///
/// Three rules these tests follow:
/// * **Never depend on device state.** Every launch asks for a throwaway
///   in-memory store, and the first launch of a round-trip also asks for factory
///   settings (`-tally-uitest-reset-settings`).
/// * **Never provoke a system dialog.** Nothing here touches the Bar Radar
///   master toggle, the notification status row, or Connect Health — those are
///   exactly the controls that lead to a one-shot iOS prompt.
/// * **Assert the persisted value, not the animation.** A round-trip is only
///   proven by killing the app and reading the control again.
final class SettingsUITests: XCTestCase {

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

    // MARK: - Launch arguments

    private enum Arg {
        static let inMemoryStore = "-tally-uitest-in-memory-store"
        static let skipOnboarding = "-tally-uitest-skip-onboarding"
        /// `TallyDefaults.resetSettingsLaunchArgument`.
        static let resetSettings = "-tally-uitest-reset-settings"
    }

    /// - Parameter resettingSettings: pass `false` on the second launch of a
    ///   round-trip, or the value under test would be wiped before it is read.
    private func launch(resettingSettings: Bool) {
        var arguments = [Arg.inMemoryStore, Arg.skipOnboarding]
        if resettingSettings { arguments.append(Arg.resetSettings) }
        app.launchArguments = arguments
        app.launch()
    }

    // MARK: - Elements

    /// Identifier lookup that does not care which UIKit class SwiftUI chose.
    ///
    /// A `List` row can surface as a cell, a button, or an "other" element
    /// depending on what is inside it, and that choice is not part of the
    /// contract — the identifier is.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private var settingsScreen: XCUIElement { element("settings.screen") }
    private var quietHoursToggle: XCUIElement { app.switches["settings.notifications.quietHoursToggle"] }
    private var digestToggle: XCUIElement { app.switches["settings.notifications.toggle.weeklyDigest"] }
    private var pacingToggle: XCUIElement { app.switches["settings.notifications.toggle.pacingNudge"] }
    private var goalPicker: XCUIElement { app.segmentedControls["settings.goal.picker"] }
    private var venueListRow: XCUIElement { element("settings.venues.listRow") }
    private var suppressedRow: XCUIElement { element("settings.venues.suppressedRow") }
    private var aboutRow: XCUIElement { element("settings.about.row") }
    private var eraseButton: XCUIElement { element("settings.data.eraseButton") }

    /// Opens Settings from the You tab, or skips the test with the reason.
    private func openSettings() throws {
        let youTab = app.tabBars.buttons["You"]
        guard youTab.waitForExistence(timeout: 10) else {
            throw XCTSkip("Tab shell not available.")
        }
        youTab.tap()

        let gear = app.buttons["settings.gearButton"]
        guard gear.waitForExistence(timeout: 5) else {
            throw XCTSkip(
                "No control with identifier \"settings.gearButton\". The You tab's gear must be "
                + "pointed at SettingsScreen and carry SettingsA11y.gearButton."
            )
        }
        gear.tap()

        XCTAssertTrue(
            settingsScreen.waitForExistence(timeout: 5),
            "The gear should present SettingsScreen (SPEC §9: Settings lives on the You tab)."
        )
    }

    private func isOn(_ toggle: XCUIElement) -> Bool {
        (toggle.value as? String) == "1"
    }

    /// Scrolls until an element is hittable — Settings is longer than a phone.
    @discardableResult
    private func reveal(_ element: XCUIElement, maxSwipes: Int = 8) -> Bool {
        var remaining = maxSwipes
        while remaining > 0 {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
            remaining -= 1
        }
        return element.exists && element.isHittable
    }

    // MARK: - Every SPEC §9 group is present

    func testSettingsShowsEverySpecGroup() throws {
        launch(resettingSettings: true)
        try openSettings()

        // §9 Venues, Notifications, Data, About — one probe per group, chosen to
        // be the row a missing section would take with it.
        XCTAssertTrue(reveal(venueListRow), "SPEC §9 Venues: the saved-venue list is missing.")
        XCTAssertTrue(reveal(suppressedRow), "SPEC §9 Venues: the suppressed-places list is missing.")
        XCTAssertTrue(reveal(quietHoursToggle), "SPEC §9 Notifications: the quiet-hours control is missing.")
        XCTAssertTrue(reveal(eraseButton), "SPEC §9 Data: Erase all data is missing.")
        XCTAssertTrue(reveal(aboutRow), "SPEC §9 About: the privacy explainer is missing.")
    }

    // MARK: - Toggles flip and survive a relaunch

    func testNotificationCategoryToggleRoundTrips() throws {
        launch(resettingSettings: true)
        try openSettings()

        XCTAssertTrue(reveal(digestToggle), "SPEC §5's weekly digest needs a toggle (SPEC §9).")
        XCTAssertTrue(isOn(digestToggle), "Categories start on; the primer and authorization are what gate delivery.")

        digestToggle.tap()
        XCTAssertFalse(isOn(digestToggle), "Tapping the toggle should turn the category off.")

        // Kill it. A value that only lives in memory is not a setting.
        app.terminate()
        launch(resettingSettings: false)
        try openSettings()

        XCTAssertTrue(reveal(digestToggle))
        XCTAssertFalse(
            isOn(digestToggle),
            "PLAN Gate 2: every Settings value round-trips — change, kill, relaunch, persisted."
        )
    }

    func testQuietHoursToggleRoundTrips() throws {
        launch(resettingSettings: true)
        try openSettings()

        XCTAssertTrue(reveal(quietHoursToggle))
        XCTAssertTrue(isOn(quietHoursToggle), "Quiet hours ship on (SPEC §5).")

        quietHoursToggle.tap()
        XCTAssertFalse(isOn(quietHoursToggle))

        app.terminate()
        launch(resettingSettings: false)
        try openSettings()

        XCTAssertTrue(reveal(quietHoursToggle))
        XCTAssertFalse(isOn(quietHoursToggle), "The quiet-hours switch must persist across launches.")
    }

    /// Turning quiet hours on reveals the window pickers; off hides them. The
    /// window is meaningless without the switch, so it should not be there.
    func testQuietHoursPickersFollowTheirToggle() throws {
        launch(resettingSettings: true)
        try openSettings()

        XCTAssertTrue(reveal(quietHoursToggle))
        XCTAssertTrue(app.datePickers["settings.notifications.quietHoursStart"].waitForExistence(timeout: 3))

        quietHoursToggle.tap()
        XCTAssertFalse(
            app.datePickers["settings.notifications.quietHoursStart"].exists,
            "With quiet hours off, the window pickers should not be offered."
        )
    }

    // MARK: - Goal (SPEC §3, §9)

    func testRatioGoalRoundTrips() throws {
        launch(resettingSettings: true)
        try openSettings()

        XCTAssertTrue(reveal(goalPicker), "SPEC §9 Goal: the NA-ratio goal needs a control.")

        let twoToOne = goalPicker.buttons["2 : 1"]
        XCTAssertTrue(twoToOne.waitForExistence(timeout: 3))
        twoToOne.tap()
        XCTAssertTrue(twoToOne.isSelected, "Picking 2 : 1 should select it.")

        app.terminate()
        launch(resettingSettings: false)
        try openSettings()

        XCTAssertTrue(reveal(goalPicker))
        XCTAssertTrue(
            goalPicker.buttons["2 : 1"].isSelected,
            "The ratio goal is shared with the You tab and must survive a relaunch."
        )
    }

    // MARK: - Independence

    /// Two categories, two switches: flipping one must not move the other.
    func testCategoryTogglesAreIndependent() throws {
        launch(resettingSettings: true)
        try openSettings()

        XCTAssertTrue(reveal(pacingToggle))
        XCTAssertTrue(isOn(pacingToggle))
        XCTAssertTrue(isOn(digestToggle))

        pacingToggle.tap()

        XCTAssertFalse(isOn(pacingToggle))
        XCTAssertTrue(isOn(digestToggle), "SPEC §5 is opt-in *per category*.")
    }

    // MARK: - Erase all data (SPEC §9)

    /// Destructive and double-confirmed: the first tap must not erase anything,
    /// and cancelling must leave the screen exactly as it was.
    func testEraseAllDataDoubleConfirms() throws {
        launch(resettingSettings: true)
        try openSettings()

        XCTAssertTrue(reveal(eraseButton))
        eraseButton.tap()

        let firstConfirm = app.buttons["settings.data.eraseConfirmButton"]
        XCTAssertTrue(
            firstConfirm.waitForExistence(timeout: 3),
            "Erase must confirm before doing anything (SPEC §9: destructive, double-confirm)."
        )
        firstConfirm.tap()

        let finalConfirm = app.buttons["settings.data.eraseFinalButton"]
        XCTAssertTrue(
            finalConfirm.waitForExistence(timeout: 3),
            "One confirmation is not a double-confirm."
        )

        let cancel = app.buttons["Keep my data"]
        XCTAssertTrue(cancel.exists, "The second confirmation needs a way out.")
        cancel.tap()

        XCTAssertTrue(settingsScreen.waitForExistence(timeout: 3), "Cancelling should return to Settings.")
    }

    // MARK: - Venue management (SPEC §9)

    func testVenueAndSuppressedListsOpen() throws {
        launch(resettingSettings: true)
        try openSettings()

        XCTAssertTrue(reveal(venueListRow))
        venueListRow.tap()
        XCTAssertTrue(
            element("settings.venues.list").waitForExistence(timeout: 5),
            "SPEC §9: the saved-venue list is part of Settings."
        )
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(reveal(suppressedRow))
        suppressedRow.tap()
        XCTAssertTrue(
            element("settings.venues.suppressedList").waitForExistence(timeout: 5),
            "SPEC §9: suppressed places are listed with an un-suppress action."
        )
    }

    // MARK: - About (SPEC §9, §10)

    func testAboutScreenStatesThePrivacyPosture() throws {
        launch(resettingSettings: true)
        try openSettings()

        XCTAssertTrue(reveal(aboutRow))
        aboutRow.tap()

        let about = element("settings.about.screen")
        XCTAssertTrue(about.waitForExistence(timeout: 5))

        XCTAssertTrue(
            app.staticTexts["Nothing leaves your device."].exists,
            "SPEC §9 About: the privacy explainer says what leaves the device — nothing."
        )
        XCTAssertTrue(
            reveal(element("settings.about.guidelinesLink")),
            "SPEC §9 About: the standard-drink guidelines link is required."
        )
    }
}
