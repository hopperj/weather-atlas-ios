import MapKit
import XCTest

@testable import WeatherAtlas

final class MapPlaybackTests: XCTestCase {
  func testMapCatalogueExcludesResearchAndCustomProductsIncludingSharedFields() throws {
    let standardCodes = ["hrdps", "rdps", "gdps", "raqdps", "hrdpa", "rdpa", "hrepa"]
    let researchCodes = ["flexpart_smoke", "custom_run_123", "experimental_forecast"]
    let products = (researchCodes + standardCodes).enumerated().map { index, code in
      Product(
        code: code, name: code, description: nil, kind: "forecast", priority: index,
        latestRunTime: Date())
    }
    func field(_ code: String) -> WeatherField {
      WeatherField(
        code: code, variableCode: code, name: code, variableClass: "test",
        levelCode: "surface", levelName: "Surface", unit: "test", palette: [], defaultMin: 0,
        defaultMax: 1)
    }
    let shared = ["air_temperature_2m", "wind_u_10m", "wind_v_10m"].map(field)
    let fields = Dictionary(
      uniqueKeysWithValues: products.map { product in
        (
          product.code,
          shared + (researchCodes.contains(product.code) ? [field("wildfire_pm25_surface")] : [])
        )
      })
    let options = MapDataOption.catalogue(products: products, fields: fields, imagery: [])
    XCTAssertFalse(options.contains { $0.id == "field:wildfire_pm25_surface" })
    for id in ["field:air_temperature_2m", "wind"] {
      let option = try XCTUnwrap(options.first { $0.id == id })
      XCTAssertEqual(option.sources.map(\.id), standardCodes)
    }
    XCTAssertTrue(options.flatMap(\.sources).allSatisfy { standardCodes.contains($0.id) })

    let researchOnly = MapDataOption.catalogue(
      products: products.filter { researchCodes.contains($0.code) }, fields: fields, imagery: [])
    XCTAssertFalse(researchOnly.contains { $0.kind == .field || $0.kind == .wind })
    XCTAssertEqual(researchOnly.first?.id, "none")
  }

  @MainActor func testResearchProductsCannotLoadAsDefaultOrBeSelectedAsSources() async throws {
    // The fixture puts research products first and gives them the same forecast kind.
    let model = try await selectionModel()
    XCTAssertEqual(model.products.map(\.code), ["hrdps", "gdps"])
    XCTAssertEqual(Set(model.fieldCatalogues.keys), ["hrdps", "gdps"])
    XCTAssertEqual(model.selectedProductCode, "hrdps")
    let originalOption = model.selectedOptionID
    for code in ["flexpart_smoke", "custom_run_123"] {
      model.selectSource(code)
      XCTAssertEqual(model.selectedProductCode, "hrdps")
    }
    model.selectOption("field:wildfire_pm25_surface")
    XCTAssertEqual(model.selectedOptionID, originalOption)
    XCTAssertEqual(model.selectedProductCode, "hrdps")
  }

  func testMapOptionsUseCommonNamesDeduplicateSourcesAndPreserveScientificDifferences() throws {
    let products = ["gdps", "hrdps"].enumerated().map { index, code in
      Product(
        code: code, name: code, description: nil, kind: "forecast", priority: 2 - index,
        latestRunTime: Date())
    }
    func field(_ code: String) -> WeatherField {
      WeatherField(
        code: code, variableCode: code, name: code, variableClass: "test",
        levelCode: "surface", levelName: "Surface", unit: "mm", palette: [], defaultMin: 0,
        defaultMax: 1)
    }
    let fields = [
      "air_temperature_2m", "relative_humidity_2m", "wind_u_10m", "wind_v_10m",
      "total_precipitation_1h", "total_precipitation_3h", "precipitation_6h_preliminary",
      "precipitation_6h_final", "wildfire_pm25_surface", "pm25_surface",
    ].map(field)
    let options = MapDataOption.catalogue(
      products: products,
      fields: ["hrdps": fields, "gdps": fields], imagery: [])
    XCTAssertEqual(options.first?.title, "None")
    XCTAssertEqual(options.map(\.rank), options.map(\.rank).sorted())
    let temperature = try XCTUnwrap(options.first { $0.id == "field:air_temperature_2m" })
    XCTAssertEqual(temperature.sources.map(\.id), ["hrdps", "gdps"])
    XCTAssertEqual(options.filter { $0.id == temperature.id }.count, 1)
    XCTAssertEqual(options.first { $0.id == "wind" }?.title, "Wind direction")
    XCTAssertNotEqual(
      field("total_precipitation_1h").mapLabel.0, field("total_precipitation_3h").mapLabel.0)
    XCTAssertNotEqual(
      field("precipitation_6h_final").mapLabel.0, field("precipitation_6h_preliminary").mapLabel.0)
    XCTAssertNotEqual(field("pm25_surface").mapLabel.0, field("wildfire_pm25_surface").mapLabel.0)
    XCTAssertEqual(temperature.sources.first?.label, "ECCC · HRDPS")
  }

