import XCTest

/// The panel's list is the one part of diagnostics a unit test cannot reach: whether a row is
/// tappable is a property of the rendered view hierarchy, not of the state behind it. A selection
/// binding on the list once swallowed these taps and nothing caught it, so this is that test.
final class DiagnosticsPanelUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTappingARequestOpensItsTimeline() {
        let app = XCUIApplication()
        app.launchArguments = ["--autorun"]
        app.launch()

        // `--autorun` runs every scenario and opens the panel, so the first thing to wait for is a
        // row rather than a button.
        let row = app.staticTexts["GET /flaky"]
        XCTAssertTrue(row.waitForExistence(timeout: 60), "the panel never showed the recorded request")

        row.tap()

        let detail = app.navigationBars["GET /flaky"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10), "tapping the request did not open its detail")
        XCTAssertTrue(app.staticTexts["Status"].exists, "the detail is missing its outcome")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "request-detail"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The timeline draws the same snapshot against one clock instead of one row per request.
    func testTheTimelinePutsEveryRequestOnOneClock() {
        let app = XCUIApplication()
        app.launchArguments = ["--autorun"]
        app.launch()

        XCTAssertTrue(app.staticTexts["GET /flaky"].waitForExistence(timeout: 60))

        app.buttons["Timeline"].tap()

        XCTAssertTrue(app.staticTexts["0 ms"].waitForExistence(timeout: 5), "the ruler is missing")
        XCTAssertTrue(app.staticTexts["GET /flaky"].exists, "the retried request has no lane")
        XCTAssertTrue(app.staticTexts["GET /slow"].exists, "the in-flight request has no lane")

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "timeline"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Switching the backend rewrites the paths the scenarios will request. No traffic is produced,
    /// so this stays offline even though the live backend is what it selects.
    func testSwitchingToLiveRewritesTheScenarioPaths() {
        let app = XCUIApplication()
        app.launch()

        // Wait for the screen itself before querying rows: querying during launch returns an empty
        // snapshot and burns the whole timeout on it.
        XCTAssertTrue(app.staticTexts["Nova Diagnostics"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["/flaky"].waitForExistence(timeout: 10))

        app.buttons["Live"].tap()

        // A List renders lazily, so only rows above the fold are in the accessibility snapshot and
        // which ones those are depends on the device. The first row is enough: the paths either got
        // rewritten or they did not.
        XCTAssertTrue(
            app.staticTexts["/status/200,503"].waitForExistence(timeout: 5),
            "the scenario rows still point at the scripted paths"
        )
        XCTAssertFalse(app.staticTexts["/flaky"].exists, "a scripted path survived the switch")
    }

    func testTheListSummarisesEveryScenario() {
        let app = XCUIApplication()
        app.launchArguments = ["--autorun"]
        app.launch()

        XCTAssertTrue(app.staticTexts["GET /flaky"].waitForExistence(timeout: 60))
        for title in ["GET /slow", "POST /orders", "GET /settings", "GET /profile"] {
            XCTAssertTrue(app.staticTexts[title].exists, "\(title) is missing from the panel")
        }

        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "request-list"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
