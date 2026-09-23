import MapKit
import XCTest

@testable import WeatherAtlas

final class MapAppearanceTests: XCTestCase {
  @MainActor func testWeatherMapIsQuietAndKeepsTheRasterBelowNativeLabels() throws {
    let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
    let raster = BufferedRasterOverlay()
    MapAppearance.configure(map, weatherOverlay: raster)
    let configuration = try XCTUnwrap(map.preferredConfiguration as? MKStandardMapConfiguration)
    XCTAssertEqual(configuration.elevationStyle, .flat)
    XCTAssertEqual(configuration.emphasisStyle, .muted)
    XCTAssertFalse(configuration.showsTraffic)
    XCTAssertTrue(configuration.pointOfInterestFilter?.excludes(.restaurant) == true)
    XCTAssertTrue(map.overlays(in: .aboveRoads).contains { $0 === raster })
    let coastline = try XCTUnwrap(map.overlays(in: .aboveRoads).last as? MKMultiPolyline)
    XCTAssertTrue(map.overlays(in: .aboveRoads).first === raster)
    XCTAssertGreaterThan(coastline.polylines.count, 100)
    let coordinator = MapSurface.Coordinator(onTap: { _ in })
    XCTAssertTrue(coordinator.mapView(map, rendererFor: coastline) is ReferenceCoastlineRenderer)
    XCTAssertTrue(map.overlays(in: .aboveLabels).isEmpty)
  }

  func testRegionalCoastlineFadesOutBeforeStreetLevelZoom() {
    func scale(_ zoom: Double) -> MKZoomScale { pow(2, zoom) * 256 / MKMapSize.world.width }
    XCTAssertEqual(ReferenceCoastlines.opacity(zoomScale: scale(6)), 1)
    XCTAssertEqual(ReferenceCoastlines.opacity(zoomScale: scale(8)), 0.5, accuracy: 0.001)
    XCTAssertEqual(ReferenceCoastlines.opacity(zoomScale: scale(9)), 0)
    XCTAssertEqual(ReferenceCoastlines.opacity(zoomScale: .nan), 0)
    XCTAssertEqual(ReferenceCoastlines.opacity(zoomScale: 0), 0)
  }

  @MainActor func testLighterOpacityRemainsUserAdjustableWithoutChangingForecastFrames() {
    let model = MapScreenModel(api: WeatherAPI(baseURL: URL(string: "http://localhost:8097")!))
    XCTAssertEqual(model.opacity, 0.62)
    let id = model.requestedFrameID
    model.opacity = 0.85
    XCTAssertEqual(model.opacity, 0.85)
    XCTAssertEqual(model.requestedFrameID, id)
  }

  func testWindSizeUsesSpeedWithoutChangingBearingAndBoundsInvalidValues() {
    XCTAssertEqual(MapAppearance.windSize(speed: 0), 20)
    XCTAssertEqual(MapAppearance.windSize(speed: 45), 30)
    XCTAssertEqual(MapAppearance.windSize(speed: 200), 30)
    for value: Double? in [nil, Double.nan, -Double.infinity, -1] {
      XCTAssertEqual(MapAppearance.windSize(speed: value), 24)
    }
    XCTAssertLessThan(MapAppearance.windSize(speed: 5), MapAppearance.windSize(speed: 25))
  }

  @MainActor func testWindAnnotationUsesTheOutlinedSymbolAndRetainsCalloutAndRotation() throws {
    let map = MKMapView(frame: .init(x: 0, y: 0, width: 400, height: 600))
    let coordinator = MapSurface.Coordinator(onTap: { _ in })
    let point = DisplayPoint(
      id: "wind", longitude: -63.57, latitude: 44.65,
      title: "10 m/s", subtitle: "10 m wind", bearing: 90, windSpeedMetresPerSecond: 10)
    let view = try XCTUnwrap(coordinator.mapView(map, viewFor: WeatherAnnotation(point)))
    XCTAssertTrue(view.canShowCallout)
    XCTAssertEqual(view.image, MapAppearance.windImage(speed: 10))
    XCTAssertEqual(view.image?.size.width, CGFloat(MapAppearance.windSize(speed: 10)))
    XCTAssertEqual(view.transform.b, 1, accuracy: 0.0001)
    XCTAssertEqual(view.annotation?.title, "10 m/s")
  }
}