  @MainActor private func selectionModel() async throws -> MapScreenModel {
    let model = MapScreenModel(api: testAPI())
    await model.load()
    await model.loadSelectionCatalogues()
    try await waitFor { model.rasterFrame != nil }
    return model
  }

  func testNoneIsFirstAndAvailableWithoutAnyServerCatalogue() {
    let options = MapDataOption.catalogue(products: [], fields: [:], imagery: [])
    XCTAssertEqual(options.first?.id, "none")
    XCTAssertEqual(options.first?.kind, MapDataOption.Kind.none)
    XCTAssertTrue(options.first?.sources.isEmpty == true)
    XCTAssertEqual(options.filter { $0.id == "none" }.count, 1)
  }

  @MainActor func testNoneClearsDisplayedWeatherPlaybackAndSamplingAndCanRestoreData() async throws
  {
    let model = try await selectionModel()
    model.frameStateChanged(id: model.requestedFrameID, state: .displayed)
    model.playing = true
    let oldID = model.requestedFrameID
    let oldTicket = try XCTUnwrap(model.playbackTicket)
    model.sampleCoordinate = .init(latitude: 44, longitude: -63)
    model.selectOption("none")
    XCTAssertTrue(model.showsNoOverlay)
    XCTAssertEqual(model.title, "None")
    XCTAssertEqual(model.navigationMode, .models)
    XCTAssertFalse(model.playing)
    XCTAssertNil(model.playbackTicket)
    XCTAssertNil(model.displayedFrame)
    XCTAssertNil(model.rasterFrame)
    XCTAssertTrue(model.rasterLayers.isEmpty)
    XCTAssertTrue(model.resolved.isEmpty)
    XCTAssertEqual(model.frameCount, 0)
    XCTAssertNil(model.bounds)
    XCTAssertNil(model.sampleCoordinate)
    XCTAssertTrue(model.selectedFieldCodes.isEmpty)
    model.frameStateChanged(id: oldID, state: .displayed)
    XCTAssertFalse(model.advancePlayback(ticket: oldTicket))
    model.sample(at: .init(latitude: 44, longitude: -63))
    model.reload()
    model.resolve()
    model.retry()
    XCTAssertFalse(model.isLoading)
    XCTAssertNil(model.sampleCoordinate)
    XCTAssertNil(model.displayedFrame)
    model.selectOption("field:relative_humidity_2m")
    try await waitFor { model.rasterFrame != nil }
    XCTAssertFalse(model.showsNoOverlay)
    XCTAssertEqual(model.rasterLayers.count, 1)
  }

  @MainActor func testNoneSurvivesInitialCataloguesAndAnImageryRoundTrip() async throws {
    let model = MapScreenModel(api: testAPI())
    model.selectOption("none")
    await model.load()
    await model.loadSelectionCatalogues()
    XCTAssertTrue(model.showsNoOverlay)
    XCTAssertNil(model.rasterFrame)
    XCTAssertFalse(model.isLoading)
    model.selectMode(.radar)
    XCTAssertNotNil(model.rasterFrame)
    model.selectMode(.models)
    XCTAssertTrue(model.showsNoOverlay)
    model.selectOption("field:air_temperature_2m")
    try await waitFor { model.rasterFrame != nil }
  }

