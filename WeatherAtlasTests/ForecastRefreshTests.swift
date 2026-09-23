import XCTest

@testable import WeatherAtlas

final class ForecastRefreshTests: XCTestCase {
  func testGPSCannotCancelFirstBulletinButCanReplaceItOnceVisibleOrFailed() {
    let now = Date()
    let fix = ForecastLocationFix(latitude: 46, longitude: -60, measuredAt: now)
    for (hasBulletin, failed, accepted) in [
      (false, false, false), (true, false, true), (false, true, true),
    ] {
      XCTAssertEqual(
        ForecastRefreshPolicy.locationForRequest(
          fix: fix, followsLocation: true, hasBulletin: hasBulletin,
          initialRequestFailed: failed, now: now), accepted ? fix : nil)
    }
    XCTAssertNil(
      ForecastRefreshPolicy.locationForRequest(
        fix: fix, followsLocation: false, hasBulletin: true, initialRequestFailed: false, now: now))
    XCTAssertNil(
      ForecastRefreshPolicy.locationForRequest(
        fix: fix, followsLocation: true, hasBulletin: true, initialRequestFailed: false,
        now: now.addingTimeInterval(301)))
  }
  private var suites: [String] = []
  override func tearDown() {
    for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
    super.tearDown()
  }
  @MainActor private func store(_ defaults: UserDefaults, host: String = "weather.test")
    -> ForecastSnapshotStore
  {
    ForecastSnapshotStore(serverURL: URL(string: "https://\(host)")!, defaults: defaults)
  }
  private func region(_ id: String = "chosen", name: String = "Halifax Metro", now: Date = Date())
    -> ForecastRegion
  {
    ForecastRegion(
      id: id, name: name, latitude: 44.65, longitude: -63.57,
      province: "NS", provinceName: "Nova Scotia", issuedAt: now.addingTimeInterval(-600),
      stale: false,
      periods: [
        ForecastPeriod(
          name: "Today", start: now, end: now.addingTimeInterval(86400),
          temperatureC: 20, temperatureClass: "high", relativeHumidityPercent: 70, popPercent: 0,
          precipitationAmount: nil, condition: "Sunny")
      ])
  }
  private func snapshot(
    selection: String = "chosen", regionID: String = "chosen", now: Date = Date()
  ) -> ForecastSnapshot {
    ForecastSnapshot(
      storedAt: now, selectionID: selection, region: region(regionID, now: now),
      hourly: HourlyForecast(
        regionId: regionID, source: "Test", generatedAt: now,
        start: now, end: now.addingTimeInterval(72 * 3600), availableHours: 0, completeHours: 0,
        hours: []),
      precipitation: nil, usingDefaultLocation: false, lastUpdated: now)
  }
  private func defaults() -> UserDefaults {
    let name = "ForecastRefreshTests-\(UUID().uuidString)"
    suites.append(name)
    return UserDefaults(suiteName: name)!
  }

  @MainActor func testDefaultStartsAsHalifaxAndPersistsPerServerWithoutChangingManualChoice() {
    let defaults = defaults()
    let app = AppStore(configuration: .current, defaults: defaults)
    let firstURL = app.serverURL
    XCTAssertNil(app.defaultForecastLocation)
    XCTAssertEqual(app.defaultForecastName, "Halifax")
    app.selectForecastRegion("manual")
    app.setDefaultForecastLocation(region("sydney", name: "Sydney"))
    XCTAssertEqual(app.defaultForecastName, "Sydney")
    XCTAssertEqual(app.selectedRegionID, "manual")
    let relaunched = AppStore(configuration: .current, defaults: defaults)
    XCTAssertEqual(relaunched.defaultForecastLocation?.id, "sydney")
    XCTAssertEqual(relaunched.selectedRegionID, "manual")
    relaunched.connect(to: URL(string: "http://another.iolan:18080")!)
    XCTAssertEqual(relaunched.defaultForecastName, "Halifax")
    relaunched.connect(to: firstURL)
    XCTAssertEqual(relaunched.defaultForecastName, "Sydney")
    relaunched.setDefaultForecastLocation(nil)
    XCTAssertEqual(
      AppStore(configuration: .current, defaults: defaults).defaultForecastName, "Halifax")
  }

  @MainActor func testAutomaticSnapshotsCannotRestoreADifferentConfiguredDefault() {
    let cache = store(defaults())
    cache.save(snapshot(selection: ""))
    XCTAssertNotNil(cache.read(selectionID: ""))
    XCTAssertNil(cache.read(selectionID: "", defaultLocationID: "sydney"))
    var updated = snapshot(selection: "", regionID: "sydney")
    updated.defaultLocationID = "sydney"
    cache.save(updated)
    XCTAssertNotNil(cache.read(selectionID: "", defaultLocationID: "sydney"))
    XCTAssertNil(cache.read(selectionID: ""))
  }

