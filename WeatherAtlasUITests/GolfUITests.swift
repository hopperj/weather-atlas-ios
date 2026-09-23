import XCTest

final class GolfUITests: XCTestCase {
  @MainActor func testGolfSettingsPinAndDailyCards() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["forecastIssuedAt"].waitForExistence(timeout: 20))
    app.tabBars.buttons["Golf"].tap()
    XCTAssertTrue(app.buttons["golfChooseLocation"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Within your limits"].firstMatch.waitForExistence(timeout: 20))
    XCTAssertFalse(app.staticTexts["Available weather fits"].firstMatch.exists)
    XCTAssertFalse(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Weather fit · limited"))
        .firstMatch.exists)
    XCTAssertFalse(app.otherElements["golfInitialLoading"].exists)
    let before = app.staticTexts["golfCoordinates"].label
    app.buttons["golfLimitsLink"].tap()
    XCTAssertTrue(app.steppers["golfWindLimit"].waitForExistence(timeout: 5))
    app.buttons["Restore suggested limits"].tap()
    let wind = app.steppers["golfWindLimit"]
    wind.buttons["golfWindLimit-Increment"].tap()
    XCTAssertTrue(wind.label.contains("30"))
    app.buttons["saveGolfLimits"].tap()
    app.buttons["golfLimitsLink"].tap()
    XCTAssertTrue(app.steppers["golfWindLimit"].label.contains("30"))
    app.buttons["saveGolfLimits"].tap()
    app.buttons["golfChooseLocation"].tap()
    let map = app.otherElements["forecastLocationMap"]
    XCTAssertTrue(map.waitForExistence(timeout: 10))
    map.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.4)).tap()
    let name = app.textFields["golfSiteName"]
    XCTAssertEqual(name.value as? String, "Golf pin")
    app.buttons["saveGolfPin"].tap()
    XCTAssertNotEqual(app.staticTexts["golfCoordinates"].label, before)
    XCTAssertTrue(app.staticTexts["Within your limits"].firstMatch.waitForExistence(timeout: 10))
    app.buttons["golfChooseTime"].tap()
    XCTAssertTrue(app.buttons["saveGolfSchedule"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Time zone at the course"].exists)
    app.buttons["saveGolfSchedule"].tap()
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Golf daily cards and compact controls"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.buttons["Round details"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Regional rain chance"].firstMatch.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Not provided"].firstMatch.exists)
    XCTAssertFalse(app.staticTexts["Cannot assess"].firstMatch.exists)
    app.tabBars.buttons["Forecast"].tap()
    XCTAssertEqual(app.staticTexts["forecastLocationName"].label, "Halifax")
    app.tabBars.buttons["Settings"].tap()
    app.buttons["golfSettings"].tap()
    XCTAssertTrue(app.steppers["golfWindLimit"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.steppers["golfWindLimit"].label.contains("30"))
  }
}