  @MainActor func testNoneClearsAllOverlayKindsAndRejectsLateRequests() async throws {
    let model = try await selectionModel()
    for id in [
      "wind", "hotspots", "imagery:radar", "imagery:satellite_natural", "stations",
      "field:relative_humidity_2m",
    ] {
      model.selectOption(id)
      if id == "wind" { try await waitFor { !model.windPoints.isEmpty } }
      // Clear the other selections while requests may still be in flight.
      model.selectOption("none")
      try await Task.sleep(for: .milliseconds(350))
      XCTAssertTrue(model.showsNoOverlay)
      XCTAssertNil(model.rasterFrame)
      XCTAssertTrue(model.windPoints.isEmpty)
      XCTAssertTrue(model.hotspotPoints.isEmpty)
      XCTAssertTrue(model.stationPoints.isEmpty)
      XCTAssertFalse(model.isLoading || model.windLoading || model.hotspotLoading)
      XCTAssertNil(model.errorMessage)
      XCTAssertNil(model.featureError)
    }
  }

  @MainActor private func waitFor(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !predicate() && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(predicate(), "Map request did not finish")
  }

  @MainActor func testTopLevelModesRestoreTheSelectedModelQuantityAndSource() async throws {
    let model = try await selectionModel()
    model.selectOption("field:relative_humidity_2m")
    model.selectSource("gdps")
    try await waitFor { model.rasterFrame != nil }
    model.frameStateChanged(id: model.requestedFrameID, state: .displayed)
    model.playing = true

    model.selectMode(.radar)
    XCTAssertEqual(model.navigationMode, .radar)
    XCTAssertEqual(model.selectedOptionID, "imagery:radar")
    XCTAssertFalse(model.playing)
    XCTAssertNil(model.displayedFrame)
    XCTAssertTrue(model.resolved.isEmpty)
    let radarID = model.requestedFrameID
    model.selectMode(.radar)
    XCTAssertEqual(model.requestedFrameID, radarID, "Tapping the current mode is a no-op")

    model.selectMode(.satellite)
    XCTAssertEqual(model.selectedOptionID, "imagery:satellite_natural")
    model.selectOption("imagery:satellite_ir")
    model.selectMode(.radar)
    model.selectMode(.satellite)
    XCTAssertEqual(model.selectedOptionID, "imagery:satellite_ir")

    model.selectMode(.models)
    try await waitFor { model.rasterFrame != nil }
    XCTAssertEqual(model.navigationMode, .models)
    XCTAssertEqual(model.selectedFieldCode, "relative_humidity_2m")
    XCTAssertEqual(model.selectedProductCode, "gdps")
    XCTAssertEqual(model.rasterLayers.count, 1)
  }

  @MainActor func testModeSelectedBeforeCataloguesArriveLoadsAndCanReturnToModel() async throws {
    let model = MapScreenModel(api: testAPI())
    model.selectMode(.radar)
    XCTAssertEqual(model.navigationMode, .radar)
    XCTAssertEqual(model.frameCount, 0)
    await model.load()
    XCTAssertEqual(model.mode, .radar)
    XCTAssertEqual(model.selectedOptionID, "imagery:radar")
    XCTAssertNotNil(model.rasterFrame)
    model.selectMode(.models)
    try await waitFor { model.rasterFrame != nil }
    XCTAssertEqual(model.selectedFieldCode, "air_temperature_2m")
    XCTAssertFalse(model.selectedProductCode.isEmpty)
  }

  @MainActor func testEmptyImageryModesRemainSelectableAndEarlyRoundTripLoadsModel() async throws {
    let model = MapScreenModel(api: testAPI())
    for mode in [MapMode.radar, .satellite] {
      model.selectMode(mode)
      XCTAssertEqual(model.navigationMode, mode)
      XCTAssertNil(model.selectedImagery)
      XCTAssertEqual(model.frameCount, 0)
      XCTAssertNil(model.rasterFrame)
    }
    model.selectMode(.models)
    await model.load()
    try await waitFor { model.rasterFrame != nil }
    XCTAssertEqual(model.navigationMode, .models)
    XCTAssertEqual(model.selectedFieldCode, "air_temperature_2m")
  }

