import XCTest

final class WeatherAtlasUITests: XCTestCase {
  @MainActor func testAboutExplainsCanadianOriginsFeaturesAndFreeAccessWithoutNetwork() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://127.0.0.1:1",
      "-forecastRegion:http://127.0.0.1:1", "about-offline-test",
    ]
    app.launch()
    defer { app.terminate() }
    app.tabBars.buttons["Settings"].tap()
    let about = app.buttons["aboutWeatherAtlas"]
    XCTAssertTrue(about.waitForExistence(timeout: 5))
    XCTAssertTrue(about.isHittable)
    XCTAssertEqual(about.label, "About Weather Atlas")
    about.tap()
    XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts["aboutWeatherAtlasIntroduction"].label.contains(
        "Environment and Climate Change Canada"))
    XCTAssertTrue(app.staticTexts["aboutWeatherAtlasFeatures"].label.contains("anywhere in Canada"))
    let mission = app.staticTexts["aboutWeatherAtlasMission"]
    XCTAssertEqual(
      mission.label,
      "Built by a Canadian, using Canadian weather data, for Canadians—free of charge.")
    XCTAssertTrue(mission.isHittable)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "About Weather Atlas"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.swipeUp()
    XCTAssertTrue(app.staticTexts["aboutWeatherAtlasVersion"].isHittable)
    app.navigationBars.buttons["Settings"].tap()
    XCTAssertTrue(app.buttons["aboutWeatherAtlas"].waitForExistence(timeout: 5))
  }

  @MainActor func testAboutScrollsAtAccessibilityTextSize() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://127.0.0.1:1",
      "-forecastRegion:http://127.0.0.1:1", "about-offline-test",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    defer { app.terminate() }
    app.tabBars.buttons["Settings"].tap()
    app.buttons["aboutWeatherAtlas"].tap()
    XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
    let version = app.staticTexts["aboutWeatherAtlasVersion"]
    for _ in 0..<12 where !version.isHittable { app.swipeUp() }
    XCTAssertTrue(version.isHittable)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "About at accessibility text size"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor func testFixedProductionHTTPSLoadsWithObsoleteServerPreference() throws {
    guard ProcessInfo.processInfo.environment["WEATHERATLAS_LIVE_HTTPS"] == "1" else {
      throw XCTSkip("Opt-in public endpoint check: TEST_RUNNER_WEATHERATLAS_LIVE_HTTPS=1.")
    }
    let app = XCUIApplication()
    app.launchArguments = [
      "-serverURL", "http://obsolete.invalid:18080",
      "-forecastRegion:https://weatheratlas.ioresearch.ca", "973f9e2654e472e2",
      "-forecastSnapshot:v1:https://weatheratlas.ioresearch.ca:manual", "",
    ]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["forecastIssuedAt"].waitForExistence(timeout: 30))
    XCTAssertEqual(app.staticTexts["forecastLocationName"].label, "Halifax")
    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(app.buttons["defaultForecastLocation"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["serverAddress"].exists)
    XCTAssertFalse(app.buttons["connectServer"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Live HTTPS Settings without server configuration"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor func testSettingsHasNoServerConfigurationAndOldAddressIsIgnored() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-serverURL", "http://obsolete.invalid:18080",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    XCTAssertTrue(app.staticTexts["forecastIssuedAt"].waitForExistence(timeout: 15))
    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(app.buttons["defaultForecastLocation"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["serverAddress"].exists)
    XCTAssertFalse(app.buttons["connectServer"].exists)
    XCTAssertFalse(app.staticTexts["Weather Atlas server"].exists)
    XCTAssertTrue(app.staticTexts["Secure connection to Weather Atlas"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Settings with fixed HTTPS service and no server configuration"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor func testCaptureLiveAppScreenshots1242x2688() async throws {
    #if targetEnvironment(simulator)
      guard ProcessInfo.processInfo.environment["WEATHERATLAS_SCREENSHOTS"] == "1" else {
        throw XCTSkip(
          "Opt-in screenshots: TEST_RUNNER_WEATHERATLAS_SCREENSHOTS=1, iPhone 11 Pro Max.")
      }
      let app = XCUIApplication()
      app.launchArguments = [
        "-weatherAtlasTestServerURL", "https://weatheratlas.ioresearch.ca",
        "-forecastRegion:https://weatheratlas.ioresearch.ca", "973f9e2654e472e2",
      ]
      app.launch()
      defer { app.terminate() }
      XCTAssertTrue(app.staticTexts["forecastIssuedAt"].waitForExistence(timeout: 30))
      XCTAssertEqual(app.staticTexts["forecastLocationName"].label, "Halifax")
      try await Task.sleep(for: .seconds(2))
      captureScreenshot("01-Daily-Forecast", app: app)

      app.segmentedControls["forecastViewPicker"].buttons["Hourly · 72h"].tap()
      XCTAssertTrue(app.staticTexts["hourlyChartTitle"].waitForExistence(timeout: 30))
      XCTAssertEqual(app.staticTexts.matching(identifier: "hourlyForecastTime").count, 72)
      try await Task.sleep(for: .seconds(1))
      captureScreenshot("02-Hourly-Forecast", app: app)

      app.tabBars.buttons["Map"].tap()
      let status = app.staticTexts["mapPlaybackStatus"]
      let ready = expectation(
        for: NSPredicate { _, _ in
          status.exists && status.label.contains("seconds per complete frame")
        },
        evaluatedWith: nil)
      await fulfillment(of: [ready], timeout: 60)
      XCTAssertTrue(app.buttons["mapDataPicker"].label.contains("Temperature"))
      // Allow the base-map labels to finish drawing after the weather frame is ready.
      try await Task.sleep(for: .seconds(3))
      captureScreenshot("03-Weather-Map", app: app)
    #else
      throw XCTSkip("Screenshot capture is simulator-only; never automates a physical phone.")
    #endif
  }

  @MainActor private func captureScreenshot(_ name: String, app: XCUIApplication) {
    let screenshot = app.screenshot()
    XCTAssertEqual(screenshot.image.cgImage?.width, 1242)
    XCTAssertEqual(screenshot.image.cgImage?.height, 2688)
    XCTAssertEqual(app.progressIndicators.count, 0)
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor func testForecastLocationButtonTurnsOffHoldsForecastAndCanResume() async throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
      "-forecastLocationPaused:http://localhost:8097", "NO",
    ]
    app.resetAuthorizationStatus(for: .location)
    defer {
      app.terminate()
      app.resetAuthorizationStatus(for: .location)
    }
    app.launch()
    XCTAssertTrue(app.staticTexts["forecastLocationName"].waitForExistence(timeout: 15))
    let location = app.buttons["useCurrentLocationForecast"]
    XCTAssertEqual(location.label, "Use my location")
    location.tap()
    allowLocationIfPrompted()
    assertForecastLocationMode("Current location", in: app, timeout: 15)
    // Native toolbar items expose the action label/value, not SwiftUI's selected trait.
    XCTAssertEqual(location.label, "Stop using my location")
    let picker = app.segmentedControls["forecastViewPicker"]
    picker.buttons["Hourly · 72h"].tap()
    XCTAssertTrue(app.staticTexts["hourlyChartTitle"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts.matching(identifier: "hourlyForecastTime").count, 72)
    let city = app.staticTexts["forecastLocationName"].label
    let issue = app.staticTexts["forecastIssuedAt"].label
    let chartY = app.staticTexts["hourlyChartTitle"].frame.minY
    location.tap()
    XCTAssertEqual(location.label, "Use my location")
    assertForecastLocationMode("Chosen location", in: app)
    XCTAssertEqual(app.staticTexts["forecastLocationName"].label, city)
    XCTAssertEqual(app.staticTexts["forecastIssuedAt"].label, issue)
    XCTAssertEqual(app.staticTexts["hourlyChartTitle"].frame.minY, chartY, accuracy: 1)
    XCTAssertEqual(app.staticTexts.matching(identifier: "hourlyForecastTime").count, 72)
    assertNoForecastLoadingIndicators(app)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Location following off with hourly forecast retained"
    shot.lifetime = .keepAlways
    add(shot)
    _ = try await forecastFixture("/test/startup?reset=1")
    XCUIDevice.shared.press(.home)
    app.activate()
    try await waitForForecastRequest("/api/v1/forecast/regions")
    let data = try await forecastFixture("/test/startup")
    let events = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    XCTAssertFalse(events.contains { $0["path"] as? String == "/api/v1/forecast/nearest" })
    XCTAssertEqual(location.label, "Use my location")
    XCTAssertEqual(app.staticTexts["forecastLocationName"].label, city)
    app.terminate()
    app.launchArguments = ["-weatherAtlasTestServerURL", "http://localhost:8097"]
    app.launch()
    XCTAssertTrue(app.staticTexts["forecastLocationName"].waitForExistence(timeout: 15))
    XCTAssertEqual(location.label, "Use my location")
    XCTAssertEqual(app.staticTexts["forecastLocationName"].label, city)
    app.buttons["Show on map"].tap()
    XCTAssertTrue(app.navigationBars["Forecast location"].waitForExistence(timeout: 5))
    app.buttons["Cancel"].tap()
    XCTAssertEqual(location.label, "Use my location")
    location.tap()
    assertForecastLocationMode("Current location", in: app, timeout: 15)
    XCTAssertEqual(location.label, "Stop using my location")
  }

  @MainActor func testCompactForecastHeaderKeepsMapAndSavingAvailable() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-savedPlaces:http://localhost:8097", "",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    dismissLocationPromptForManualForecast()
    let header = app.descendants(matching: .any).matching(identifier: "forecastHeader").firstMatch
    XCTAssertTrue(header.waitForExistence(timeout: 15))
    XCTAssertEqual(
      header.staticTexts.count, 3,
      "Only location, issue time and map button text belong in the card")
    XCTAssertEqual(header.staticTexts["forecastLocationName"].label, "Halifax")
    XCTAssertTrue(header.staticTexts["forecastIssuedAt"].label.hasPrefix("Issued "))
    XCTAssertTrue(header.buttons["Show on map"].isHittable)
    XCTAssertLessThan(header.frame.height, 130)
    XCTAssertFalse(header.buttons["Save or unsave Halifax"].exists)
    XCTAssertTrue(app.navigationBars.buttons["Save or unsave Halifax"].isHittable)
    XCTAssertTrue(app.staticTexts["forecast-temperature-Today"].isHittable)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Compact forecast header and collapsed observations"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.navigationBars.buttons["Save or unsave Halifax"].tap()
    app.tabBars.buttons["Saved"].tap()
    XCTAssertTrue(app.staticTexts["Halifax"].waitForExistence(timeout: 5))
    app.staticTexts["Halifax"].tap()
    XCTAssertTrue(app.buttons["Show on map"].waitForExistence(timeout: 5))
    app.buttons["Show on map"].tap()
    XCTAssertTrue(app.navigationBars["Forecast location"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.segmentedControls["mapModePicker"].exists)
    app.buttons["Cancel"].tap()
    XCTAssertTrue(app.tabBars.buttons["Forecast"].isSelected)
  }

  @MainActor func testForecastLocationMapCityPinConfirmationAndPersistence() async throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
      "-forecastMapPin:http://localhost:8097", "",
    ]
    app.launch()
    dismissLocationPromptForManualForecast()
    XCTAssertTrue(app.buttons["Show on map"].waitForExistence(timeout: 15))
    _ = try await forecastFixture("/test/startup?reset=1")
    app.buttons["Show on map"].tap()
    // MapKit exposes its internal map element, not the MKMapView's identifier.
    XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 10))
    XCTAssertFalse(app.segmentedControls["mapModePicker"].exists)
    XCTAssertFalse(app.buttons["mapDataPicker"].exists)
    XCTAssertFalse(app.staticTexts["mapPlaybackStatus"].exists)
    app.buttons["forecastMapCitySearch"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("Sydney")
    let city = app.buttons["forecast-map-city-sydney-fixture"]
    XCTAssertTrue(city.waitForExistence(timeout: 10))
    city.tap()
    XCTAssertTrue(app.staticTexts["forecastMapSelection"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.staticTexts["forecastMapSelection"].label, "Sydney")
    let marker = app.descendants(matching: .any).matching(
      identifier: "forecast-city-marker-sydney-fixture"
    ).firstMatch
    XCTAssertTrue(marker.waitForExistence(timeout: 10))
    marker.tap()
    XCTAssertEqual(app.staticTexts["forecastMapSelection"].label, "Sydney")
    app.buttons["useMapForecast"].tap()
    XCTAssertTrue(app.staticTexts["forecastLocationName"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts["forecastLocationName"].label, "Sydney")
    app.buttons["Show on map"].tap()
    XCTAssertTrue(app.navigationBars["Forecast location"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["Nearest available regional forecast to your pin."].exists)
    let map = app.maps.firstMatch
    map.coordinate(withNormalizedOffset: .init(dx: 0.7, dy: 0.35)).press(forDuration: 0.7)
    XCTAssertTrue(
      app.staticTexts["Nearest available regional forecast to your pin."].waitForExistence(
        timeout: 10))
    XCTAssertTrue(app.buttons["useMapForecast"].isEnabled)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Clean forecast location map with dropped pin"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let data = try await forecastFixture("/test/startup")
    let events = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    XCTAssertTrue(events.contains { $0["path"] as? String == "/api/v1/forecast/nearest" })
    XCTAssertFalse(
      events.contains {
        let path = $0["path"] as? String ?? ""
        return path == "/api/v1/products" || path == "/api/v1/imagery"
          || path == "/api/v1/layers/resolve" || path == "/api/v1/sample"
      })
    app.buttons["useMapForecast"].tap()
    XCTAssertTrue(app.staticTexts["forecastLocationName"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts["forecastLocationName"].label, "Sydney")
    XCTAssertTrue(app.tabBars.buttons["Forecast"].isSelected)
    app.terminate()
    app.launchArguments = ["-weatherAtlasTestServerURL", "http://localhost:8097"]
    app.launch()
    XCTAssertTrue(app.staticTexts["forecastLocationName"].waitForExistence(timeout: 15))
    XCTAssertEqual(app.staticTexts["forecastLocationName"].label, "Sydney")
    app.buttons["Show on map"].tap()
    XCTAssertTrue(
      app.staticTexts["Nearest available regional forecast to your pin."].waitForExistence(
        timeout: 5))
    app.buttons["Cancel"].tap()
    XCTAssertEqual(app.staticTexts["forecastLocationName"].label, "Sydney")
  }

  @MainActor func testForecastLocationMapCancelKeepsForecastAndWeatherMapMode() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    dismissLocationPromptForManualForecast()
    app.tabBars.buttons["Map"].tap()
    let modes = app.segmentedControls["mapModePicker"]
    XCTAssertTrue(modes.waitForExistence(timeout: 10))
    modes.buttons["Satellite"].tap()
    app.tabBars.buttons["Forecast"].tap()
    app.buttons["Show on map"].tap()
    XCTAssertTrue(app.navigationBars["Forecast location"].waitForExistence(timeout: 5))
    XCTAssertFalse(modes.exists)
    app.maps.firstMatch.coordinate(withNormalizedOffset: .init(dx: 0.7, dy: 0.35)).tap()
    XCTAssertTrue(
      app.staticTexts["Nearest available regional forecast to your pin."].waitForExistence(
        timeout: 10))
    app.buttons["Cancel"].tap()
    XCTAssertEqual(app.staticTexts["forecastLocationName"].label, "Halifax")
    app.tabBars.buttons["Map"].tap()
    XCTAssertTrue(modes.buttons["Satellite"].isSelected)
  }

  @MainActor func testForecastHeaderAdaptsToAccessibilityTextSize() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    dismissLocationPromptForManualForecast()
    let issue = app.staticTexts["forecastIssuedAt"]
    XCTAssertTrue(issue.waitForExistence(timeout: 15))
    let map = app.buttons["Show on map"]
    XCTAssertGreaterThan(map.frame.minY, issue.frame.maxY)
    XCTAssertTrue(map.isHittable)
    XCTAssertLessThanOrEqual(map.frame.maxX, app.frame.maxX - 16)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Forecast header at accessibility text size"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor func testForecastChangesAndNearbyObservations() throws {
    let app = XCUIApplication()
    app.launchEnvironment["WEATHERATLAS_NATIVE_CHANGES"] =
      ProcessInfo.processInfo.environment["WEATHERATLAS_NATIVE_CHANGES"]
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    dismissLocationPromptForManualForecast()
    let changes = app.buttons["forecastChanges"]
    XCTAssertTrue(changes.waitForExistence(timeout: 15))
    XCTAssertEqual(changes.value as? String, "Collapsed")
    XCTAssertFalse(app.staticTexts["Temperature: 19 → 22 °C"].exists)
    XCTAssertLessThan(changes.frame.height, 30, "Collapsed control must be text-height only")
    changes.tap()
    waitForChangesParagraphOrAvailability(app)
    XCTAssertEqual(changes.value as? String, "Expanded")
    changes.tap()
    XCTAssertFalse(app.staticTexts["Temperature: 19 → 22 °C"].exists)
    let observations = app.buttons["nearbyObservations"]
    XCTAssertEqual(observations.value as? String, "Collapsed")
    let station = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", "Observed at Shearwater")
    ).firstMatch
    XCTAssertFalse(station.exists)
    XCTAssertFalse(
      app.staticTexts["Distances from this forecast region's representative point."].exists)
    observations.tap()
    XCTAssertTrue(station.waitForExistence(timeout: 10))
    XCTAssertEqual(observations.value as? String, "Expanded")
    observations.tap()
    XCTAssertFalse(station.exists)
    observations.tap()
    XCTAssertTrue(station.waitForExistence(timeout: 5))
    changes.tap()
    XCTAssertEqual(
      observations.value as? String, "Expanded",
      "Nearby observations must expand independently of the insight buttons")
    changes.tap()
    station.tap()
    XCTAssertTrue(app.navigationBars["Shearwater"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Trace"].exists)
    XCTAssertTrue(app.staticTexts["Past 48 hours"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Nearby station details"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor func testSummaryPreparesBeforeOpeningAndCanBeClosed() {
    let app = XCUIApplication()
    app.launchEnvironment["WEATHERATLAS_NATIVE_CHANGES"] =
      ProcessInfo.processInfo.environment["WEATHERATLAS_NATIVE_CHANGES"]
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    dismissLocationPromptForManualForecast()
    let summary = app.buttons["forecastSummary"]
    let changes = app.buttons["forecastChanges"]
    XCTAssertTrue(summary.waitForExistence(timeout: 15))
    XCTAssertLessThan(summary.frame.height, 30)
    XCTAssertEqual(summary.frame.minY, changes.frame.minY, accuracy: 1)
    XCTAssertTrue((summary.value as? String)?.hasPrefix("Collapsed") == true)
    XCTAssertFalse(app.buttons["forecastSummaryRetry"].exists)
    let prepared = expectation(
      for: NSPredicate { _, _ in
        let value = summary.value as? String ?? ""
        return value == "Collapsed, Summary ready" || value == "Collapsed, Summary unavailable"
      }, evaluatedWith: nil)
    wait(for: [prepared], timeout: 60)
    XCTAssertFalse(
      app.descendants(matching: .any).matching(identifier: "forecastSummaryText").firstMatch.exists)
    changes.tap()
    waitForChangesParagraphOrAvailability(app)
    if !summary.isHittable { app.swipeUp() }
    summary.tap()
    XCTAssertTrue((summary.value as? String)?.hasPrefix("Expanded") == true)
    XCTAssertEqual(changes.value as? String, "Collapsed")
    XCTAssertFalse(app.staticTexts["Temperature: 19 → 22 °C"].exists)
    // This exercises the real native availability path, not a synthetic AI response.
    let disclosure = app.staticTexts[
      "Uses Apple Intelligence on this device only. No forecast data is sent to a cloud AI service."
    ]
    let generated = app.descendants(matching: .any).matching(identifier: "forecastSummaryText")
      .firstMatch
    XCTAssertTrue(disclosure.waitForExistence(timeout: 5) || generated.exists)
    let finished = expectation(
      for: NSPredicate { _, _ in
        generated.exists || app.staticTexts["forecastSummaryMessage"].exists
      }, evaluatedWith: nil)
    wait(for: [finished], timeout: 60)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Compact forecast buttons and native summary"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    if generated.exists {
      let output = XCTAttachment(string: generated.value as? String ?? generated.label)
      output.name = "Automatically generated native summary"
      output.lifetime = .keepAlways
      add(output)
    }
    changes.tap()
    XCTAssertEqual(changes.value as? String, "Expanded")
    XCTAssertTrue((summary.value as? String)?.hasPrefix("Collapsed") == true)
    XCTAssertFalse(app.buttons["forecastSummaryRetry"].exists)
    XCTAssertFalse(generated.exists)
    XCTAssertFalse(app.staticTexts["forecastSummaryMessage"].exists)
    changes.tap()
    XCTAssertEqual(changes.value as? String, "Collapsed")
    summary.tap()
    XCTAssertTrue(
      generated.exists || app.staticTexts["forecastSummaryMessage"].exists,
      "Reopening must reuse the prepared summary state")
    summary.tap()
    XCTAssertTrue((summary.value as? String)?.hasPrefix("Collapsed") == true)
  }

  @MainActor private func waitForChangesParagraphOrAvailability(_ app: XCUIApplication) {
    let paragraph = app.descendants(matching: .any).matching(identifier: "forecastChangesText")
      .firstMatch
    let available = expectation(
      for: NSPredicate { _, _ in
        paragraph.exists
          || app.descendants(matching: .any).matching(identifier: "forecastChangesMessage")
            .firstMatch.exists
      }, evaluatedWith: nil)
    wait(for: [available], timeout: 60)
    if ProcessInfo.processInfo.environment["WEATHERATLAS_NATIVE_CHANGES"] == "1" {
      XCTAssertTrue(
        paragraph.exists, "Native acceptance must render a paragraph, not just an error state")
    }
    XCTAssertFalse(app.staticTexts["Temperature: 19 → 22 °C"].exists)
    XCTAssertEqual(app.progressIndicators.count, 0)
    if paragraph.exists {
      let text = paragraph.label
      XCTAssertFalse(text.contains("→"))
      XCTAssertLessThanOrEqual(text.split(whereSeparator: \.isWhitespace).count, 85)
      let output = XCTAttachment(string: text)
      output.name = "On-device important forecast changes"
      output.lifetime = .keepAlways
      add(output)
    }
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Compact What changed paragraph"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor func testLiveServerNativeSummaryOnDevice() throws {
    #if targetEnvironment(simulator)
      throw XCTSkip(
        "Live-server native inference acceptance runs on the connected physical iPhone only.")
    #else
      let app = XCUIApplication()
      app.launchArguments = [
        "-weatherAtlasTestServerURL", "https://weatheratlas.ioresearch.ca",
        "-forecastRegion:https://weatheratlas.ioresearch.ca", "973f9e2654e472e2",
      ]
      app.launch()
      let summary = app.buttons["forecastSummary"]
      XCTAssertTrue(summary.waitForExistence(timeout: 30))
      if !summary.isHittable { app.swipeUp() }
      summary.tap()
      let generated = app.descendants(matching: .any).matching(identifier: "forecastSummaryText")
        .firstMatch
      let message = app.staticTexts["forecastSummaryMessage"]
      let finished = expectation(
        for: NSPredicate { _, _ in generated.exists || message.exists }, evaluatedWith: nil)
      wait(for: [finished], timeout: 60)
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.name = "Physical iPhone native summary"
      screenshot.lifetime = .keepAlways
      add(screenshot)
      if message.exists {
        throw XCTSkip("Native generation unavailable on this phone: \(message.label)")
      }
      XCTAssertTrue(generated.exists)
      let text = generated.value as? String ?? generated.label
      XCTAssertFalse(text.isEmpty)
      let output = XCTAttachment(string: text)
      output.name = "Native forecast summary output"
      output.lifetime = .keepAlways
      add(output)
    #endif
  }

  @MainActor func testLiveHalifaxSummaryOnSimulator() throws {
    #if targetEnvironment(simulator)
      guard ProcessInfo.processInfo.environment["WEATHERATLAS_LIVE_SUMMARY"] == "1" else {
        throw XCTSkip(
          "Opt-in live LAN/native-model acceptance; set TEST_RUNNER_WEATHERATLAS_LIVE_SUMMARY=1.")
      }
      let app = XCUIApplication()
      app.launchArguments = [
        "-weatherAtlasTestServerURL", "https://weatheratlas.ioresearch.ca",
        "-forecastRegion:https://weatheratlas.ioresearch.ca", "973f9e2654e472e2",
      ]
      app.launch()
      dismissLocationPromptForManualForecast()
      let summary = app.buttons["forecastSummary"]
      XCTAssertTrue(summary.waitForExistence(timeout: 30))
      let prepared = expectation(
        for: NSPredicate { _, _ in
          let value = summary.value as? String ?? ""
          return value == "Collapsed, Summary ready" || value == "Collapsed, Summary unavailable"
        }, evaluatedWith: nil)
      wait(for: [prepared], timeout: 60)
      if !summary.isHittable { app.swipeUp() }
      summary.tap()
      let message = app.staticTexts["forecastSummaryMessage"]
      if message.exists {
        XCTFail("Opt-in native summary acceptance failed: \(message.label)")
        return
      }
      let generated = app.descendants(matching: .any).matching(identifier: "forecastSummaryText")
        .firstMatch
      XCTAssertTrue(generated.waitForExistence(timeout: 5))
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.name = "Live Halifax three-sentence outlook"
      screenshot.lifetime = .keepAlways
      add(screenshot)
    #else
      throw XCTSkip("Read-only live API acceptance using the dedicated simulator only.")
    #endif
  }

  @MainActor func testWeatherStationsKeepTopMapTabs() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    dismissLocationPromptForManualForecast()
    app.tabBars.buttons["Map"].tap()
    app.buttons["Map data"].tap()
    let station = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Weather stations"))
      .firstMatch
    XCTAssertTrue(station.waitForExistence(timeout: 10))
    station.tap()
    XCTAssertTrue(app.segmentedControls["mapModePicker"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["stationFieldPicker"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts["1 stations · Tap a marker for readings and history"].waitForExistence(
        timeout: 10))
    XCTAssertFalse(app.buttons["mapModelPicker"].exists)
    app.segmentedControls["mapModePicker"].buttons["Radar"].tap()
    XCTAssertFalse(app.buttons["stationFieldPicker"].exists)
    app.segmentedControls["mapModePicker"].buttons["Model"].tap()
    XCTAssertTrue(app.buttons["stationFieldPicker"].waitForExistence(timeout: 5))
  }

  @MainActor private func dismissLocationPromptForManualForecast() {
    // The unit-test host can leave a location prompt pending on a fresh simulator.
    // These presentation tests explicitly choose a region and do not use GPS.
    let deny = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Don’t Allow"]
    if deny.waitForExistence(timeout: 2) { deny.tap() }
  }

  @MainActor private func assertForecastLocationMode(
    _ mode: String, in app: XCUIApplication, timeout: TimeInterval = 10
  ) {
    let expected = expectation(
      for: NSPredicate(format: "value == %@", mode),
      evaluatedWith: app.buttons["useCurrentLocationForecast"])
    wait(for: [expected], timeout: timeout)
  }

  @MainActor private func forecastFixture(_ path: String) async throws -> Data {
    try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8097\(path)")!).0
  }

  @MainActor private func assertNoForecastLoadingIndicators(_ app: XCUIApplication) {
    for id in [
      "forecastInitialLoading", "hourlyForecastInitialLoading", "forecastInitialLocationLoading",
    ] {
      XCTAssertFalse(app.descendants(matching: .any)[id].exists)
    }
    XCTAssertEqual(app.progressIndicators.count, 0)
    XCTAssertEqual(
      app.buttons["nearbyObservations"].value as? String, "Collapsed",
      "A routine update must not expand observations")
  }

  @MainActor private func waitForForecastRequest(_ path: String) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
      let data = try await forecastFixture("/test/startup")
      let events = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
      if events.contains(where: { $0["path"] as? String == path }) { return }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTFail("Expected a background request for \(path)")
  }

  @MainActor func testBackgroundRefreshKeepsDailyAndHourlyLayoutStable() async throws {
    _ = try await forecastFixture("/test/forecast-refresh?reset=1")
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
      "-forecastSnapshot:v1:http://localhost:8097:manual", "",
    ]
    do {
      app.launch()
      dismissLocationPromptForManualForecast()
      let picker = app.segmentedControls["forecastViewPicker"]
      XCTAssertTrue(picker.waitForExistence(timeout: 10))
      let warm = expectation(
        for: NSPredicate(format: "label == %@", "Precipitation: 2.4 mm"),
        evaluatedWith: app.staticTexts["precipitation-Tonight"])
      await fulfillment(of: [warm], timeout: 10)
      for (offset, mode) in [(1, "Daily / Nightly"), (2, "Hourly · 72h")] {
        picker.buttons[mode].tap()
        let anchor = app.staticTexts[
          offset == 1 ? "forecast-temperature-Today" : "hourlyChartTitle"]
        XCTAssertTrue(anchor.waitForExistence(timeout: 5))
        let originalFrame = anchor.frame
        _ = try await forecastFixture(
          "/test/forecast-refresh?hold=bulletin&hold=optional&temperature_offset=\(offset)")
        _ = try await forecastFixture("/test/startup?reset=1")
        // Foreground reactivation uses the same refresh path as the five-minute timer.
        XCUIDevice.shared.press(.home)
        app.activate()
        try await waitForForecastRequest("/api/v1/forecast/regions")
        assertNoForecastLoadingIndicators(app)
        XCTAssertFalse(app.staticTexts["savedForecastNotice"].exists)
        XCTAssertEqual(anchor.frame.minY, originalFrame.minY, accuracy: 1)

        _ = try await forecastFixture("/test/forecast-refresh?release=bulletin")
        try await waitForForecastRequest("/api/v1/forecast/hourly")
        assertNoForecastLoadingIndicators(app)
        XCTAssertFalse(app.staticTexts["savedForecastNotice"].exists)
        XCTAssertEqual(anchor.frame.minY, originalFrame.minY, accuracy: 1)
        if offset == 1 {
          XCTAssertEqual(anchor.label, "23°", "New bulletin values must still be published")
        } else {
          XCTAssertEqual(
            app.staticTexts.matching(identifier: "hourlyForecastTemperature").firstMatch.label, "19"
          )
          XCTAssertEqual(app.staticTexts.matching(identifier: "hourlyForecastTime").count, 72)
        }

        _ = try await forecastFixture("/test/forecast-refresh?release=optional")
        picker.buttons["Hourly · 72h"].tap()
        let updated = expectation(
          for: NSPredicate(format: "label == %@", String(18 + offset)),
          evaluatedWith: app.staticTexts.matching(identifier: "hourlyForecastTemperature")
            .firstMatch)
        await fulfillment(of: [updated], timeout: 10)
        assertNoForecastLoadingIndicators(app)
        if offset == 2 {
          XCTAssertEqual(anchor.frame.minY, originalFrame.minY, accuracy: 1)
        }
      }
      app.terminate()
      _ = try await forecastFixture("/test/forecast-refresh?reset=1")
    } catch {
      app.terminate()
      _ = try? await forecastFixture("/test/forecast-refresh?reset=1")
      throw error
    }
  }

  @MainActor func testInitialForecastLoadingIsVisibleWithoutExistingData() async throws {
    _ = try await forecastFixture("/test/forecast-refresh?reset=1&hold=bulletin&hold=optional")
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
      "-forecastSnapshot:v1:http://localhost:8097:manual", "",
    ]
    do {
      app.launch()
      dismissLocationPromptForManualForecast()
      XCTAssertTrue(
        app.descendants(matching: .any)["forecastInitialLoading"].waitForExistence(timeout: 5))
      XCTAssertFalse(app.staticTexts["Halifax"].exists)
      _ = try await forecastFixture("/test/forecast-refresh?release=bulletin")
      let picker = app.segmentedControls["forecastViewPicker"]
      XCTAssertTrue(picker.waitForExistence(timeout: 10))
      picker.buttons["Hourly · 72h"].tap()
      XCTAssertTrue(
        app.descendants(matching: .any)["hourlyForecastInitialLoading"].waitForExistence(timeout: 5)
      )
      XCTAssertEqual(app.staticTexts.matching(identifier: "hourlyForecastTime").count, 0)
      _ = try await forecastFixture("/test/forecast-refresh?release=optional")
      XCTAssertTrue(app.staticTexts["hourlyChartTitle"].waitForExistence(timeout: 10))
      assertNoForecastLoadingIndicators(app)
      app.terminate()
      _ = try await forecastFixture("/test/forecast-refresh?reset=1")
    } catch {
      app.terminate()
      _ = try? await forecastFixture("/test/forecast-refresh?reset=1")
      throw error
    }
  }

  @MainActor func testDailyAndNightlyWeatherIconsAppearBesideTemperatures() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
      "-forecastSnapshot:v1:http://localhost:8097:manual", "",
    ]
    app.launch()
    dismissLocationPromptForManualForecast()
    XCTAssertTrue(app.segmentedControls["forecastViewPicker"].waitForExistence(timeout: 10))
    let rain = app.images["forecast-condition-Today"]
    let tonight = app.images["forecast-condition-Tonight"]
    for _ in 0..<3 {
      if tonight.isHittable { break }
      app.swipeUp()
    }
    XCTAssertEqual(rain.label, "Rain")
    XCTAssertEqual(tonight.label, "Partly cloudy")
    for name in ["Today", "Tonight"] {
      let icon = app.images["forecast-condition-\(name)"]
      let temperature = app.staticTexts["forecast-temperature-\(name)"]
      XCTAssertLessThan(icon.frame.maxX, temperature.frame.minX)
      XCTAssertEqual(icon.frame.midY, temperature.frame.midY, accuracy: 8)
    }
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Daily and nightly weather icons beside temperatures"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor func testSettingsDefaultLocationPersistsAndDrivesForecastWithoutGPS() {
    let app = XCUIApplication()
    let baseArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "",
      "-forecastSnapshot:v1:http://localhost:8097:automatic", "",
    ]
    app.launchArguments = baseArguments + ["-defaultForecastLocation:http://localhost:8097", ""]
    app.resetAuthorizationStatus(for: .location)
    defer {
      app.terminate()
      app.resetAuthorizationStatus(for: .location)
    }
    app.launch()
    let deny = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Don’t Allow"]
    XCTAssertTrue(deny.waitForExistence(timeout: 10))
    deny.tap()
    XCTAssertTrue(app.staticTexts["Halifax"].waitForExistence(timeout: 15))
    app.tabBars.buttons["Settings"].tap()
    XCTAssertEqual(app.buttons["defaultForecastLocation"].value as? String, "Halifax")
    app.buttons["defaultForecastLocation"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap()
    search.typeText("Sydney")
    let sydney = app.buttons["default-location-sydney-fixture"]
    XCTAssertTrue(sydney.waitForExistence(timeout: 15))
    sydney.tap()
    XCTAssertTrue(app.buttons["defaultForecastLocation"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["defaultForecastLocation"].value as? String, "Sydney")
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Settings default forecast location"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.tabBars.buttons["Forecast"].tap()
    XCTAssertTrue(app.staticTexts["Sydney"].waitForExistence(timeout: 15))
    assertForecastLocationMode("Default location", in: app)
    app.segmentedControls["forecastViewPicker"].buttons["Hourly · 72h"].tap()
    XCTAssertTrue(app.staticTexts["Next 72 hours"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts.matching(identifier: "hourlyForecastTime").count, 72)

    app.terminate()
    app.launchArguments = baseArguments
    app.launch()
    XCTAssertTrue(app.staticTexts["Sydney"].waitForExistence(timeout: 15))
    assertForecastLocationMode("Default location", in: app)
    app.tabBars.buttons["Settings"].tap()
    XCTAssertEqual(app.buttons["defaultForecastLocation"].value as? String, "Sydney")
    app.buttons["defaultForecastLocation"].tap()
    app.buttons["default-location-halifax"].tap()
    XCTAssertTrue(app.buttons["defaultForecastLocation"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["defaultForecastLocation"].value as? String, "Halifax")
    app.tabBars.buttons["Forecast"].tap()
    XCTAssertTrue(app.staticTexts["Halifax"].waitForExistence(timeout: 15))
  }

  @MainActor func testMapModesStayAboveModelControlsAndRestoreSelection() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    dismissLocationPromptForManualForecast()
    app.tabBars.buttons["Map"].tap()
    let modes = app.segmentedControls["mapModePicker"]
    XCTAssertTrue(modes.waitForExistence(timeout: 10))
    XCTAssertEqual(modes.buttons.count, 3)
    XCTAssertTrue(modes.buttons["Model"].isSelected)
    XCTAssertTrue(modes.buttons["Radar"].exists)
    XCTAssertTrue(modes.buttons["Satellite"].exists)
    selectMapData("field:relative_humidity_2m", search: "Humidity", in: app)
    let source = app.buttons["mapModelPicker"]
    XCTAssertTrue(source.waitForExistence(timeout: 10))
    source.tap()
    app.buttons["Global forecast (GDPS)"].tap()
    XCTAssertTrue(source.label.contains("GDPS"))
    XCTAssertGreaterThanOrEqual(app.buttons["mapDataPicker"].frame.minY, modes.frame.maxY)
    XCTAssertGreaterThanOrEqual(source.frame.minY, modes.frame.maxY)
    let modelShot = XCTAttachment(screenshot: app.screenshot())
    modelShot.name = "Model Radar Satellite tabs above data and model selectors"
    modelShot.lifetime = .keepAlways
    add(modelShot)

    for (mode, title) in [("Radar", "Rain radar"), ("Satellite", "Satellite — visible")] {
      modes.buttons[mode].tap()
      XCTAssertTrue(modes.buttons[mode].isSelected)
      XCTAssertFalse(source.exists)
      XCTAssertFalse(app.buttons["mapDataPicker"].exists)
      XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
      XCTAssertTrue(app.navigationBars.buttons["Map data"].exists)
      let shot = XCTAttachment(screenshot: app.screenshot())
      shot.name = "\(mode) tabs without model selectors"
      shot.lifetime = .keepAlways
      add(shot)
      assertNoManualImageRefresh(in: app)
    }
    modes.buttons["Model"].tap()
    XCTAssertTrue(modes.buttons["Model"].isSelected)
    XCTAssertTrue(source.waitForExistence(timeout: 10))
    XCTAssertTrue(source.label.contains("GDPS"))
    XCTAssertTrue(app.buttons["mapDataPicker"].label.contains("Humidity"))
    XCTAssertGreaterThanOrEqual(source.frame.minY, modes.frame.maxY)
  }

  @MainActor func testSimpleMapDataNamesSourcesOrderingAndSingleSelection() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    dismissLocationPromptForManualForecast()
    app.tabBars.buttons["Map"].tap()
    XCTAssertTrue(app.buttons["mapDataPicker"].waitForExistence(timeout: 10))
    app.buttons["mapDataPicker"].tap()
    let temperature = app.buttons["map-option-field:air_temperature_2m"]
    let rain = app.buttons["map-option-field:total_precipitation_1h"]
    let humidity = app.buttons["map-option-field:relative_humidity_2m"]
    XCTAssertTrue(temperature.waitForExistence(timeout: 10))
    let none = app.buttons["map-option-none"]
    XCTAssertTrue(none.exists)
    XCTAssertLessThan(none.frame.minY, temperature.frame.minY)
    XCTAssertLessThan(none.frame.minY, app.buttons["Source & display options"].frame.minY)
    XCTAssertTrue(rain.exists)
    XCTAssertTrue(humidity.exists)
    XCTAssertEqual(app.buttons.matching(identifier: "map-option-field:air_temperature_2m").count, 1)
    XCTAssertTrue(temperature.label.contains("Temperature, ECCC · HRDPS"))
    XCTAssertFalse(app.buttons["map-option-field:wildfire_pm25_surface"].exists)
    XCTAssertTrue(temperature.isSelected)
    XCTAssertLessThan(temperature.frame.minY, rain.frame.minY)
    XCTAssertLessThan(rain.frame.minY, humidity.frame.minY)
    XCTAssertFalse(app.switches["10 m wind arrows"].exists)
    XCTAssertFalse(app.switches["CWFIS satellite hotspots"].exists)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Simple map data list with subtle sources"
    shot.lifetime = .keepAlways
    add(shot)
    humidity.tap()
    XCTAssertTrue(app.buttons["mapDataPicker"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["mapDataPicker"].label.contains("Humidity"))
    app.buttons["mapDataPicker"].tap()
    XCTAssertTrue(humidity.waitForExistence(timeout: 5))
    XCTAssertTrue(humidity.isSelected)
    XCTAssertFalse(temperature.isSelected)
    app.buttons["Source & display options"].tap()
    app.buttons["mapDataSource"].tap()
    XCTAssertFalse(app.buttons["FLEXPART_SMOKE"].exists)
    XCTAssertFalse(app.buttons["CUSTOM_RUN_123"].exists)
    app.buttons["Global forecast (GDPS)"].tap()
    XCTAssertTrue(humidity.label.contains("ECCC · GDPS"))
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("FLEXPART")
    XCTAssertTrue(app.staticTexts["No matching map data."].waitForExistence(timeout: 5))
    XCTAssertEqual(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "map-option-")).count, 1)
    app.buttons["map-option-none"].tap()
    XCTAssertTrue(app.buttons["mapDataPicker"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["mapDataPicker"].label, "Choose map data: None")
  }

  @MainActor func testNoneClearsMainMapAndRemainsFirstDuringSearch() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    dismissLocationPromptForManualForecast()
    app.tabBars.buttons["Map"].tap()
    let modes = app.segmentedControls["mapModePicker"]
    XCTAssertTrue(modes.waitForExistence(timeout: 10))
    let ready = expectation(
      for: NSPredicate(format: "label == %@", "0.75 seconds per complete frame"),
      evaluatedWith: app.staticTexts["mapPlaybackStatus"])
    wait(for: [ready], timeout: 15)
    app.buttons["mapPlaybackToggle"].tap()
    openMapData(in: app)
    let none = app.buttons["map-option-none"]
    XCTAssertTrue(none.waitForExistence(timeout: 5))
    XCTAssertEqual(none.label, "None")
    XCTAssertLessThan(none.frame.minY, app.buttons["Source & display options"].frame.minY)
    none.tap()
    XCTAssertTrue(app.buttons["mapDataPicker"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["mapDataPicker"].label, "Choose map data: None")
    XCTAssertFalse(app.buttons["mapPlaybackToggle"].exists)
    XCTAssertFalse(app.staticTexts["mapPlaybackStatus"].exists)
    XCTAssertFalse(app.buttons["mapModelPicker"].exists)
    XCTAssertFalse(app.buttons["Fit layer"].exists)
    XCTAssertEqual(app.progressIndicators.count, 0)
    app.maps.firstMatch.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.4)).tap()
    XCTAssertFalse(app.navigationBars["At this point"].exists)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Main map with None selected"
    shot.lifetime = .keepAlways
    add(shot)
    openMapData(in: app)
    XCTAssertTrue(none.isSelected)
    let search = app.searchFields.firstMatch
    search.tap()
    search.typeText("Humidity")
    let humidity = app.buttons["map-option-field:relative_humidity_2m"]
    XCTAssertTrue(humidity.waitForExistence(timeout: 5))
    XCTAssertTrue(none.exists)
    XCTAssertLessThan(none.frame.minY, humidity.frame.minY)
    humidity.tap()
    XCTAssertTrue(app.buttons["mapModelPicker"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["mapPlaybackToggle"].exists)
    for name in ["Radar", "Satellite"] {
      modes.buttons[name].tap()
      XCTAssertTrue(app.buttons["mapPlaybackToggle"].exists)
      openMapData(in: app)
      none.tap()
      XCTAssertTrue(app.buttons["mapDataPicker"].waitForExistence(timeout: 5))
      XCTAssertEqual(app.buttons["mapDataPicker"].label, "Choose map data: None")
      XCTAssertFalse(app.buttons["mapPlaybackToggle"].exists)
    }
  }

  @MainActor func testUncachedHalifaxLaunchDoesNotWaitForCountryCatalogueOrMap() async throws {
    func control(_ value: String) async throws -> Data {
      try await URLSession.shared.data(
        from: URL(string: "http://localhost:8097/test/startup?\(value)")!
      ).0
    }
    _ = try await control("catalogue_delay=10&reset=1")
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "",
      "-forecastSnapshot:v1:http://localhost:8097:automatic", "",
    ]
    let started = ContinuousClock.now
    app.launch()
    XCTAssertTrue(app.navigationBars["Forecast"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.staticTexts["Halifax"].waitForExistence(timeout: 3))
    let elapsed = started.duration(to: .now)
    // Include app.launch(), where a black-screen delay was previously unmeasured.
    XCTAssertLessThan(elapsed, .seconds(8), "Cold launch through visible forecast: \(elapsed)")
    let data = try await control("")
    let events = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    let paths = events.compactMap { $0["path"] as? String }
    XCTAssertTrue(paths.contains("/api/v1/forecast/nearest"))
    XCTAssertFalse(paths.contains("/api/v1/forecast/regions"))
    XCTAssertFalse(paths.contains("/api/v1/products"), "Inactive map must not start its catalogue")
    let timing = XCTAttachment(
      string: "Cold launch to visible Halifax (including app.launch): \(elapsed)")
    timing.lifetime = .keepAlways
    add(timing)
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Uncached Halifax without national catalogue or map startup"
    shot.lifetime = .keepAlways
    add(shot)
    app.terminate()
    _ = try await control("catalogue_delay=0")
  }

  @MainActor func testSavedForecastAppearsBeforeASlowNetworkRefresh() async throws {
    func delay(_ seconds: Int) async throws {
      _ = try await URLSession.shared.data(
        from:
          URL(string: "http://localhost:8097/test/forecast-delay?seconds=\(seconds)")!)
    }
    try await delay(0)
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    XCTAssertTrue(app.staticTexts["precipitation-Today"].waitForExistence(timeout: 10))
    // Wait for a complete warm snapshot, including model precipitation amounts.
    let amount = app.staticTexts["precipitation-Tonight"]
    let warm = expectation(
      for: NSPredicate(format: "label == %@", "Precipitation: 2.4 mm"),
      evaluatedWith: amount)
    await fulfillment(of: [warm], timeout: 10)
    app.terminate()
    try await delay(6)
    app.launch()
    // Six-second responses cannot supply this; it must be the persisted forecast.
    XCTAssertTrue(app.staticTexts["precipitation-Today"].waitForExistence(timeout: 2))
    XCTAssertFalse(app.staticTexts["savedForecastNotice"].exists)
    assertNoForecastLoadingIndicators(app)
    XCTAssertEqual(app.staticTexts["precipitation-Today"].label, "Precipitation: 5 to 10 mm")
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Instant saved forecast while network refresh is delayed"
    shot.lifetime = .keepAlways
    add(shot)
    app.terminate()
    try await delay(0)
  }

  @MainActor func testForecastIsLeftmostAndOpensOnEveryFreshLaunch() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    let forecast = app.tabBars.buttons["Forecast"]
    XCTAssertTrue(forecast.waitForExistence(timeout: 10))
    XCTAssertTrue(forecast.isSelected)
    let tabs = ["Forecast", "Map", "Saved", "Settings"].map { app.tabBars.buttons[$0] }
    for index in 0..<(tabs.count - 1) {
      XCTAssertLessThan(tabs[index].frame.minX, tabs[index + 1].frame.minX)
    }
    XCTAssertTrue(app.navigationBars["Forecast"].exists)
    app.tabBars.buttons["Map"].tap()
    XCTAssertTrue(app.tabBars.buttons["Map"].isSelected)
    app.terminate()
    app.launch()
    XCTAssertTrue(forecast.waitForExistence(timeout: 10))
    XCTAssertTrue(forecast.isSelected)
    XCTAssertTrue(app.navigationBars["Forecast"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Forecast first tab and launch default"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor func testMapPlaybackWaitsForCompleteFramesAndOffersFourSpeeds() async throws {
    let base = URL(string: "http://localhost:8097")!
    _ = try await URLSession.shared.data(
      from: base.appendingPathComponent("test/playback-events")
        .appending(queryItems: [.init(name: "reset", value: "1")]))
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", base.absoluteString,
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    dismissLocationPromptForManualForecast()
    app.tabBars.buttons["Map"].tap()
    let status = app.staticTexts["mapPlaybackStatus"]
    let ready = NSPredicate(format: "label == %@", "0.75 seconds per complete frame")
    let first = expectation(for: ready, evaluatedWith: status)
    await fulfillment(of: [first], timeout: 20)
    app.maps.firstMatch.pinch(withScale: 2, velocity: 1)
    let zoomed = expectation(for: ready, evaluatedWith: status)
    await fulfillment(of: [zoomed], timeout: 20)
    let speed = app.segmentedControls["mapPlaybackSpeed"]
    XCTAssertTrue(speed.exists)
    for (label, seconds) in [("1×", "0.75"), ("2×", "0.375"), ("4×", "0.1875"), ("8×", "0.09375")] {
      XCTAssertTrue(speed.buttons[label].isHittable)
      speed.buttons[label].tap()
      XCTAssertEqual(status.label, "\(seconds) seconds per complete frame")
    }
    speed.buttons["2×"].tap()
    app.buttons["mapPlaybackToggle"].tap()
    let caption = app.staticTexts["mapDisplayedCaption"]
    let next = expectation(
      for: NSPredicate(format: "label == %@", "Forecast +8 h"), evaluatedWith: caption)
    await fulfillment(of: [next], timeout: 25)
    app.buttons["mapPlaybackToggle"].tap()
    let (data, _) = try await URLSession.shared.data(
      from: base.appendingPathComponent("test/playback-events"))
    let events = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    func times(_ frame: String, _ event: String) -> [Double] {
      events.filter { $0["frame"] as? String == frame && $0["event"] as? String == event }
        .compactMap { $0["at"] as? Double }
    }
    let finalTileOfSlowFrame = try XCTUnwrap(times("1", "sent").max())
    let nextFrameRequested = try XCTUnwrap(times("2", "requested").min())
    XCTAssertGreaterThanOrEqual(
      nextFrameRequested - finalTileOfSlowFrame, 0.375,
      "Even the last tile must have at least the full dwell before the next frame starts loading")
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Buffered map playback and speed controls"
    shot.lifetime = .keepAlways
    add(shot)
  }

  @MainActor func testHourlyColumnHeadersSelectThePlot() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    dismissLocationPromptForManualForecast()
    let picker = app.segmentedControls["forecastViewPicker"]
    XCTAssertTrue(picker.waitForExistence(timeout: 10))
    picker.buttons["Hourly · 72h"].tap()
    let title = app.staticTexts["hourlyChartTitle"]
    XCTAssertTrue(title.waitForExistence(timeout: 10))
    XCTAssertEqual(title.label, "Temperature (°C)")
    XCTAssertTrue(app.staticTexts["hourlyTimeHeader"].exists)
    XCTAssertFalse(app.buttons["hourlyTimeHeader"].exists)
    XCTAssertFalse(app.buttons["hourlyPlot-data"].exists)
    XCTAssertFalse(app.staticTexts["Data"].exists)
    XCTAssertFalse(app.staticTexts["Complete"].exists)
    let temperature = app.buttons["hourlyPlot-temperature"]
    for _ in 0..<3 {
      if temperature.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(temperature.isHittable)
    XCTAssertTrue(temperature.isSelected)
    // Keep the chart and the header row together in the review screenshots.
    if temperature.frame.midY < app.frame.height * 0.45 {
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
      let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
      start.press(forDuration: 0.05, thenDragTo: end)
    }
    let headerY = temperature.frame.midY
    func scrollHeaders(left: Bool) {
      let origin = app.coordinate(withNormalizedOffset: .zero)
      let start = origin.withOffset(CGVector(dx: app.frame.width * (left ? 0.9 : 0.1), dy: headerY))
      let end = origin.withOffset(CGVector(dx: app.frame.width * (left ? 0.1 : 0.9), dy: headerY))
      start.press(forDuration: 0.05, thenDragTo: end)
    }
    for (plot, expected) in [
      ("precipitation", "Precipitation (mm)"), ("wind", "Wind speed (km/h)"),
      ("gust", "Wind gusts (km/h)"), ("humidity", "Relative humidity (%)"),
    ] {
      let header = app.buttons["hourlyPlot-\(plot)"]
      for _ in 0..<4 {
        if header.isHittable { break }
        scrollHeaders(left: true)
      }
      XCTAssertTrue(header.isHittable)
      header.tap()
      XCTAssertEqual(title.label, expected)
      XCTAssertTrue(header.isSelected)
      XCTAssertFalse(temperature.isSelected)
      XCTAssertTrue(app.otherElements["hourlyForecastChart"].exists)
      XCTAssertTrue(
        (app.otherElements["hourlyForecastChart"].value as? String)?.contains(
          "Daily ticks at midnight:") == true)
    }
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Hourly humidity plot with weekday and date at midnight"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    for _ in 0..<4 {
      if temperature.isHittable { break }
      scrollHeaders(left: false)
    }
    temperature.tap()
    XCTAssertEqual(title.label, "Temperature (°C)")
    XCTAssertTrue(temperature.isSelected)
    XCTAssertEqual(app.staticTexts.matching(identifier: "hourlyForecastTime").count, 72)
  }

  @MainActor func testHalifaxFallbackWhenLocationIsDenied() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "",
      "-forecastSnapshot:v1:http://localhost:8097:automatic", "",
    ]
    app.resetAuthorizationStatus(for: .location)
    defer {
      app.terminate()
      app.resetAuthorizationStatus(for: .location)
    }
    app.launch()
    let deny = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Don’t Allow"]
    XCTAssertTrue(deny.waitForExistence(timeout: 10))
    let permission = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    permission.name = "Foreground approximate-location permission and server purpose"
    permission.lifetime = .keepAlways
    add(permission)
    deny.tap()
    assertForecastLocationMode("Default location", in: app)
    XCTAssertTrue(app.staticTexts["Halifax"].exists)
    XCTAssertNotEqual(
      app.buttons["useCurrentLocationForecast"].value as? String, "Current location")
    XCTAssertTrue(app.staticTexts["precipitation-Today"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Halifax fallback forecast"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let hourly = app.segmentedControls["forecastViewPicker"].buttons["Hourly · 72h"]
    for _ in 0..<3 {
      if hourly.isHittable { break }
      app.swipeUp()
    }
    hourly.tap()
    XCTAssertTrue(
      app.staticTexts["ECCC GDPS · 71 of 72 complete hours"].waitForExistence(timeout: 10))
    app.navigationBars.buttons["Choose region"].tap()
    let sydney = app.buttons.containing(.staticText, identifier: "Sydney").firstMatch
    XCTAssertTrue(sydney.waitForExistence(timeout: 10))
    sydney.tap()
    assertForecastLocationMode("Chosen location", in: app)
    XCTAssertTrue(app.staticTexts["Sydney"].exists)
    XCTAssertNotEqual(
      app.buttons["useCurrentLocationForecast"].value as? String, "Default location")
    app.buttons["useCurrentLocationForecast"].tap()
    assertForecastLocationMode("Default location", in: app)
    XCTAssertTrue(app.staticTexts["Halifax"].exists)
  }

  @MainActor func testDailyAndHourlyForecastToggle() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    dismissLocationPromptForManualForecast()
    let picker = app.segmentedControls["forecastViewPicker"]
    XCTAssertTrue(picker.waitForExistence(timeout: 10))
    let daily = picker.buttons["Daily / Nightly"]
    let hourly = picker.buttons["Hourly · 72h"]
    XCTAssertTrue(daily.isSelected)
    XCTAssertTrue(app.staticTexts["The week ahead"].exists)
    XCTAssertFalse(app.staticTexts["Next 72 hours"].exists)
    XCTAssertGreaterThan(picker.frame.minY, app.buttons["Show on map"].frame.maxY)
    XCTAssertLessThan(picker.frame.maxY, app.staticTexts["The week ahead"].frame.minY)

    hourly.tap()
    XCTAssertTrue(hourly.isSelected)
    XCTAssertTrue(app.staticTexts["Next 72 hours"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["The week ahead"].exists)
    XCTAssertFalse(app.staticTexts["precipitation-Today"].exists)
    XCTAssertTrue(
      app.staticTexts["ECCC GDPS · 71 of 72 complete hours"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts.matching(identifier: "hourlyForecastTime").count, 72)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Hourly forecast toggle"
    screenshot.lifetime = .keepAlways
    add(screenshot)

    daily.tap()
    XCTAssertTrue(daily.isSelected)
    XCTAssertTrue(app.staticTexts["The week ahead"].exists)
    XCTAssertTrue(app.staticTexts["precipitation-Today"].exists)
    XCTAssertFalse(app.staticTexts["Next 72 hours"].exists)
    XCTAssertEqual(app.staticTexts.matching(identifier: "hourlyForecastTime").count, 0)
  }

  @MainActor func testPrecipitationAmountsAppearForWetForecastPeriods() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    XCTAssertTrue(app.staticTexts["precipitation-Today"].waitForExistence(timeout: 10))
    XCTAssertEqual(app.staticTexts["precipitation-Today"].label, "Precipitation: 5 to 10 mm")
    let estimated = app.staticTexts["precipitation-Tonight"]
    let loaded = NSPredicate(format: "label == %@", "Precipitation: 2.4 mm")
    expectation(for: loaded, evaluatedWith: estimated)
    waitForExpectations(timeout: 10)
    for _ in 0..<5 {
      if app.staticTexts["precipitation-Wednesday"].isHittable { break }
      app.swipeUp()
    }
    XCTAssertEqual(
      app.staticTexts["precipitation-Tuesday"].label, "Precipitation: amount unavailable")
    XCTAssertFalse(app.staticTexts["precipitation-Tuesday night"].exists)
    XCTAssertEqual(
      app.staticTexts["precipitation-Wednesday"].label,
      "Precipitation: <0.1 mm")
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Precipitation amounts"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor func testMapFeatureControlsAndNearbyForecast() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "0123456789abcdef",
    ]
    app.launch()
    dismissLocationPromptForManualForecast()
    app.tabBars.buttons["Map"].tap()
    XCTAssertTrue(app.staticTexts["Temperature"].waitForExistence(timeout: 10))
    selectMapData("wind", search: "Wind direction", in: app)
    XCTAssertTrue(
      app.staticTexts["Arrow colour and size show wind speed at 10 m. Tap an arrow for its speed."]
        .waitForExistence(timeout: 5))
    XCTAssertTrue(app.otherElements["windSpeedLegend"].exists)
    let windScreenshot = XCTAttachment(screenshot: app.screenshot())
    windScreenshot.name = "Speed-coloured wind arrows"
    windScreenshot.lifetime = .keepAlways
    add(windScreenshot)
    selectMapData("hotspots", search: "Fire", in: app)
    XCTAssertTrue(app.staticTexts["hotspotAttribution"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["hotspotDatePicker"].exists)
    XCTAssertFalse(app.buttons["mapPlaybackToggle"].exists)
    let featuresScreenshot = XCTAttachment(screenshot: app.screenshot())
    featuresScreenshot.name = "Standalone fire hotspots"
    featuresScreenshot.lifetime = .keepAlways
    add(featuresScreenshot)
    selectMapData("field:air_temperature_2m", search: "Temperature", in: app)
    XCTAssertFalse(app.staticTexts["hotspotAttribution"].exists)
    let ready = expectation(
      for: NSPredicate(format: "label == %@", "0.75 seconds per complete frame"),
      evaluatedWith: app.staticTexts["mapPlaybackStatus"])
    wait(for: [ready], timeout: 15)
    let map = app.maps.firstMatch
    map.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
    XCTAssertTrue(app.navigationBars["At this point"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["nearbyForecast"].waitForExistence(timeout: 5))
    app.buttons["nearbyForecast"].tap()
    XCTAssertTrue(app.navigationBars["Forecast"].waitForExistence(timeout: 5))
  }

  @MainActor func testForecastSearchSavingAndNavigation() {
    let app = XCUIApplication()
    // Run Support/fixture_server.py on the Mac before this UI test.
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-savedPlaces:http://localhost:8097", "",
      "-forecastRegion:http://localhost:8097", "",
    ]
    app.launch()
    allowLocationIfPrompted()
    app.tabBars.buttons["Forecast"].tap()
    XCTAssertTrue(app.staticTexts["Halifax"].waitForExistence(timeout: 15))
    assertForecastLocationMode("Current location", in: app)
    app.buttons["Save or unsave Halifax"].tap()
    app.tabBars.buttons["Saved"].tap()
    XCTAssertTrue(app.staticTexts["Halifax"].waitForExistence(timeout: 5))
    app.staticTexts["Halifax"].tap()
    XCTAssertTrue(app.navigationBars["Forecast"].waitForExistence(timeout: 5))
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Forecast"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.tabBars.buttons["Map"].tap()
    let mapScreenshot = XCTAttachment(screenshot: app.screenshot())
    mapScreenshot.name = "Model map"
    mapScreenshot.lifetime = .keepAlways
    add(mapScreenshot)
    selectMapData("imagery:radar_rain", search: "Rain radar", in: app)
    XCTAssertTrue(app.staticTexts["Rain radar"].waitForExistence(timeout: 10))
    assertNoManualImageRefresh(in: app)
    selectMapData("imagery:satellite_natural", search: "visible", in: app)
    XCTAssertTrue(app.staticTexts["Satellite — visible"].waitForExistence(timeout: 10))
    assertNoManualImageRefresh(in: app)
    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(app.buttons["defaultForecastLocation"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.textFields["serverAddress"].exists)
    XCTAssertFalse(app.buttons["connectServer"].exists)
  }

  @MainActor func testManualRegionOverridesLocationAndCanReturnToGPS() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-weatherAtlasTestServerURL", "http://localhost:8097",
      "-forecastRegion:http://localhost:8097", "",
    ]
    app.launch()
    allowLocationIfPrompted()
    XCTAssertTrue(app.staticTexts["Halifax"].waitForExistence(timeout: 15))
    assertForecastLocationMode("Current location", in: app)
    app.navigationBars.buttons["Choose region"].tap()
    XCTAssertTrue(
      app.buttons.containing(.staticText, identifier: "Sydney").firstMatch.waitForExistence(
        timeout: 10))
    app.buttons.containing(.staticText, identifier: "Sydney").firstMatch.tap()
    assertForecastLocationMode("Chosen location", in: app)
    XCTAssertTrue(app.staticTexts["Sydney"].exists)
    app.buttons["useCurrentLocationForecast"].tap()
    assertForecastLocationMode("Current location", in: app, timeout: 15)
    XCTAssertTrue(app.staticTexts["Halifax"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Current-location forecast"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  @MainActor private func allowLocationIfPrompted() {
    let button = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons[
      "Allow While Using App"]
    if button.waitForExistence(timeout: 4) { button.tap() }
  }

  @MainActor private func openMapData(in app: XCUIApplication) {
    if app.buttons["mapDataPicker"].exists {
      app.buttons["mapDataPicker"].tap()
    } else {
      app.navigationBars.buttons["Map data"].tap()
    }
  }

  @MainActor private func assertNoManualImageRefresh(in app: XCUIApplication) {
    openMapData(in: app)
    let options = app.buttons["Source & display options"]
    XCTAssertTrue(options.waitForExistence(timeout: 5))
    options.tap()
    XCTAssertTrue(app.sliders.firstMatch.exists)
    XCTAssertFalse(app.buttons["Refresh images"].exists)
    XCTAssertFalse(app.buttons["Refresh frames"].exists)
    app.navigationBars.buttons["Done"].tap()
  }

  @MainActor private func selectMapData(_ id: String, search: String, in app: XCUIApplication) {
    openMapData(in: app)
    let field = app.searchFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText(search)
    let option = app.buttons["map-option-\(id)"]
    XCTAssertTrue(option.waitForExistence(timeout: 10))
    option.tap()
    XCTAssertTrue(app.segmentedControls["mapModePicker"].waitForExistence(timeout: 5))
  }
}
