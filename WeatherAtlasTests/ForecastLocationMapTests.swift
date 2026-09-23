import MapKit
import XCTest

@testable import WeatherAtlas

final class ForecastLocationMapTests: XCTestCase {
  private func region(_ name: String) -> ForecastRegion {
    ForecastRegion(
      id: name, name: name, latitude: 44.65, longitude: -63.57,
      province: "NS", provinceName: "Nova Scotia", issuedAt: Date(), stale: false, periods: [])
  }

  @MainActor private func waitUntil(_ predicate: () async -> Bool) async throws {
    for _ in 0..<200 {
      if await predicate() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Map selection did not reach the expected state")
  }

  @MainActor func testCitiesComeFromServerAndSearchTownOrProvince() async {
    let server = PinTestServer(regions: [region("Sydney"), region("Halifax")])
    let model = ForecastLocationMapModel(region: region("Halifax"), pin: nil, api: server)
    await model.loadCities()
    XCTAssertEqual(model.cities(matching: " SYDNEY ").map(\.id), ["Sydney"])
    XCTAssertEqual(model.cities(matching: "Nova Scotia").map(\.id), ["Halifax", "Sydney"])
    XCTAssertTrue(model.cities(matching: "unknown").isEmpty)
    XCTAssertNil(model.confirmedPin)
  }

  @MainActor func testPinUsesServerResultNotLocalDistanceAndRetainsExactPoint() async throws {
    let server = PinTestServer(regions: [])
    let model = ForecastLocationMapModel(region: region("Halifax"), pin: nil, api: server)
    model.dropPin(at: .init(latitude: 44.7, longitude: -63.6))
    XCTAssertNil(model.selected)
    XCTAssertTrue(model.lookingUp)
    try await waitUntil { await server.pendingCount == 1 }
    await server.complete(latitude: 44.7, result: .success(region("Sydney")))
    try await waitUntil { !model.lookingUp }
    XCTAssertEqual(model.selected?.id, "Sydney")
    XCTAssertEqual(
      model.confirmedPin, ForecastMapPin(regionID: "Sydney", latitude: 44.7, longitude: -63.6))
  }

  @MainActor func testLatePinCannotReplaceNewerPinOrCityOrCancelledSelection() async throws {
    for action in ["pin", "city", "cancel"] {
      let server = PinTestServer(regions: [])
      let model = ForecastLocationMapModel(region: region("Halifax"), pin: nil, api: server)
      model.dropPin(at: .init(latitude: 44, longitude: -63))
      try await waitUntil { await server.pendingCount == 1 }
      if action == "pin" {
        model.dropPin(at: .init(latitude: 46, longitude: -60))
        try await waitUntil { await server.pendingCount == 2 }
        await server.complete(latitude: 46, result: .success(region("Sydney")))
        try await waitUntil { !model.lookingUp }
      } else if action == "city" {
        model.choose(region("Sydney"))
      } else {
        model.cancel()
      }
      await server.complete(latitude: 44, result: .success(region("Old response")))
      try await Task.sleep(for: .milliseconds(20))
      XCTAssertEqual(model.selected?.id, action == "cancel" ? nil : "Sydney")
      XCTAssertFalse(model.lookingUp)
      if action == "city" { XCTAssertNil(model.pin) }
    }
  }

  @MainActor func testFailedPinCannotConfirmPreviousRegionAndCanRetry() async throws {
    let server = PinTestServer(regions: [])
    let model = ForecastLocationMapModel(region: region("Halifax"), pin: nil, api: server)
    for error in [
      WeatherAPIError.server(status: 404, message: "No nearby forecast"),
      .server(status: 500, message: "Unavailable"),
    ] {
      model.dropPin(at: .init(latitude: 45, longitude: -63))
      try await waitUntil { await server.pendingCount == 1 }
      await server.complete(latitude: 45, result: .failure(error))
      try await waitUntil { !model.lookingUp }
      XCTAssertNil(model.selected)
      XCTAssertNil(model.confirmedPin)
      XCTAssertNotNil(model.error)
    }
    model.dropPin(at: .init(latitude: 45, longitude: -63))
    try await waitUntil { await server.pendingCount == 1 }
    await server.complete(latitude: 45, result: .success(region("Halifax")))
    try await waitUntil { !model.lookingUp }
    XCTAssertNil(model.error)
    XCTAssertEqual(model.selected?.id, "Halifax")
  }

  @MainActor func testExplicitPinPersistsPerServerAndCityOrGPSClearsIt() {
    let name = "ForecastMapPinTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let configuration = AppConfiguration(apiBaseURL: URL(string: "http://weather.test:18080")!)
    let app = AppStore(configuration: configuration, defaults: defaults)
    let pin = ForecastMapPin(regionID: "Halifax", latitude: 44.7, longitude: -63.6)
    app.selectForecastRegion("Halifax", pin: pin)
    XCTAssertFalse(app.followsCurrentLocation)
    XCTAssertEqual(AppStore(configuration: configuration, defaults: defaults).forecastMapPin, pin)
    app.connect(to: URL(string: "http://other.test:18080")!)
    XCTAssertNil(app.forecastMapPin)
    app.connect(to: configuration.apiBaseURL)
    XCTAssertEqual(app.forecastMapPin, pin)
    app.selectForecastRegion("Sydney")
    XCTAssertNil(app.forecastMapPin)
    app.selectForecastRegion("Halifax", pin: pin)
    app.useCurrentLocationForForecast()
    XCTAssertNil(app.forecastMapPin)
    XCTAssertNil(AppStore(configuration: configuration, defaults: defaults).forecastMapPin)
  }

  @MainActor func testInvalidOrMismatchedPinsAreNotRestored() {
    let initial = region("Halifax")
    for pin in [
      ForecastMapPin(regionID: "Sydney", latitude: 44, longitude: -63),
      ForecastMapPin(regionID: "Halifax", latitude: 100, longitude: -63),
    ] {
      let model = ForecastLocationMapModel(
        region: initial, pin: pin, api: PinTestServer(regions: []))
      XCTAssertNil(model.pin)
      XCTAssertEqual(model.focus.latitude, initial.latitude)
    }
  }

  @MainActor func testLocationSurfaceOnlyAddsCityAndPinAnnotationsNeverWeatherOverlays() {
    let initial = region("Halifax")
    var chosen: String?
    let surface = ForecastLocationMapSurface(
      regions: [initial], selectedID: initial.id,
      pin: .init(latitude: 44.7, longitude: -63.6), focus: initial.coordinate, focusRevision: 0,
      onDropPin: { _ in }, onSelectCity: { chosen = $0.id })
    let map = MKMapView(frame: .init(x: 0, y: 0, width: 400, height: 600))
    let coordinator = surface.makeCoordinator()
    coordinator.update(map)
    XCTAssertTrue(map.overlays.isEmpty)
    XCTAssertEqual(map.annotations.count, 2)
    let annotation = ForecastLocationMapSurface.CityAnnotation(initial)
    coordinator.mapView(
      map, didSelect: MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil))
    XCTAssertEqual(chosen, initial.id)
    XCTAssertTrue(map.overlays.isEmpty)
  }
}

private actor PinTestServer: ForecastLocationMapServing {
  let regions: [ForecastRegion]
  var pending: [Double: CheckedContinuation<NearbyForecast, Error>] = [:]
  var pendingCount: Int { pending.count }
  init(regions: [ForecastRegion]) { self.regions = regions }
  func forecastRegions() async throws -> ForecastRegionsResponse {
    ForecastRegionsResponse(generatedAt: Date(), timeZone: "America/Halifax", regions: regions)
  }
  func nearestForecast(longitude: Double, latitude: Double) async throws -> NearbyForecast {
    try await withCheckedThrowingContinuation { pending[latitude] = $0 }
  }
  func complete(latitude: Double, result: Result<ForecastRegion, Error>) {
    pending.removeValue(forKey: latitude)?.resume(
      with: result.map {
        NearbyForecast(region: $0, distanceKm: 2.5, matchKind: "nearest_representative_point")
      })
  }
}