  @MainActor func testChoosingNewDataReplacesRatherThanTogglesOrStacks() async throws {
    let model = try await selectionModel()
    XCTAssertEqual(model.selectedFieldCodes, ["air_temperature_2m"])
    model.selectOption("field:relative_humidity_2m")
    try await waitFor { model.rasterFrame != nil }
    XCTAssertEqual(model.selectedFieldCodes, ["relative_humidity_2m"])
    XCTAssertEqual(model.rasterLayers.count, 1)
    XCTAssertEqual(model.resolved.map(\.field), ["relative_humidity_2m"])
    let id = model.requestedFrameID
    model.selectOption("field:relative_humidity_2m")
    XCTAssertEqual(model.requestedFrameID, id, "Choosing the same row must not turn the map off")
    model.selectSource("gdps")
    try await waitFor { model.rasterFrame != nil }
    XCTAssertEqual(model.selectedFieldCodes, ["relative_humidity_2m"])
    XCTAssertEqual(model.rasterLayers.count, 1)
    XCTAssertEqual(model.sourceLabel, "ECCC · GDPS")
  }

  @MainActor func testQuickSelectionBeforeInitialCoverageLoadsStillProducesAFrame() async throws {
    let model = MapScreenModel(api: testAPI())
    await model.load()
    await model.loadSelectionCatalogues()
    XCTAssertTrue(model.domains.isEmpty, "Fixture deliberately delays initial coverage metadata")
    model.selectOption("field:relative_humidity_2m")
    try await waitFor { model.rasterFrame != nil }
    XCTAssertEqual(model.selectedDomainCode, "canada")
    XCTAssertEqual(model.selectedFieldCode, "relative_humidity_2m")
  }

  @MainActor func testWindHotspotsAndImageryAreExclusiveAndClearPreviousData() async throws {
    let model = try await selectionModel()
    model.selectOption("wind")
    try await waitFor { model.rasterFrame != nil }
    XCTAssertTrue(model.showWind)
    XCTAssertTrue(model.rasterLayers.isEmpty)
    XCTAssertTrue(model.resolved.isEmpty)
    XCTAssertEqual(model.rasterFrame?.wind.count, 1)
    model.playing = true
    XCTAssertNil(model.playbackTicket)
    model.frameStateChanged(id: model.requestedFrameID, state: .displayed)
    XCTAssertNotNil(
      model.playbackTicket, "Standalone wind still waits for display before its dwell")
    let windContext = model.presentationContextID
    model.selectOption("field:wind_u_10m")
    XCTAssertNotEqual(model.presentationContextID, windContext)
    XCTAssertFalse(model.showWind)
    model.selectOption("hotspots")
    try await waitFor { !model.hotspotLoading }
    XCTAssertEqual(model.hotspotPoints.count, 1)
    XCTAssertTrue(model.windPoints.isEmpty)
    XCTAssertTrue(model.rasterLayers.isEmpty)
    XCTAssertNil(model.displayedFrame)
    XCTAssertEqual(model.frameCount, 0)
    XCTAssertFalse(model.playing)
    XCTAssertEqual(model.hotspotDate, "2026-09-07")
    model.selectOption("imagery:radar")
    XCTAssertFalse(model.showHotspots)
    XCTAssertTrue(model.hotspotPoints.isEmpty)
    XCTAssertEqual(model.rasterLayers.count, 1)
    XCTAssertTrue(model.rasterFrame?.wind.isEmpty == true)
    XCTAssertTrue(model.rasterFrame?.legends.isEmpty == true)
    model.selectOption("field:air_temperature_2m")
    try await waitFor { model.rasterFrame != nil }
    XCTAssertFalse(model.showWind)
    XCTAssertFalse(model.showHotspots)
    XCTAssertEqual(model.rasterLayers.count, 1)
  }

