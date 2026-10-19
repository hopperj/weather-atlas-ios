import XCTest

@testable import WeatherAtlas

final class AstronomyTests: XCTestCase {
  @MainActor func testExactSitesPersistIndependentlyWithNoRegionalSnapping() throws {
    let suite = "Astronomy-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let seed = ObservingSite(name: "Forecast", latitude: 44.65, longitude: -63.57)
    let point = ObservingSite(name: "Remote telescope", latitude: 45.123456, longitude: -65.987654)
    let settings = AstronomySettings(seed: seed, server: "https://dev.test", defaults: defaults)
    settings.followsGPS = true
    settings.choose(point)
    XCTAssertFalse(settings.followsGPS)
    settings.save()
    settings.save()
    XCTAssertEqual(settings.saved.count, 1)
    let restored = AstronomySettings(seed: seed, server: "https://dev.test", defaults: defaults)
    XCTAssertEqual(restored.site, point)
    XCTAssertEqual(restored.saved, [point])
    XCTAssertEqual(
      AstronomySettings(seed: seed, server: "https://other.test", defaults: defaults).site, seed)
    XCTAssertEqual(
      AstronomySettings(
        seed: seed, server: "https://dev.test", defaults: defaults, restoreLast: false
      ).site, seed)
    restored.remove(point)
    XCTAssertTrue(restored.saved.isEmpty)
    settings.choose(.init(name: "Bad", latitude: .nan, longitude: 0))
    XCTAssertEqual(settings.site, point)
  }

  func testPreviewContractPreservesMissingWeatherAndCrossMidnightIntervals() throws {
    let text = """
      {"schemaVersion":1,"generatedAt":"2026-10-19T16:00:00Z","preview":true,
       "latitude":45.123456,"longitude":-65.987654,"timeZone":"America/Halifax",
       "product":"gdps","source":"ECCC GDPS","runTime":null,"stale":true,
       "mode":"deep_sky","ruleVersion":"cloud-darkness-preview-v1","method":"Nearest cell",
       "limitations":["Seeing unavailable"],"sample":null,
       "frames":[{"time":"2026-10-20T04:00:00Z","cloudPercent":null,"temperatureC":null,
         "humidityPercent":null,"windKmh":null,"gustKmh":null,"dewPointC":null,"dewRisk":null,
         "rainMm":null,"rainStart":null,"sunAltitudeDegrees":-40,"moonAltitudeDegrees":-5,
         "moonIlluminatedPercent":20}],
       "nights":[{"date":"2026-10-19","start":"2026-10-19T15:00:00Z",
         "end":"2026-10-20T15:00:00Z","state":"insufficient_data","summary":"No weather",
         "events":{"sunset":"2026-10-19T21:00:00Z","moonrise":null},
         "darkness":[{"start":"2026-10-19T23:00:00Z","end":"2026-10-20T09:00:00Z","minutes":600}],
         "moonlessDarkness":[],"windows":[],"moonIlluminatedPercent":20}]}
      """
    let value = try WeatherAPI.decoder().decode(AstronomyForecast.self, from: Data(text.utf8))
    XCTAssertTrue(value.preview)
    XCTAssertNil(value.frames.first?.cloudPercent)
    XCTAssertNil(value.frames.first?.rainMm)
    XCTAssertEqual(value.nights.first?.state, "insufficient_data")
    XCTAssertNil(value.nights.first?.bestWindow)
    XCTAssertEqual(value.zone.identifier, "America/Halifax")
    XCTAssertEqual(value.nights.first?.darkness.first?.minutes, 600)
  }
}
