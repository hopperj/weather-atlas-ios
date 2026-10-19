import XCTest

final class AstronomyUITests: XCTestCase {
  @MainActor func testObservingPageAndExactCoordinatePicker() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    defer { app.terminate() }
    let entry = app.tabBars.buttons["Astronomy"]
    XCTAssertTrue(entry.waitForExistence(timeout: 15))
    let golf = app.tabBars.buttons["Golf"]
    XCTAssertTrue(golf.exists)
    XCTAssertTrue(entry.isHittable)
    XCTAssertLessThan(golf.frame.midX, entry.frame.midX)
    XCTAssertFalse(app.buttons["forecastAstronomy"].exists)
    entry.tap()
    XCTAssertTrue(app.staticTexts["MOONLESS DARKNESS"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.staticTexts["This preview does not assess seeing or transparency."].exists)
    let initial = XCTAttachment(screenshot: app.screenshot())
    initial.name = "Astronomy native preview"
    initial.lifetime = .keepAlways
    add(initial)
    app.buttons["astronomyChooseSite"].tap()
    XCTAssertTrue(app.navigationBars["Observing site"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.otherElements["forecastLocationMap"].waitForExistence(timeout: 10))
    let latitude = app.textFields["Latitude (−90 to 90)"]
    XCTAssertTrue(latitude.exists)
    let picker = XCTAttachment(screenshot: app.screenshot())
    picker.name = "Exact-coordinate observing picker"
    picker.lifetime = .keepAlways
    add(picker)
    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.buttons["astronomyChooseSite"].waitForExistence(timeout: 5))
    for _ in 0..<3 { app.swipeUp() }
    let timeline = XCTAttachment(screenshot: app.screenshot())
    timeline.name = "Native observing timeline and missing-field explanation"
    timeline.lifetime = .keepAlways
    add(timeline)
    app.openSection("Saved")
    XCTAssertTrue(app.navigationBars["Saved places"].waitForExistence(timeout: 5))
    app.openSection("Settings")
    XCTAssertTrue(app.buttons["aboutWeatherAtlas"].waitForExistence(timeout: 5))
    entry.tap()
    XCTAssertTrue(app.buttons["astronomyChooseSite"].waitForExistence(timeout: 5))
  }
}