  @MainActor func testLateHotspotsCannotReturnAfterChangingTheSelection() async throws {
    let model = try await selectionModel()
    model.selectOption("hotspots")
    try await Task.sleep(for: .milliseconds(40))
    model.selectOption("imagery:radar")
    try await Task.sleep(for: .milliseconds(350))
    XCTAssertEqual(model.selectedOptionID, "imagery:radar")
    XCTAssertTrue(model.hotspotPoints.isEmpty)
    XCTAssertFalse(model.hotspotLoading)
    XCTAssertNil(model.featureError)
  }

  func testSpeedOptionsUsePointSevenFiveSecondBaseAndPointThreeSevenFiveAtDoubleSpeed() {
    XCTAssertEqual(MapPlaybackSpeed.allCases.map(\.rawValue), [1, 2, 4, 8])
    XCTAssertEqual(MapPlaybackSpeed.allCases.map(\.secondsPerFrame), [0.75, 0.375, 0.1875, 0.09375])
  }

  @MainActor private func imageryModel() async throws -> MapScreenModel {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [PlaybackFixtureProtocol.self]
    let api = WeatherAPI(
      baseURL: URL(string: "https://weather.test")!,
      session: URLSession(configuration: config))
    let model = MapScreenModel(api: api)
    await model.loadImagery()
    model.selectOption("imagery:radar")
    XCTAssertEqual(model.frameCount, 3)
    model.selectFrame(0)
    return model
  }

  @MainActor func testMetadataAloneNeverStartsViewingTimer() async throws {
    let model = try await imageryModel()
    model.playing = true
    XCTAssertNotNil(model.rasterFrame)
    XCTAssertNil(model.playbackTicket)
    model.frameStateChanged(id: model.requestedFrameID, state: .loading)
    XCTAssertNil(model.playbackTicket)
    model.frameStateChanged(id: model.requestedFrameID, state: .displayed)
    XCTAssertEqual(model.playbackTicket?.speed.secondsPerFrame, 0.75)
  }

  @MainActor func testCameraMovementCancelsDwellAndStartsFullNewDwell() async throws {
    let model = try await imageryModel()
    model.playing = true
    model.frameStateChanged(id: model.requestedFrameID, state: .displayed)
    let old = try XCTUnwrap(model.playbackTicket)
    model.frameStateChanged(id: model.requestedFrameID, state: .loading)
    XCTAssertNil(model.playbackTicket)
    XCTAssertFalse(model.advancePlayback(ticket: old))
    model.frameStateChanged(id: model.requestedFrameID, state: .displayed)
    XCTAssertNotEqual(model.playbackTicket, old)
    XCTAssertFalse(model.advancePlayback(ticket: old))
    XCTAssertEqual(model.selectedFrameIndex, 0)
  }

  @MainActor func testPlaybackAdvancesOneFrameAndHoldsDisplayedTimeUntilReady() async throws {
    let model = try await imageryModel()
    model.playing = true
    model.frameStateChanged(id: model.requestedFrameID, state: .displayed)
    let oldTime = model.displayedFrame?.time
    let ticket = try XCTUnwrap(model.playbackTicket)
    XCTAssertTrue(model.advancePlayback(ticket: ticket))
    XCTAssertEqual(model.selectedFrameIndex, 1)
    XCTAssertEqual(model.displayedFrame?.time, oldTime)
    XCTAssertNil(model.playbackTicket)
    XCTAssertFalse(model.advancePlayback(ticket: ticket))
    // An old tile completion must not make the newly requested frame ready.
    model.frameStateChanged(id: ticket.frameID, state: .displayed)
    XCTAssertNil(model.playbackTicket)
    model.frameStateChanged(id: model.requestedFrameID, state: .displayed)
    XCTAssertNotEqual(model.displayedFrame?.time, oldTime)
    XCTAssertNotNil(model.playbackTicket)
  }

