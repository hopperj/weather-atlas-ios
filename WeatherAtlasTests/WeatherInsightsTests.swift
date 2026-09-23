import XCTest

@testable import WeatherAtlas

final class WeatherInsightsTests: XCTestCase {
  func testStationMissingAndTraceAreNotZero() throws {
    let json = """
      {"id":"CAAW","name":"Shearwater","longitude":-63.5,"latitude":44.6,
        "source":"MSC","attribution":"ECCC","stale":false,"observation":{
        "observedAt":"2026-09-08T12:00:00Z","expiresAt":"2026-09-08T14:15:00Z",
        "expectedIntervalMinutes":60,"values":{"temperatureC":13.1,"precipitationMm":null},
        "quality":{"precipitationMm":{"state":"trace","sourceField":"pcpn_amt_pst1hr","unit":"mm"}},
        "intervals":{}}}
      """
    let station = try WeatherAPI.decoder().decode(WeatherStation.self, from: Data(json.utf8))
    XCTAssertNil(station.value(.precipitationMm))
    XCTAssertEqual(station.formatted(.precipitationMm), "Trace")
    XCTAssertEqual(station.value(.temperatureC), 13.1)
    XCTAssertEqual(station.formatted(.gustKmh), "Unavailable")
  }

  func testWidgetCacheIsScopedAndDoesNotAcceptAnOlderResponse() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fresh = try payload(generated: "2026-09-08T12:30:00Z")
    let old = try payload(generated: "2026-09-08T12:00:00Z")
    let server = "http://wolf359.iolan:18080"
    XCTAssertTrue(WidgetDataStore.save(fresh, server: server, directory: directory))
    XCTAssertFalse(WidgetDataStore.save(old, server: server, directory: directory))
    XCTAssertEqual(
      WidgetDataStore.read(server: server, regionID: fresh.regionId, directory: directory)?
        .generatedAt, fresh.generatedAt)
    XCTAssertNil(
      WidgetDataStore.read(
        server: "http://another-server:18080", regionID: fresh.regionId, directory: directory))
    XCTAssertNil(
      WidgetDataStore.read(server: server, regionID: "fedcba9876543210", directory: directory))
  }

  func testWidgetForecastExpiresAndNeverReusesAnOldHourlyEntry() throws {
    let payload = try payload(generated: "2026-09-08T12:00:00Z")
    let noon = try Date.ISO8601FormatStyle().parse("2026-09-08T12:00:00Z")
    XCTAssertEqual(payload.entry(at: noon)?.temperatureC, 20)
    XCTAssertNil(payload.entry(at: noon.addingTimeInterval(3600)))
    XCTAssertNil(payload.entry(at: noon.addingTimeInterval(86400)))
  }

  func testWidgetRedirectPolicyRejectsDowngradesAndOtherOrigins() throws {
    let base = WeatherAtlasEndpoint.productionURL
    XCTAssertTrue(
      WidgetServerPolicy.sameOrigin(base.appendingPathComponent("api/v1/widgets/forecast"), base))
    for other in [
      "http://weatheratlas.ioresearch.ca", "https://weatheratlas.ioresearch.ca:8443",
      "https://example.com", "https://user:password@weatheratlas.ioresearch.ca",
    ] {
      XCTAssertFalse(WidgetServerPolicy.sameOrigin(try XCTUnwrap(URL(string: other)), base))
    }
  }

  func testWidgetsUpgradeLegacySettingsBeforeMakingAnyNetworkRequest() {
    let place = WidgetLocationRecord(id: "0123456789abcdef", name: "Halifax")
    for address in WeatherAtlasEndpoint.legacyAddresses {
      let settings = WidgetSettings(
        server: address, defaultLocation: place, lastLocation: place, saved: [place])
      let migrated = WeatherAtlasEndpoint.widgetSettings(settings)
      XCTAssertEqual(migrated.server, WeatherAtlasEndpoint.productionURL.absoluteString)
      XCTAssertEqual(migrated.defaultLocation, place)
      XCTAssertEqual(migrated.lastLocation, place)
      XCTAssertEqual(migrated.saved, [place])
      XCTAssertEqual(
        WeatherAtlasEndpoint.widgetURL(for: address), WeatherAtlasEndpoint.productionURL)
    }
    let foreign = WeatherAtlasEndpoint.widgetSettings(
      WidgetSettings(
        server: "https://unrelated.example", defaultLocation: place, lastLocation: place,
        saved: [place]))
    XCTAssertEqual(foreign.server, WeatherAtlasEndpoint.productionURL.absoluteString)
    XCTAssertNil(foreign.defaultLocation)
    XCTAssertNil(foreign.lastLocation)
    XCTAssertTrue(foreign.saved.isEmpty)
    XCTAssertNil(WeatherAtlasEndpoint.widgetURL(for: "https://unrelated.example"))
  }

  @MainActor func testLegacyWidgetLinksOpenTheRegionWithoutSwitchingTheEndpoint() throws {
    let suite = "widget-migration-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(configuration: .current, defaults: defaults)
    store.openWidgetURL(
      URL(
        string: "weatheratlas://forecast?region=0123456789abcdef&server=http://wolf359.iolan:18080")!
    )
    XCTAssertEqual(store.selectedRegionID, "0123456789abcdef")
    XCTAssertEqual(store.serverURL, WeatherAtlasEndpoint.productionURL)
    store.openWidgetURL(
      URL(
        string: "weatheratlas://forecast?region=fedcba9876543210&server=https://unrelated.example")!
    )
    XCTAssertEqual(store.selectedRegionID, "0123456789abcdef")
  }

  @MainActor func testWidgetLinkDoesNotChangeDefaultOrConnectToAnotherServer() throws {
    let suite = "widget-tests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let server = URL(string: "http://wolf359.iolan:18080")!
    let store = AppStore(configuration: AppConfiguration(apiBaseURL: server), defaults: defaults)
    store.openWidgetURL(URL(string: "weatheratlas://forecast?region=0123456789abcdef")!)
    XCTAssertEqual(store.selectedRegionID, "0123456789abcdef")
    XCTAssertNil(store.defaultForecastLocation)
    store.openWidgetURL(
      URL(string: "weatheratlas://forecast?region=fedcba9876543210&server=http://elsewhere:18080")!)
    XCTAssertEqual(store.serverURL, server)
    XCTAssertEqual(store.selectedRegionID, "0123456789abcdef")
  }

  @MainActor func testStationSelectionIsStandaloneAndModelTabsSurvive() {
    let model = MapScreenModel(api: WeatherAPI(baseURL: URL(string: "http://localhost:8097")!))
    model.selectOption("stations")
    XCTAssertTrue(model.showStations)
    XCTAssertEqual(model.navigationMode, .models)
    XCTAssertNil(model.rasterFrame)
    XCTAssertEqual(model.frameCount, 0)
    XCTAssertNil(model.playbackTicket)
    model.cancelRequests()
  }

  private func payload(generated: String) throws -> WidgetForecast {
    let json = """
      {"schemaVersion":1,"regionId":"0123456789abcdef","name":"Halifax","source":"ECCC",
        "issuedAt":"2026-09-08T10:00:00Z","generatedAt":"\(generated)",
        "expiresAt":"2026-09-09T10:00:00Z","nextRefreshAt":"2026-09-08T13:00:00Z",
        "entries":[{"date":"2026-09-08T12:00:00Z","validUntil":"2026-09-08T13:00:00Z",
        "temperatureC":20,"highC":23,"lowC":12,"condition":"Sunny","symbol":"sun.max.fill",
        "popPercent":0,"precipitationMm":0,"hours":[]}]}
      """
    return try WidgetDataStore.decoder().decode(WidgetForecast.self, from: Data(json.utf8))
  }
}