  @MainActor func testChangingDefaultImmediatelyClearsOldAutomaticSnapshot() {
    let defaults = defaults()
    let url = URL(string: "https://weather.test")!
    store(defaults).save(snapshot(selection: ""))
    let app = AppStore(configuration: AppConfiguration(apiBaseURL: url), defaults: defaults)
    XCTAssertNotNil(app.forecast.region)
    app.setDefaultForecastLocation(region("sydney", name: "Sydney"))
    XCTAssertNil(app.forecast.region)
    XCTAssertTrue(app.followsCurrentLocation)
    XCTAssertEqual(app.defaultForecastLocation?.id, "sydney")
  }

  func testForecastRefreshChecksNetworkButDoesNotDisableMapHTTPCache() async throws {
    struct Echo: Decodable, Sendable { let policy: UInt }
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ForecastPolicyProbe.self]
    let api = WeatherAPI(
      baseURL: URL(string: "https://weather.test")!, session: URLSession(configuration: config))
    for path in [
      "/api/v1/forecast/regions", "/api/v1/forecast/nearest", "/api/v1/forecast/hourly",
      "/api/v1/forecast/precipitation",
    ] {
      let result: Echo = try await api.get(path)
      XCTAssertEqual(result.policy, URLRequest.CachePolicy.reloadIgnoringLocalCacheData.rawValue)
    }
    let catalogue: Echo = try await api.get("/api/v1/products")
    XCTAssertEqual(catalogue.policy, URLRequest.CachePolicy.useProtocolCachePolicy.rawValue)
  }

  @MainActor func testSavedForecastRestoresSynchronouslyWithoutAnyAPIOrLocationCall() async {
    let cache = store(defaults())
    cache.save(snapshot())
    let api = ForecastTestServer(holdRegions: true)
    let model = ForecastModel(api: api, cache: cache)
    model.restore(preferredID: "chosen")
    XCTAssertEqual(model.region?.periods.first?.temperatureC, 20)
    XCTAssertEqual(model.hourly?.regionId, "chosen")
    XCTAssertTrue(model.showingSavedData)
    let calls = await api.calls
    XCTAssertTrue(calls.isEmpty)
  }

  @MainActor func testSlowRefreshKeepsPreviousDailyAndHourlyDataOnScreen() async {
    let cache = store(defaults())
    cache.save(snapshot())
    let api = ForecastTestServer(holdRegions: true)
    let model = ForecastModel(api: api, cache: cache)
    model.restore(preferredID: "chosen")
    let previousTime = model.lastUpdated
    let loading = Task { await model.load(preferredID: "chosen", location: nil) }
    await api.waitForRegions()
    XCTAssertTrue(model.loading)
    XCTAssertEqual(model.region?.periods.first?.temperatureC, 20)
    XCTAssertEqual(model.hourly?.regionId, "chosen")
    XCTAssertEqual(model.lastUpdated, previousTime)
    await api.releaseRegions()
    await loading.value
    XCTAssertFalse(model.loading)
    XCTAssertFalse(model.showingSavedData)
    XCTAssertNotNil(model.lastUpdated)
  }

  @MainActor func testAutomaticStartupRefreshesLastRegionWhileGPSIsPending() async {
    let cache = store(defaults())
    cache.save(snapshot(selection: ""))
    let api = ForecastTestServer()
    let model = ForecastModel(api: api, cache: cache)
    model.restore(preferredID: "")
    XCTAssertTrue(model.usingLastLocation)
    await model.load(preferredID: "", location: nil)
    XCTAssertEqual(model.region?.id, "chosen")
    XCTAssertTrue(model.usingLastLocation)
    XCTAssertFalse(model.usingDefaultLocation)
    let calls = await api.calls
    XCTAssertEqual(calls, ["regions", "hourly:chosen"])
    await model.load(
      preferredID: "",
      location: ForecastLocationFix(latitude: 45, longitude: -63, measuredAt: Date()))
    XCTAssertEqual(model.region?.id, "nearby")
    XCTAssertEqual(model.hourly?.regionId, "nearby")
    XCTAssertFalse(model.usingLastLocation)
  }

  @MainActor func testFailedLocationRefreshRetainsAndLabelsPreviousRegion() async {
    let cache = store(defaults())
    cache.save(snapshot(selection: ""))
    let model = ForecastModel(
      api: ForecastTestServer(nearestError: .server(status: 404, message: "Outside coverage")),
      cache: cache)
    await model.load(
      preferredID: "", location: ForecastLocationFix(latitude: 0, longitude: 0, measuredAt: Date()))
    XCTAssertEqual(model.region?.id, "chosen")
    XCTAssertEqual(model.hourly?.regionId, "chosen")
    XCTAssertTrue(model.usingLastLocation)
    XCTAssertTrue(model.showingSavedData)
    XCTAssertTrue(model.refreshIncomplete)
    XCTAssertTrue(model.error?.contains("previous region") == true)
  }

  @MainActor func testChangingSelectionInvalidatesLateResponsesBeforeNextLoadStarts() async {
    let api = ForecastTestServer(holdNearest: true)
    let model = ForecastModel(api: api)
    let pending = Task {
      await model.load(
        preferredID: "",
        location: ForecastLocationFix(latitude: 45, longitude: -63, measuredAt: Date()))
    }
    await api.waitForNearest()
    model.restore(preferredID: "chosen")
    await api.releaseNearest()
    await pending.value
    XCTAssertNil(model.region)
    let calls = await api.calls
    XCTAssertFalse(calls.contains("hourly:nearby"))
  }

  @MainActor func testCacheSeparatesServersManualRegionsAndAutomaticChoice() {
    let defaults = defaults()
    let cache = store(defaults)
    cache.save(snapshot(selection: ""))
    cache.save(snapshot())
    XCTAssertNotNil(cache.read(selectionID: ""))
    XCTAssertNotNil(cache.read(selectionID: "chosen"))
    XCTAssertNil(cache.read(selectionID: "other"))
    XCTAssertNil(store(defaults, host: "another.test").read(selectionID: "chosen"))
    cache.save(snapshot(selection: "other", regionID: "other"))
    XCTAssertNil(cache.read(selectionID: "chosen"), "Only the latest manual choice is kept")
    XCTAssertNotNil(cache.read(selectionID: ""))
  }

  @MainActor func testExpiredCorruptAndMismatchedSnapshotsAreIgnored() {
    let defaults = defaults()
    let cache = store(defaults)
    let now = Date()
    cache.save(snapshot(now: now.addingTimeInterval(-25 * 3600)))
    XCTAssertNil(cache.read(selectionID: "chosen", now: now))
    cache.save(snapshot(selection: "chosen", regionID: "other"))
    XCTAssertNil(cache.read(selectionID: "chosen"))
    defaults.set(
      Data("invalid json".utf8), forKey: "forecastSnapshot:v1:https://weather.test:manual")
    XCTAssertNil(cache.read(selectionID: "chosen"))
  }

  @MainActor func testNewAppStoreHasCachedForecastBeforeViewOrTaskStarts() {
    let defaults = defaults()
    let url = URL(string: "https://weather.test")!
    store(defaults).save(snapshot(selection: ""))
    let app = AppStore(configuration: AppConfiguration(apiBaseURL: url), defaults: defaults)
    XCTAssertEqual(app.forecast.region?.id, "chosen")
    XCTAssertTrue(app.forecast.showingSavedData)
    XCTAssertEqual(app.selectedRegionID, "", "Cached location must not become a manual override")
  }

  @MainActor
  func testStoppingLocationKeepsVisibleForecastAndPersistsItWithoutLoadingOldManualCache() {
    let defaults = defaults()
    let configuration = AppConfiguration(apiBaseURL: URL(string: "https://weather.test")!)
    let cache = store(defaults)
    let automatic = snapshot(selection: "", regionID: "current")
    cache.save(automatic)
    cache.save(snapshot(selection: "previous", regionID: "previous"))
    let app = AppStore(configuration: configuration, defaults: defaults)
    XCTAssertTrue(app.followsCurrentLocation)
    app.stopUsingCurrentLocationForForecast()
    XCTAssertFalse(app.followsCurrentLocation)
    XCTAssertEqual(app.selectedRegionID, "current")
    XCTAssertEqual(app.forecast.region, automatic.region)
    XCTAssertEqual(app.forecast.hourly?.regionId, automatic.hourly?.regionId)
    XCTAssertEqual(app.forecast.hourly?.generatedAt, automatic.hourly?.generatedAt)
    XCTAssertEqual(app.forecast.lastUpdated, automatic.lastUpdated)
    XCTAssertFalse(app.forecast.usingLastLocation)
    XCTAssertFalse(app.forecast.usingDefaultLocation)
    XCTAssertEqual(cache.read(selectionID: "current")?.region, automatic.region)
    let restored = AppStore(configuration: configuration, defaults: defaults)
    XCTAssertFalse(restored.followsCurrentLocation)
    XCTAssertEqual(restored.forecast.region, automatic.region)
    XCTAssertEqual(restored.defaultForecastName, "Halifax")
    restored.useCurrentLocationForForecast()
    XCTAssertTrue(restored.followsCurrentLocation)
  }

  @MainActor func testStoppingLocationRejectsLateCoordinatesWithoutBlankingTheForecast() async {
    let cache = store(defaults())
    cache.save(snapshot(selection: ""))
    let api = ForecastTestServer(holdNearest: true)
    let model = ForecastModel(api: api, cache: cache)
    model.restore(preferredID: "")
    let current = model.region
    let pending = Task {
      await model.load(
        preferredID: "", location: .init(latitude: 46, longitude: -60, measuredAt: Date()))
    }
    await api.waitForNearest()
    XCTAssertEqual(model.holdCurrentRegion(), "chosen")
    XCTAssertEqual(model.region, current)
    await api.releaseNearest()
    await pending.value
    XCTAssertEqual(model.region, current)
    XCTAssertEqual(model.hourly?.regionId, "chosen")
    let calls = await api.calls
    XCTAssertFalse(calls.contains("hourly:nearby"))
    await model.load(preferredID: "chosen", location: nil)
    XCTAssertEqual(model.region?.id, "chosen")
    XCTAssertFalse(model.usingDefaultLocation)
  }

  @MainActor func testStoppingBeforeFirstForecastPersistsOffPerServerAndCanResumeOrChoose() {
    let defaults = defaults()
    let configuration = AppConfiguration(apiBaseURL: URL(string: "https://weather.test")!)
    let app = AppStore(configuration: configuration, defaults: defaults)
    XCTAssertNil(app.forecast.region)
    app.stopUsingCurrentLocationForForecast()
    XCTAssertFalse(app.followsCurrentLocation)
    XCTAssertEqual(app.selectedRegionID, "")
    let restored = AppStore(configuration: configuration, defaults: defaults)
    XCTAssertFalse(restored.followsCurrentLocation)
    XCTAssertNil(restored.forecast.region)
    restored.connect(to: URL(string: "http://another.iolan:18080")!)
    XCTAssertTrue(restored.followsCurrentLocation)
    restored.connect(to: configuration.apiBaseURL)
    XCTAssertFalse(restored.followsCurrentLocation)
    restored.setDefaultForecastLocation(region("sydney", name: "Sydney"))
    XCTAssertFalse(restored.followsCurrentLocation)
    XCTAssertNil(restored.forecast.region)
    restored.selectForecastRegion("sydney")
    XCTAssertFalse(restored.followsCurrentLocation)
    XCTAssertEqual(restored.selectedRegionID, "sydney")
    restored.useCurrentLocationForForecast()
    XCTAssertTrue(restored.followsCurrentLocation)
    XCTAssertTrue(AppStore(configuration: configuration, defaults: defaults).followsCurrentLocation)
  }

  @MainActor func testFiveMinuteRefreshContinuesAcrossTabChangesWithoutLocationDependency() async {
    let app = AppStore(configuration: .current, defaults: defaults())
    var intervals: [Duration] = []
    var ticks = 0
    await ForecastRefreshPolicy.run(
      active: true,
      sleep: { duration in
        intervals.append(duration)
        if intervals.count == 3 { throw CancellationError() }
      },
      refresh: {
        app.selectedTab = ticks == 0 ? 0 : 2
        app.refreshForecast()
        ticks += 1
      })
    XCTAssertEqual(intervals, [.seconds(300), .seconds(300), .seconds(300)])
    XCTAssertEqual(app.forecastRefresh, 2)
    XCTAssertEqual(app.selectedTab, 2)
  }

  @MainActor func testInactiveAppDoesNotStartPeriodicWork() async {
    var calls = 0
    await ForecastRefreshPolicy.run(
      active: false,
      sleep: { _ in
        XCTFail("No periodic wait should start in the background")
      }, refresh: { calls += 1 })
    XCTAssertEqual(calls, 0)
  }

  @MainActor func testCancelledPeriodicWaitDoesNotTriggerAnExtraRefresh() async {
    var sleeping = false
    var refreshed = false
    let task = Task {
      await ForecastRefreshPolicy.run(
        active: true,
        sleep: { _ in
          sleeping = true
          try await Task.sleep(for: .seconds(30))
        }, refresh: { refreshed = true })
    }
    while !sleeping { await Task.yield() }
    task.cancel()
    await task.value
    XCTAssertFalse(refreshed)
  }
}

private final class ForecastPolicyProbe: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data("{\"policy\":\(request.cachePolicy.rawValue)}".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