  @MainActor func testSpeedChangePauseResumeAndScrubbingInvalidateOldTimer() async throws {
    let model = try await imageryModel()
    model.playing = true
    model.frameStateChanged(id: model.requestedFrameID, state: .displayed)
    let old = try XCTUnwrap(model.playbackTicket)
    model.playbackSpeed = .octuple
    XCTAssertEqual(model.playbackTicket?.speed.secondsPerFrame, 0.09375)
    XCTAssertFalse(model.advancePlayback(ticket: old))
    let fast = try XCTUnwrap(model.playbackTicket)
    model.playing = false
    XCTAssertNil(model.playbackTicket)
    model.playing = true
    XCTAssertFalse(model.advancePlayback(ticket: fast))
    let resumed = try XCTUnwrap(model.playbackTicket)
    model.selectFrame(2)
    XCTAssertFalse(model.advancePlayback(ticket: resumed))
    model.frameStateChanged(id: model.requestedFrameID, state: .displayed)
    XCTAssertTrue(model.advancePlayback(ticket: try XCTUnwrap(model.playbackTicket)))
    XCTAssertEqual(model.selectedFrameIndex, 0, "Wrap to the immediate next frame; never skip")
  }

  @MainActor func testFailedFrameHoldsPreviousAndPausesInsteadOfSkipping() async throws {
    let model = try await imageryModel()
    model.frameStateChanged(id: model.requestedFrameID, state: .displayed)
    let oldTime = model.displayedFrame?.time
    model.playing = true
    model.moveFrame(by: 1)
    model.frameStateChanged(id: model.requestedFrameID, state: .failed("Tile failed"))
    XCTAssertFalse(model.playing)
    XCTAssertNil(model.playbackTicket)
    XCTAssertEqual(model.selectedFrameIndex, 1)
    XCTAssertEqual(model.displayedFrame?.time, oldTime)
    XCTAssertEqual(model.errorMessage, "Tile failed")
    let failedID = model.requestedFrameID
    model.retry()
    XCTAssertNotEqual(model.requestedFrameID, failedID)
    XCTAssertEqual(model.selectedFrameIndex, 1)
    XCTAssertNil(model.errorMessage)
  }

  @MainActor func testOpacityEditInvalidatesOldDwellWithoutUnconditionallyClearingReadiness()
    async throws
  {
    let model = try await imageryModel()
    model.frameStateChanged(id: model.requestedFrameID, state: .displayed)
    model.playing = true
    let old = try XCTUnwrap(model.playbackTicket)
    model.opacity = 0.5
    XCTAssertFalse(model.advancePlayback(ticket: old))
    // The surface invalidates readiness if effective drawing changes. A global
    // opacity masked by every per-layer override must not leave the clock stuck.
    XCTAssertTrue(model.isFrameDisplayed)
    model.frameStateChanged(id: model.requestedFrameID, state: .loading)
    XCTAssertNil(model.playbackTicket)
  }

  func testCoverageRequiresEveryViewportPieceAndIgnoresRepeatedDraws() {
    var coverage = RasterDrawCoverage(MKMapRect(x: 0, y: 0, width: 100, height: 100))
    XCTAssertFalse(coverage.record(MKMapRect(x: 0, y: 0, width: 50, height: 100)))
    XCTAssertFalse(coverage.record(MKMapRect(x: 0, y: 0, width: 50, height: 100)))
    XCTAssertFalse(coverage.record(MKMapRect(x: 50, y: 0, width: 50, height: 50)))
    XCTAssertFalse(coverage.record(MKMapRect(x: 150, y: 0, width: 50, height: 50)))
    XCTAssertTrue(coverage.record(MKMapRect(x: 50, y: 50, width: 50, height: 50)))
  }

