import XCTest

final class GolfUITests: XCTestCase {
  @MainActor private func launch(
    reset: Bool = true, accessibilityText: Bool = false, forecastRegion: String = "0123456789abcdef"
  )
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments =
      [
        "-weatherAtlasTestServerURL", "http://localhost:8097",
        "-forecastRegion:http://localhost:8097", forecastRegion,
        "-golfFixtureDirectory",
      ] + (reset ? ["-golfResetSavedRounds"] : [])
      + (accessibilityText
        ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
    app.launch()
    addUIInterruptionMonitor(withDescription: "Location permission") { alert in
      let deny = alert.buttons["Don’t Allow"]
      if deny.exists {
        deny.tap()
        return true
      }
      return false
    }
    if forecastRegion == "sydney-fixture" {
      let title = app.staticTexts["forecastLocationName"]
      XCTAssertTrue(title.waitForExistence(timeout: 15))
      let ready = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "label CONTAINS 'Sydney'"), object: title)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }
    app.tabBars.buttons["Golf"].tap()
    XCTAssertTrue(app.buttons["golfAddRound"].waitForExistence(timeout: 10))
    return app
  }

  @MainActor private func addCourse(_ query: String, named name: String, app: XCUIApplication) {
    app.buttons["golfAddRound"].tap()
    let find = app.buttons["golfChooseCourse"]
    XCTAssertTrue(find.waitForExistence(timeout: 5))
    find.tap()
    let field = app.textFields["golfCourseSearch"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText(query)
    let result = app.buttons["golfCourseResult-\(name)"]
    XCTAssertTrue(result.waitForExistence(timeout: 10))
    result.tap()
    app.buttons["golfUseCourse"].tap()
    let save = app.buttons["golfSaveRound"]
    XCTAssertTrue(save.waitForExistence(timeout: 5))
    XCTAssertTrue(save.isEnabled)
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'America/Halifax'")).firstMatch
        .exists)
    save.tap()
    XCTAssertTrue(app.buttons["golfAddRound"].waitForExistence(timeout: 5))
  }

  @MainActor private func screenshot(_ name: String, app: XCUIApplication) {
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = name
    capture.lifetime = .keepAlways
    add(capture)
  }

  @MainActor func testGolfHasOnlyAddTeeTimeAtAccessibilityTextSizes() {
    let app = launch(accessibilityText: true)
    defer { app.terminate() }
    let add = app.buttons["golfAddRound"]
    XCTAssertFalse(app.buttons["golfFindCourse"].exists)
    XCTAssertFalse(app.buttons["golfDropPin"].exists)
    for _ in 0..<3 where !add.isHittable { app.swipeUp() }
    XCTAssertTrue(add.isHittable)
    screenshot("Single Add tee time action at accessibility text size", app: app)
  }

  @MainActor func testCoursePickerOpensInTheSelectedForecastArea() {
    let app = launch(forecastRegion: "sydney-fixture")
    defer { app.terminate() }
    app.buttons["golfAddRound"].tap()
    let choose = app.buttons["golfChooseCourse"]
    XCTAssertTrue(choose.waitForExistence(timeout: 5))
    choose.tap()
    XCTAssertTrue(app.otherElements["forecastLocationMap"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.textFields["golfCourseSearch"].waitForExistence(timeout: 5))
    screenshot("Golf course picker starts in the Sydney forecast area", app: app)
  }

  @MainActor func testUsualCourseShortcutAndCalendarCloseOnBothSameAndNewDay() throws {
    let avon = "Avon Valley Golf & Country Club"
    let app = launch()
    defer { app.terminate() }
    addCourse("Avon", named: avon, app: app)
    addCourse("Brunello", named: "The Links at Brunello", app: app)
    app.buttons["golfAddRound"].tap()
    let choose = app.buttons["golfChooseCourse"]
    XCTAssertTrue(choose.waitForExistence(timeout: 5))
    let quick = app.buttons["golfQuickCourse-\(avon)"]
    XCTAssertTrue(quick.waitForExistence(timeout: 5))
    XCTAssertGreaterThan(quick.frame.minY, choose.frame.maxY)
    XCTAssertEqual(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'golfQuickCourse-'")).count, 2
    )
    quick.tap()
    XCTAssertEqual(quick.value as? String, "Selected")
    XCTAssertFalse(
      app.textFields["golfCourseSearch"].exists, "A usual course should not open a new search")
    XCTAssertTrue(app.buttons["golfSaveRound"].isEnabled)
    screenshot("Usual courses directly below the course chooser", app: app)

    var clock = Calendar(identifier: .gregorian)
    clock.timeZone = TimeZone(identifier: "America/Halifax")!
    let tomorrow = try XCTUnwrap(clock.date(byAdding: .day, value: 1, to: Date()))
    let originalDay = clock.component(.day, from: tomorrow)
    let dateButton = app.buttons["golfRoundDate"]
    let originalValue = dateButton.value as? String
    for day in [originalDay, originalDay < 28 ? originalDay + 1 : originalDay - 1] {
      dateButton.tap()
      let calendar = app.descendants(matching: .any).matching(identifier: "golfRoundCalendar")
        .firstMatch
      XCTAssertTrue(calendar.waitForExistence(timeout: 5))
      let button = calendar.buttons.matching(
        NSPredicate(format: "label MATCHES %@", ".*\\b\(day)\\b.*")
      ).firstMatch
      XCTAssertTrue(button.waitForExistence(timeout: 5), calendar.debugDescription)
      button.tap()
      let dismissed = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == false"), object: calendar)
      XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }
    XCTAssertNotEqual(dateButton.value as? String, originalValue)
    screenshot("Calendar closes immediately after choosing a day", app: app)
    app.buttons["golfSaveRound"].tap()
    XCTAssertTrue(app.buttons["golfAddRound"].waitForExistence(timeout: 5))
    XCTAssertEqual(
      app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'golfSavedRound-'"))
        .count, 3)
  }

  @MainActor func testMultipleRoundsPersistAndOnlySelectedTeeTimeIsEvaluated() throws {
    let avon = "Avon Valley Golf & Country Club"
    let brunello = "The Links at Brunello"
    let app = launch()
    defer { app.terminate() }
    XCTAssertFalse(app.buttons["golfFindCourse"].exists)
    XCTAssertFalse(app.buttons["golfDropPin"].exists)
    XCTAssertTrue(app.staticTexts["No upcoming tee times"].waitForExistence(timeout: 5))
    addCourse("Avon", named: avon, app: app)
    XCTAssertTrue(app.staticTexts["Good"].firstMatch.waitForExistence(timeout: 15))
    addCourse("Brunello", named: brunello, app: app)
    let saved = app.otherElements.matching(
      NSPredicate(format: "identifier BEGINSWITH 'golfSavedRound-'"))
    XCTAssertEqual(saved.count, 2)
    screenshot("Saved rounds with independent courses and tee times", app: app)
    app.tabBars.buttons["Forecast"].tap()
    app.tabBars.buttons["Golf"].tap()
    XCTAssertEqual(saved.count, 2)
    app.terminate()
    app.launchArguments.removeAll { $0 == "-golfResetSavedRounds" }
    app.launch()
    app.tabBars.buttons["Golf"].tap()
    XCTAssertTrue(app.staticTexts[avon].waitForExistence(timeout: 10))
    XCTAssertEqual(saved.count, 2)
    let views = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'golfViewRound-'"))
    views.firstMatch.tap()
    XCTAssertTrue(app.navigationBars["Round outlook"].waitForExistence(timeout: 5))
    let days = app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'golfDay-'"))
    XCTAssertTrue(days.firstMatch.waitForExistence(timeout: 15))
    XCTAssertEqual(days.count, 1, "One saved tee time must not produce seven daily cards")
    XCTAssertTrue(app.staticTexts["Regional rain chance"].firstMatch.exists)
    XCTAssertTrue(app.staticTexts["Not provided"].firstMatch.exists)
    XCTAssertFalse(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS '/100'")).firstMatch.exists)
    screenshot("One round outlook with before, round and after details", app: app)
  }

  @MainActor func testPinRoundCanBeRenamedEditedAndDeletedWithoutChangingOtherRound() throws {
    let app = launch()
    defer { app.terminate() }
    addCourse("Brunello", named: "The Links at Brunello", app: app)
    app.buttons["golfAddRound"].tap()
    let choose = app.buttons["golfChooseCourse"]
    XCTAssertTrue(choose.waitForExistence(timeout: 5))
    choose.tap()
    let map = app.otherElements["forecastLocationMap"]
    XCTAssertTrue(map.waitForExistence(timeout: 10))
    map.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.35)).tap()
    XCTAssertTrue(app.buttons["golfUseCourse"].waitForExistence(timeout: 5))
    app.buttons["golfUseCourse"].tap()
    let name = app.textFields["golfPinName"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.tap()
    name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "Practice course")
    app.buttons["golfSaveRound"].tap()
    XCTAssertTrue(app.staticTexts["Practice course"].waitForExistence(timeout: 5))
    let pin = app.otherElements.matching(
      NSPredicate(format: "identifier BEGINSWITH 'golfSavedRound-'")
    ).containing(.staticText, identifier: "Practice course").firstMatch
    pin.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'golfEditRound-'"))
      .firstMatch.tap()
    let delete = app.buttons["golfDeleteRound"]
    for _ in 0..<3 where !delete.isHittable { app.swipeUp() }
    XCTAssertTrue(delete.isHittable)
    delete.tap()
    let confirmation = app.buttons["golfConfirmDeleteRound"].firstMatch
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
    confirmation.tap()
    XCTAssertTrue(app.buttons["golfAddRound"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["The Links at Brunello"].exists)
    XCTAssertFalse(app.staticTexts["Practice course"].exists)
    XCTAssertEqual(
      app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'golfSavedRound-'"))
        .count, 1)
    app.buttons["golfLimitsLink"].tap()
    app.buttons["Restore suggested limits"].tap()
    app.steppers["golfWindLimit"].buttons["golfWindLimit-Increment"].tap()
    app.buttons["saveGolfLimits"].tap()
    app.openSection("Settings")
    app.buttons["golfSettings"].tap()
    XCTAssertTrue(app.steppers["golfWindLimit"].label.contains("30"))
  }
}