  func testTilePlanCoversViewportAtZoomAndClampsWorldEdges() {
    let size = MKMapSize.world.width / 128
    let rect = MKMapRect(x: 32.2 * size, y: 45.2 * size, width: 2 * size, height: 3 * size)
    let tiles = RasterTile.covering(rect, viewWidth: 512)
    XCTAssertEqual(tiles.count, 12)
    XCTAssertTrue(tiles.allSatisfy { $0.z == 7 })
    var coverage = RasterDrawCoverage(rect)
    for tile in tiles { _ = coverage.record(tile.mapRect) }
    XCTAssertTrue(coverage.remaining.isEmpty)
    let edges = RasterTile.covering(.world, viewWidth: 512)
    XCTAssertEqual(edges.count, 4)
    XCTAssertTrue(edges.allSatisfy { (0..<2).contains($0.x) && (0..<2).contains($0.y) })
    XCTAssertTrue(RasterTile.covering(.null, viewWidth: 0).isEmpty)
  }

  func testTileURLNeverEscapesConfiguredOrigin() throws {
    let tile = RasterTile(z: 2, x: 1, y: 0)
    let base = URL(string: "https://weather.test")!
    XCTAssertEqual(
      try tile.url(template: "https://weather.test/{z}/{x}/{y}.png", baseURL: base).path,
      "/2/1/0.png")
    XCTAssertThrowsError(
      try tile.url(template: "https://external.test/{z}/{x}/{y}.png", baseURL: base))
  }

  func testFrameLoaderWaitsForSlowestTileAndAllLayers() async throws {
    let api = testAPI()
    let layers = ["first", "second"].map {
      MapRasterLayer(id: $0, template: "https://weather.test/\($0)/{z}/{x}/{y}.png", opacity: 0.5)
    }
    let start = ContinuousClock.now
    let tiles = try await RasterFrameLoader().prepare(
      layers: layers,
      tiles: [.init(z: 1, x: 0, y: 0), .init(z: 1, x: 1, y: 0)], api: api)
    XCTAssertGreaterThanOrEqual(start.duration(to: .now), .milliseconds(200))
    XCTAssertEqual(tiles.count, 4)
    XCTAssertEqual(tiles.map(\.layerIndex), [0, 0, 1, 1])
  }

  func testFrameLoaderRejectsMissingAndUndecodableTiles() async {
    for name in ["missing", "invalid"] {
      do {
        _ = try await RasterFrameLoader().prepare(
          layers: [
            .init(id: name, template: "https://weather.test/\(name)/{z}/{x}/{y}.png", opacity: 1)
          ],
          tiles: [.init(z: 1, x: 0, y: 0)], api: testAPI())
        XCTFail("A failed tile must not produce a partial frame")
      } catch {}
    }
  }

  func testCancelledFrameNeverReturnsPartialTiles() async {
    let api = testAPI()
    let loading = Task {
      try await RasterFrameLoader().prepare(
        layers: [
          .init(id: "slow", template: "https://weather.test/slow/{z}/{x}/{y}.png", opacity: 1)
        ],
        tiles: [.init(z: 1, x: 0, y: 0), .init(z: 1, x: 1, y: 0)], api: api)
    }
    try? await Task.sleep(for: .milliseconds(40))
    loading.cancel()
    do {
      _ = try await loading.value
      XCTFail("Cancelling a partly loaded frame must not publish it")
    } catch {}
  }

  func testEmptyFrameCannotBeMistakenForReady() async {
    do {
      _ = try await RasterFrameLoader().prepare(
        layers: [], tiles: [.init(z: 0, x: 0, y: 0)], api: testAPI())
      XCTFail("No selected layers is not a ready animation frame")
    } catch {}
  }

  private func testAPI() -> WeatherAPI {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [PlaybackFixtureProtocol.self]
    return WeatherAPI(
      baseURL: URL(string: "https://weather.test")!,
      session: URLSession(configuration: config))
  }
}

private final class PlaybackFixtureProtocol: URLProtocol, @unchecked Sendable {
  private var work: DispatchWorkItem?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let url = request.url!
    let isJSON = url.path.hasPrefix("/api/")
    let data: Data
    if url.path == "/api/v1/imagery" {
      let frames = (0..<3).map { i in
        """
        {"id":"radar-\(i)","validTime":"2026-09-07T0\(i):00:00Z",
        "tileUrl":"/radar/\(i)/{z}/{x}/{y}.png","bounds":[-69,41,-52,50]}
        """
      }.joined(separator: ",")
      data = Data(
        """
        {"items":[{"code":"radar","name":"Radar","kind":"radar","attribution":"Test",
        "stale":false,"frames":[\(frames)]},
        {"code":"satellite_natural","name":"Visible","kind":"satellite","attribution":"Test",
        "stale":false,"frames":[\(frames)]},
        {"code":"satellite_ir","name":"Infrared","kind":"satellite","attribution":"Test",
        "stale":false,"frames":[\(frames)]}]}
        """.utf8)
    } else if isJSON {
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      func value(_ key: String) -> String { query.first { $0.name == key }?.value ?? "" }
      let object: [String: Any]
      if url.path == "/api/v1/products" {
        object = [
          "items": ["flexpart_smoke", "custom_run_123", "hrdps", "gdps"].enumerated().map {
            index, code in
            [
              "code": code, "name": code, "kind": "forecast", "priority": index,
              "latestRunTime": "2026-09-07T00:00:00Z",
            ] as [String: Any]
          }
        ]
      } else if url.path.hasSuffix("/domains") {
        object = ["items": [["code": "canada", "name": "Canada", "bounds": [-140, 40, -40, 80]]]]
      } else if url.path.hasSuffix("/fields") {
        object = [
          "items": ["air_temperature_2m", "relative_humidity_2m", "wind_u_10m", "wind_v_10m"].map {
            code in
            [
              "code": code, "name": code, "variableCode": code, "variableClass": "weather",
              "levelCode": "surface", "levelName": "Surface", "unit": "test", "palette": [],
              "defaultMin": 0, "defaultMax": 50,
            ] as [String: Any]
          }
        ]
      } else if url.path.hasSuffix("/timeline") {
        object = [
          "items": (0..<3).map { index in
            [
              "validTime": "2026-09-07T0\(index):00:00Z", "runTime": "2026-09-07T00:00:00Z",
              "forecastHour": index, "timeKind": "instant",
            ] as [String: Any]
          }, "truncated": false,
        ]
      } else if url.path == "/api/v1/layers/resolve" {
        object = [
          "product": value("product"), "domain": "canada", "runTime": "2026-09-07T00:00:00Z",
          "validTime": value("valid_time"), "forecastHour": 0, "field": value("field"),
          "variable": value("field"),
          "level": "surface", "unit": "test", "tileUrl": "/first/{z}/{x}/{y}.png",
          "token": value("field"),
          "legend": ["minimum": 0, "maximum": 50, "palette": []],
        ]
      } else if url.path == "/api/v1/hotspots/dates" {
        object = ["items": [["dataDate": "2026-09-06"], ["dataDate": "2026-09-07"]]]
      } else if url.path == "/api/v1/hotspots" {
        object = [
          "features": [
            [
              "geometry": ["coordinates": [-63, 44]],
              "properties": ["observed_at": "2026-09-07T12:00:00Z", "sensor": "Test"],
            ]
          ]
        ]
      } else {
        object = [
          "unit": "m/s",
          "features": [
            [
              "geometry": ["coordinates": [-63, 44]],
              "properties": ["speed": 10, "bearing": 45],
            ]
          ],
        ]
      }
      data = try! JSONSerialization.data(withJSONObject: object)
    } else if url.path.contains("invalid") {
      data = Data("not an image".utf8)
    } else {
      data = Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg=="
      )!
    }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let response = HTTPURLResponse(
        url: url, statusCode: url.path.contains("missing") ? 503 : 200,
        httpVersion: nil, headerFields: ["Content-Type": isJSON ? "application/json" : "image/png"])!
      self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      self.client?.urlProtocol(self, didLoad: data)
      self.client?.urlProtocolDidFinishLoading(self)
    }
    self.work = work
    DispatchQueue.global().asyncAfter(
      deadline: .now()
        + (url.path.contains("/1/1/0.png") || url.path == "/api/v1/hotspots"
          || url.path.hasSuffix("/domains") ? 0.25 : 0),
      execute: work)
  }
  override func stopLoading() { work?.cancel() }
}
