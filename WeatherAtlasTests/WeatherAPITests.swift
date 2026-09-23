import CoreLocation
import UIKit
import XCTest

@testable import WeatherAtlas

final class WeatherAPITests: XCTestCase {
  func testFastTimestampDecoderPreservesFractionalSecondsAndTimezoneOffsets() throws {
    struct Stamp: Decodable { let time: Date }
    let decoder = WeatherAPI.decoder()
    let baseline = Date(timeIntervalSince1970: 1_788_782_400)
    for (value, fraction) in [
      ("2026-09-07T12:00:00Z", 0.0), ("2026-09-07T12:00:00.123Z", 0.123),
      ("2026-09-07T09:00:00-03:00", 0.0), ("2026-09-07T13:00:00.123456+01:00", 0.123456),
    ] {
      let stamp = try decoder.decode(Stamp.self, from: Data("{\"time\":\"\(value)\"}".utf8))
      XCTAssertEqual(stamp.time.timeIntervalSince(baseline), fraction, accuracy: 0.000002)
    }
    XCTAssertThrowsError(try decoder.decode(Stamp.self, from: Data("{\"time\":\"invalid\"}".utf8)))
  }

  func testCountryScaleForecastTimestampDecoding() throws {
    struct Stamp: Decodable { let time: Date }
    // The production catalogue contains about 15,000 timestamps. The previous
    // per-date formatter cost seconds, hidden by the tiny two-region UI fixture.
    let row = "{\"time\":\"2026-09-07T12:00:00.123Z\"}"
    let data = Data(("[" + Array(repeating: row, count: 20_000).joined(separator: ",") + "]").utf8)
    let start = ContinuousClock.now
    let rows = try WeatherAPI.decoder().decode([Stamp].self, from: data)
    XCTAssertEqual(rows.count, 20_000)
    XCTAssertLessThan(start.duration(to: .now), .seconds(2))
  }

  @MainActor func testLocationServiceIsNotConstructedUntilExplicitlyStarted() {
    let driver = ForecastTestLocationDriver()
    var created = 0
    let location = ForecastLocation(makeManager: {
      created += 1
      return driver
    })
    XCTAssertEqual(created, 0)
    location.stop()
    location.stop()
    XCTAssertEqual(created, 0)
    XCTAssertEqual(driver.stops, 0)
    location.start()
    location.start()
    XCTAssertEqual(created, 1)
    XCTAssertEqual(driver.permissionRequests, 1)
    location.stop()
  }

  func testTemperatureLegendUsesServerBoundsAndActualStopSpacing() throws {
    let data = Data(
      """
      {"minimum":0,"maximum":25,"palette":[
        {"value":0,"color":"#0000ff"},
        {"value":5,"color":"#00ffff"},
        {"value":25,"color":"#ff0000"}]}
      """.utf8)
    let legend = try WeatherAPI.decoder().decode(Legend.self, from: data)
    XCTAssertEqual(legend.minimum, 0)
    XCTAssertEqual(legend.maximum, 25)
    XCTAssertEqual(legend.position(for: legend.palette[0].value), 0)
    XCTAssertEqual(legend.position(for: legend.palette[1].value), 0.2, accuracy: 0.000001)
    XCTAssertEqual(legend.position(for: legend.palette[2].value), 1)
    XCTAssertEqual(legend.position(for: -5), 0)
    XCTAssertEqual(legend.position(for: 30), 1)
  }

  func testBundledAppIconIsConfiguredForIPhone() throws {
    let plistURL = Bundle.main.bundleURL.appendingPathComponent("Info.plist")
    let info = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil)
        as? [String: Any])
    let icons = try XCTUnwrap(info["CFBundleIcons"] as? [String: Any])
    let primary = try XCTUnwrap(icons["CFBundlePrimaryIcon"] as? [String: Any])
    XCTAssertEqual(primary["CFBundleIconName"] as? String, "AppIcon")
    let files = try XCTUnwrap(primary["CFBundleIconFiles"] as? [String])
    XCTAssertFalse(files.isEmpty)
    // Xcode may emit iPad compatibility icons even with an iPhone-only target.
    XCTAssertEqual(info["UIDeviceFamily"] as? [Int], [1])
    XCTAssertNotNil(Bundle.main.url(forResource: "Assets", withExtension: "car"))
  }

  func testServerOriginAndTileTemplateValidation() throws {
    let api = WeatherAPI(baseURL: try XCTUnwrap(URL(string: "https://weather.example.com")))
    XCTAssertEqual(
      try api.tileTemplate("/tiles/token/{z}/{x}/{y}.png"),
      "https://weather.example.com/tiles/token/{z}/{x}/{y}.png")
    for url in [
      "https://upstream.example.com/{z}/{x}/{y}.png",
      "//upstream.example.com/{z}/{x}/{y}.png",
      "https://weather.example.com:444/{z}/{x}/{y}.png",
      "http://weather.example.com/{z}/{x}/{y}.png",
      "https://user:secret@weather.example.com/{z}/{x}/{y}.png",
    ] {
      XCTAssertThrowsError(try api.tileTemplate(url))
    }
    XCTAssertFalse(WeatherAPI.sameOrigin(URL(string: "https://upstream.example.com")!, api.baseURL))
  }
  func testServerURLAcceptsHTTPAndHTTPSWithoutCredentials() throws {
    XCTAssertEqual(try WeatherAPI.validatedBaseURL("http://localhost:8080").port, 8080)
    XCTAssertEqual(
      try WeatherAPI.validatedBaseURL("http://wolf359.iolan:18080").absoluteString,
      "http://wolf359.iolan:18080")
    XCTAssertNoThrow(try WeatherAPI.validatedBaseURL("http://192.168.1.20:8080"))
    XCTAssertNoThrow(try WeatherAPI.validatedBaseURL("http://weather.example.com:8080"))
    XCTAssertNoThrow(try WeatherAPI.validatedBaseURL("https://weather.example.com"))
    for url in [
      "https://user:pw@weather.example.com", "http://user:pw@wolf359.iolan:18080",
      "ftp://example.com", "https://example.com?secret=x", "http://wolf359.iolan:18080/api",
      "http://wolf359.iolan:18080#fragment", "wolf359.iolan:18080",
    ] {
      XCTAssertThrowsError(try WeatherAPI.validatedBaseURL(url))
    }
  }
  func testHTTPTilesPreserveServerSchemeHostAndPort() throws {
    let api = WeatherAPI(baseURL: try WeatherAPI.validatedBaseURL("http://wolf359.iolan:18080"))
    XCTAssertEqual(
      try api.tileTemplate("/tiles/token/{z}/{x}/{y}.png"),
      "http://wolf359.iolan:18080/tiles/token/{z}/{x}/{y}.png")
    XCTAssertNoThrow(try api.tileTemplate("http://wolf359.iolan:18080/tiles/{z}/{x}/{y}.png"))
    for url in [
      "https://wolf359.iolan:18080/tiles/{z}/{x}/{y}.png",
      "http://wolf359.iolan:8080/tiles/{z}/{x}/{y}.png",
      "http://wolf359.iolan/tiles/{z}/{x}/{y}.png",
      "http://upstream.iolan:8080/tiles/{z}/{x}/{y}.png",
    ] {
      XCTAssertThrowsError(try api.tileTemplate(url))
    }
  }
  func testBundledConfigurationUsesTheFixedHTTPSService() throws {
    XCTAssertEqual(AppConfiguration.current.apiBaseURL, WeatherAtlasEndpoint.productionURL)
    XCTAssertEqual(
      Bundle.main.object(forInfoDictionaryKey: "WeatherAtlasAPIBaseURL") as? String,
      "https://weatheratlas.ioresearch.ca")
    XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity"))
    XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription"))
  }

  func testOnlyExplicitSimulatorFixtureArgumentsCanOverrideTheEndpoint() {
    XCTAssertEqual(
      WeatherAtlasEndpoint.launchURL(arguments: []), WeatherAtlasEndpoint.productionURL)
    XCTAssertEqual(
      WeatherAtlasEndpoint.launchURL(arguments: ["-serverURL", "http://localhost:8097"]),
      WeatherAtlasEndpoint.productionURL)
    for value in [
      "http://evil.example:8097", "http://localhost:8080", "http://localhost:8097/api",
      "http://user:pw@localhost:8097",
    ] {
      XCTAssertEqual(
        WeatherAtlasEndpoint.launchURL(arguments: ["-weatherAtlasTestServerURL", value]),
        WeatherAtlasEndpoint.productionURL)
    }
    #if DEBUG && targetEnvironment(simulator)
      XCTAssertEqual(
        WeatherAtlasEndpoint.launchURL(arguments: [
          "-weatherAtlasTestServerURL", "http://localhost:8097",
        ]).absoluteString,
        "http://localhost:8097")
    #else
      XCTAssertEqual(
        WeatherAtlasEndpoint.launchURL(arguments: [
          "-weatherAtlasTestServerURL", "http://localhost:8097",
        ]),
        WeatherAtlasEndpoint.productionURL)
    #endif
  }
  func testForecastDecodingPreservesNullZeroAndOffsets() throws {
    let json = """
      {"regionId":"123","source":"ECCC GDPS","generatedAt":"2026-09-07T12:00:00.123Z",
      "start":"2026-09-07T09:00:00-03:00","end":"2026-09-10T12:00:00Z","availableHours":1,"completeHours":0,
      "hours":[{"time":"2026-09-07T12:00:00Z","runTime":null,"precipitationStart":"2026-09-07T11:00:00Z",
      "status":"partial","temperatureC":null,"relativeHumidityPercent":65,"precipitationMm":0,"windKmh":18,"gustKmh":null}]}
      """
    let forecast = try WeatherAPI.decoder().decode(HourlyForecast.self, from: Data(json.utf8))
    XCTAssertNil(forecast.hours[0].temperatureC)
    XCTAssertEqual(forecast.hours[0].precipitationMm, 0)
    XCTAssertEqual(forecast.start, forecast.hours[0].time)
    XCTAssertNil(forecast.hours[0].runTime)
  }
  func testAnalysisDoesNotInventForecastLead() throws {
    let data = Data(
      """
      {"items":[{"validTime":"2026-09-07T12:00:00Z","runTime":"2026-09-07T12:00:00Z",
      "forecastHour":null,"intervalStart":"2026-09-07T06:00:00Z","intervalEnd":"2026-09-07T12:00:00Z",
      "timeKind":"accumulation"}],"truncated":false}
      """.utf8)
    let timeline = try WeatherAPI.decoder().decode(TimelineResponse.self, from: data)
    XCTAssertNil(timeline.items[0].forecastHour)
    XCTAssertEqual(timeline.items[0].timeKind, "accumulation")
    XCTAssertNotEqual(timeline.items[0].intervalStart, timeline.items[0].intervalEnd)
  }
  @MainActor func testSavedPlacesAreScopedToServer() throws {
    let suite = "WeatherAtlasTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = URL(string: "https://first.example.com")!
    let store = AppStore(configuration: AppConfiguration(apiBaseURL: first), defaults: defaults)
    let region = ForecastRegion(
      id: "halifax", name: "Halifax", latitude: 44.65, longitude: -63.57,
      province: "NS", provinceName: "Nova Scotia", issuedAt: Date(), stale: false, periods: [])
    store.toggle(region)
    XCTAssertEqual(store.saved.count, 1)
    store.connect(to: URL(string: "https://second.example.com")!)
    XCTAssertTrue(store.saved.isEmpty)
    store.connect(to: first)
    XCTAssertEqual(store.saved.first?.id, region.id)
  }

  @MainActor func testSavedServerPreferencesCannotOverrideTheFixedEndpoint() throws {
    for address in [
      nil, "http://another.iolan:8080", "https://wolf359.iolan:8443", "http://localhost:8097",
      "https://elsewhere.example",
    ] as [String?] {
      let suite = "WeatherAtlasTests-\(UUID().uuidString)"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      if let address { defaults.set(address, forKey: "serverURL") }
      let store = AppStore(configuration: .current, defaults: defaults)
      XCTAssertEqual(store.serverURL, WeatherAtlasEndpoint.productionURL)
      XCTAssertNil(defaults.string(forKey: "serverURL"))
    }
  }

  @MainActor func testOldDefaultMigratesOnceAndKeepsSavedPlaces() throws {
    let suite = "WeatherAtlasTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let oldAddress = "http://wolf359.iolan:8080/"
    let newAddress = WeatherAtlasEndpoint.productionURL.absoluteString
    let place = SavedPlace(
      id: "halifax", name: "Halifax", province: "NS", latitude: 44.65, longitude: -63.57)
    let savedData = try JSONEncoder().encode([place])
    defaults.set(oldAddress, forKey: "serverURL")
    defaults.set(savedData, forKey: "savedPlaces:\(oldAddress)")

    let store = AppStore(configuration: .current, defaults: defaults)
    XCTAssertEqual(store.serverURL.absoluteString, newAddress)
    XCTAssertNil(defaults.string(forKey: "serverURL"))
    XCTAssertEqual(store.saved, [place])
    XCTAssertEqual(defaults.data(forKey: "savedPlaces:\(oldAddress)"), savedData)
    XCTAssertEqual(defaults.data(forKey: "savedPlaces:\(newAddress)"), savedData)

    // An obsolete preference cannot reconnect to HTTP after migration.
    defaults.set(oldAddress, forKey: "serverURL")
    let relaunched = AppStore(configuration: .current, defaults: defaults)
    XCTAssertEqual(relaunched.serverURL.absoluteString, newAddress)
    XCTAssertNil(defaults.string(forKey: "serverURL"))
  }

  @MainActor func testDefaultMigrationDoesNotOverwriteDestinationFavorites() throws {
    let suite = "WeatherAtlasTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let oldAddress = "http://wolf359.iolan:8080"
    let newAddress = WeatherAtlasEndpoint.productionURL.absoluteString
    let original = SavedPlace(id: "old", name: "Old", province: "NS", latitude: 44, longitude: -63)
    let destination = SavedPlace(
      id: "new", name: "New", province: "NS", latitude: 45, longitude: -64)
    let originalData = try JSONEncoder().encode([original])
    let destinationData = try JSONEncoder().encode([destination])
    defaults.set(oldAddress, forKey: "serverURL")
    defaults.set(originalData, forKey: "savedPlaces:\(oldAddress)")
    defaults.set(destinationData, forKey: "savedPlaces:\(newAddress)")

    let store = AppStore(configuration: .current, defaults: defaults)
    XCTAssertEqual(store.serverURL.absoluteString, newAddress)
    XCTAssertEqual(store.saved, [destination])
    XCTAssertEqual(defaults.data(forKey: "savedPlaces:\(oldAddress)"), originalData)
    XCTAssertEqual(defaults.data(forKey: "savedPlaces:\(newAddress)"), destinationData)
  }

  @MainActor func testHTTPSMigrationPreservesLocationStateAndForecastSnapshots() throws {
    let suite = "WeatherAtlasTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let old = "http://wolf359.iolan:18080"
    let current = WeatherAtlasEndpoint.productionURL.absoluteString
    let place = SavedPlace(
      id: "sydney", name: "Sydney", province: "NS", latitude: 46.1, longitude: -60.2)
    defaults.set(old, forKey: "serverURL")
    defaults.set("", forKey: "forecastRegion:\(old)")
    defaults.set(true, forKey: "forecastLocationPaused:\(old)")
    defaults.set(try JSONEncoder().encode(place), forKey: "defaultForecastLocation:\(old)")
    // Migration copies cache bytes; ForecastSnapshotStore independently validates
    // schema, region, age and coverage before any snapshot can be displayed.
    let bytes = Data("saved snapshot".utf8)
    for selection in ["automatic", "manual"] {
      defaults.set(bytes, forKey: "forecastSnapshot:v1:\(old):\(selection)")
    }
    let store = AppStore(configuration: .current, defaults: defaults)
    XCTAssertEqual(store.defaultForecastLocation, place)
    XCTAssertFalse(store.followsCurrentLocation)
    for selection in ["automatic", "manual"] {
      XCTAssertEqual(defaults.data(forKey: "forecastSnapshot:v1:\(current):\(selection)"), bytes)
    }
    store.useCurrentLocationForForecast()
    XCTAssertTrue(AppStore(configuration: .current, defaults: defaults).followsCurrentLocation)
  }

  @MainActor func testHTTPSMigrationPreservesMapPinWithoutCopyingForeignServerData() throws {
    let suite = "WeatherAtlasTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let old = "http://wolf359.iolan:18080"
    let pin = ForecastMapPin(regionID: "halifax", latitude: 44.7, longitude: -63.6)
    defaults.set(old, forKey: "serverURL")
    defaults.set(pin.regionID, forKey: "forecastRegion:\(old)")
    defaults.set(try JSONEncoder().encode(pin), forKey: "forecastMapPin:\(old)")
    XCTAssertEqual(AppStore(configuration: .current, defaults: defaults).forecastMapPin, pin)
    defaults.removePersistentDomain(forName: suite)
    defaults.set("https://unrelated.example", forKey: "serverURL")
    defaults.set("foreign", forKey: "forecastRegion:https://unrelated.example")
    let fresh = AppStore(configuration: .current, defaults: defaults)
    XCTAssertEqual(fresh.serverURL, WeatherAtlasEndpoint.productionURL)
    XCTAssertTrue(fresh.selectedRegionID.isEmpty)
    XCTAssertEqual(defaults.string(forKey: "forecastRegion:https://unrelated.example"), "foreign")
  }
}

final class HourlyPlotTests: XCTestCase {
  private func hour(value: Double? = nil, status: String = "complete") -> HourlyForecastHour {
    HourlyForecastHour(
      time: Date(), runTime: nil, precipitationStart: Date(), status: status,
      temperatureC: value, relativeHumidityPercent: value, precipitationMm: value,
      windKmh: value, gustKmh: value)
  }

  func testEachPlotUsesItsOwnServerMeasurement() {
    let hour = HourlyForecastHour(
      time: Date(), runTime: nil, precipitationStart: Date(), status: "complete",
      temperatureC: -4, relativeHumidityPercent: 78, precipitationMm: 2.4,
      windKmh: 12, gustKmh: 35)
    XCTAssertEqual(HourlyPlot.temperature.value(for: hour), -4)
    XCTAssertEqual(HourlyPlot.precipitation.value(for: hour), 2.4)
    XCTAssertEqual(HourlyPlot.wind.value(for: hour), 12)
    XCTAssertEqual(HourlyPlot.gust.value(for: hour), 35)
    XCTAssertEqual(HourlyPlot.humidity.value(for: hour), 78)
  }

  func testPlotUnitsTitlesAndColumnOrder() {
    XCTAssertEqual(
      HourlyPlot.allCases, [.temperature, .precipitation, .wind, .gust, .humidity])
    XCTAssertEqual(HourlyPlot.allCases.map(\.unit), ["°C", "mm", "km/h", "km/h", "%"])
    XCTAssertEqual(HourlyPlot.temperature.chartTitle, "Temperature (°C)")
    XCTAssertEqual(HourlyPlot.precipitation.chartTitle, "Precipitation (mm)")
    XCTAssertEqual(HourlyPlot.gust.chartTitle, "Wind gusts (km/h)")
    XCTAssertFalse(HourlyPlot.allCases.map(\.columnTitle).contains("Data"))
  }

  func testMissingValuesStayMissingAndZeroRemainsPlottable() {
    for plot in HourlyPlot.allCases {
      XCTAssertNil(plot.value(for: hour()))
      XCTAssertEqual(plot.value(for: hour(value: 0)), 0)
      XCTAssertNil(plot.value(for: hour(value: .nan)))
      XCTAssertNil(plot.value(for: hour(value: .infinity)))
    }
  }

}

final class ForecastPresentationTests: XCTestCase {
  func testWeatherDescriptionsChooseDistinctIcons() {
    let examples: [(String, ForecastWeatherIcon)] = [
      ("Sunny", .clearDay), ("Clear", .clearDay),
      ("A mix of sun and cloud.", .partlyCloudyDay), ("Cloudy periods", .partlyCloudyDay),
      ("Partly cloudy", .partlyCloudyDay), ("Mainly cloudy", .cloudy), ("Overcast", .cloudy),
      ("Periods of rain", .rain), ("Chance of showers", .rain), ("Drizzle", .drizzle),
      ("Showers with a risk of thunderstorms", .thunderstorms),
      ("Snow flurries", .snow), ("Blowing snow", .snow),
      ("Rain mixed with snow", .sleet), ("Freezing drizzle", .sleet), ("Ice pellets", .sleet),
      ("Hail", .hail), ("Fog patches", .fog), ("Hazy", .hazeDay), ("Smoke", .smoke),
      ("Windy", .wind), ("", .unknown), ("Unrecognized condition", .unknown),
    ]
    for (condition, expected) in examples {
      XCTAssertEqual(ForecastWeatherIcon(condition: condition, isNight: false), expected, condition)
    }
  }

  func testClearAndPartlyCloudyNightPeriodsUseMoonIcons() {
    for (name, temperatureClass) in [
      ("Tonight", "high"), ("Tuesday night", "high"), ("This evening", "high"), ("Tuesday", "low"),
    ] {
      let period = ForecastPeriod(
        name: name, start: Date(), end: Date().addingTimeInterval(3600), temperatureC: 12,
        temperatureClass: temperatureClass, relativeHumidityPercent: nil, popPercent: nil,
        precipitationAmount: nil, condition: "Partly cloudy")
      XCTAssertEqual(period.weatherIcon, .partlyCloudyNight)
    }
    XCTAssertEqual(ForecastWeatherIcon(condition: "Clear", isNight: true), .clearNight)
    XCTAssertEqual(ForecastWeatherIcon(condition: "Haze", isNight: true), .hazeNight)
    XCTAssertEqual(ForecastWeatherIcon(condition: "Rain", isNight: true), .rain)
  }

  @MainActor func testEveryWeatherSymbolExistsAndHasAnAccessibleDescription() {
    for icon in ForecastWeatherIcon.allCases {
      XCTAssertNotNil(UIImage(systemName: icon.symbolName), icon.symbolName)
      XCTAssertFalse(icon.label.isEmpty)
    }
  }

  private var halifaxCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Halifax")!
    return calendar
  }
  private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

  func testEveryForecastDayGetsAMidnightTickIncludingPartialFirstDay() {
    let start = date("2026-09-07T18:00:00-03:00")
    let end = start.addingTimeInterval(72 * 3600)
    let axis = HourlyDayAxis(start: start, end: end, calendar: halifaxCalendar)
    XCTAssertEqual(
      axis.ticks, (7...10).map { date("2026-09-\(String(format: "%02d", $0))T00:00:00-03:00") })
    XCTAssertEqual(axis.domain.lowerBound, axis.ticks.first)
    XCTAssertEqual(axis.domain.upperBound, end)
    XCTAssertEqual(
      axis.label(for: axis.ticks[0], locale: Locale(identifier: "en_US")), "Mon\nSep 7")
    XCTAssertEqual(
      axis.label(for: axis.ticks[3], locale: Locale(identifier: "en_US")), "Thu\nSep 10")
  }

  func testMidnightEndDoesNotLabelAnExtraEmptyDay() {
    let axis = HourlyDayAxis(
      start: date("2026-09-07T00:00:00-03:00"), end: date("2026-09-10T00:00:00-03:00"),
      calendar: halifaxCalendar)
    XCTAssertEqual(axis.ticks.count, 3)
    XCTAssertEqual(axis.ticks.last, date("2026-09-09T00:00:00-03:00"))
  }

  func testTicksStayAtLocalMidnightAcrossBothDaylightSavingChanges() {
    for (input, shortOrLongDay) in [
      ("2026-03-07T18:00:00-04:00", 23.0), ("2026-10-31T18:00:00-03:00", 25.0),
    ] {
      let start = date(input)
      let axis = HourlyDayAxis(
        start: start, end: start.addingTimeInterval(72 * 3600), calendar: halifaxCalendar)
      XCTAssertEqual(axis.ticks.count, 4)
      for tick in axis.ticks {
        XCTAssertEqual(halifaxCalendar.component(.hour, from: tick), 0)
        XCTAssertEqual(halifaxCalendar.component(.minute, from: tick), 0)
      }
      let gaps = zip(axis.ticks, axis.ticks.dropFirst()).map { $1.timeIntervalSince($0) / 3600 }
      XCTAssertTrue(gaps.contains(shortOrLongDay))
    }
  }

  func testMidnightTicksCrossMonthAndYearBoundaries() {
    let axis = HourlyDayAxis(
      start: date("2026-12-31T18:00:00-04:00"), end: date("2027-01-03T18:00:00-04:00"),
      calendar: halifaxCalendar)
    XCTAssertEqual(axis.ticks.count, 4)
    XCTAssertEqual(axis.ticks[1], date("2027-01-01T00:00:00-04:00"))
    XCTAssertEqual(
      axis.label(for: axis.ticks[1], locale: Locale(identifier: "en_US")), "Fri\nJan 1")
  }

  func testEmptyIntervalStillHasAValidChartDomain() {
    let start = date("2026-09-07T00:00:00-03:00")
    let axis = HourlyDayAxis(start: start, end: start, calendar: halifaxCalendar)
    XCTAssertEqual(axis.ticks, [start])
    XCTAssertGreaterThan(axis.domain.upperBound, axis.domain.lowerBound)
  }
}

final class ForecastBehaviorTests: XCTestCase {
  private var sydneyDefault: SavedPlace {
    SavedPlace(id: "sydney", name: "Sydney", province: "NS", latitude: 46.14, longitude: -60.19)
  }

  @MainActor func testConfiguredDefaultIsUsedForDailyAndHourlyWithoutGPS() async {
    let api = ForecastTestServer(extraRegions: [fallbackRegion(id: "sydney", name: "Sydney")])
    let model = ForecastModel(api: api)
    await model.load(preferredID: "", location: nil, defaultLocation: sydneyDefault)
    XCTAssertEqual(model.region?.id, "sydney")
    XCTAssertEqual(model.hourly?.regionId, "sydney")
    XCTAssertTrue(model.usingDefaultLocation)
    XCTAssertEqual(model.fallbackMessage, "Showing Sydney until your location is available.")
    let calls = await api.calls
    XCTAssertEqual(calls, ["regions", "hourly:sydney"])
  }

  @MainActor func testConfiguredDefaultDoesNotOverrideGPSOrManualSelection() async {
    let model = ForecastModel(api: ForecastTestServer())
    let fix = ForecastLocationFix(latitude: 46, longitude: -60, measuredAt: Date())
    await model.load(preferredID: "", location: fix, defaultLocation: sydneyDefault)
    XCTAssertEqual(model.region?.id, "nearby")
    XCTAssertFalse(model.usingDefaultLocation)
    await model.load(preferredID: "chosen", location: fix, defaultLocation: sydneyDefault)
    XCTAssertEqual(model.region?.id, "chosen")
    XCTAssertFalse(model.usingDefaultLocation)
  }

  @MainActor func testConfiguredDefaultHandlesMissingLocationEndpoint() async {
    let api = ForecastTestServer(
      nearestError: .server(status: 404, message: "Not Found"),
      extraRegions: [fallbackRegion(id: "sydney", name: "Sydney")])
    let model = ForecastModel(api: api)
    await model.load(
      preferredID: "",
      location: ForecastLocationFix(latitude: 46, longitude: -60, measuredAt: Date()),
      defaultLocation: sydneyDefault)
    XCTAssertEqual(model.region?.id, "sydney")
    XCTAssertTrue(model.usingDefaultLocation)
    XCTAssertEqual(
      model.fallbackMessage, "Showing Sydney because this server cannot match your location yet.")
  }

  @MainActor func testUnavailableConfiguredDefaultDoesNotSilentlyChooseHalifax() async {
    let model = ForecastModel(api: ForecastTestServer(extraRegions: [fallbackRegion()]))
    await model.load(preferredID: "", location: nil, defaultLocation: sydneyDefault)
    XCTAssertNil(model.region)
    XCTAssertTrue(model.error?.contains("Sydney is unavailable") == true)
  }

  @MainActor func testChangingDefaultRejectsAnInFlightOldDefault() async {
    let api = ForecastTestServer(
      extraRegions: [fallbackRegion(), fallbackRegion(id: "sydney", name: "Sydney")],
      holdRegions: true)
    let model = ForecastModel(api: api)
    let pending = Task { await model.load(preferredID: "", location: nil) }
    await api.waitForRegions()
    model.restore(preferredID: "", defaultLocation: sydneyDefault)
    await model.load(preferredID: "", location: nil, defaultLocation: sydneyDefault)
    await api.releaseRegions()
    await pending.value
    XCTAssertEqual(model.region?.id, "sydney")
    XCTAssertEqual(model.hourly?.regionId, "sydney")
    let calls = await api.calls
    XCTAssertFalse(calls.contains("hourly:halifax"))
  }

  @MainActor func testFailedGPSUsesConfiguredDefaultInsteadOfLastGPSRegion() async {
    let api = ForecastTestServer(extraRegions: [fallbackRegion(id: "sydney", name: "Sydney")])
    let model = ForecastModel(api: api)
    await model.load(
      preferredID: "",
      location: ForecastLocationFix(latitude: 46, longitude: -60, measuredAt: Date()),
      defaultLocation: sydneyDefault)
    XCTAssertEqual(model.region?.id, "nearby")
    await model.load(
      preferredID: "", location: nil, defaultLocation: sydneyDefault, locationUnavailable: true)
    XCTAssertEqual(model.region?.id, "sydney")
    XCTAssertTrue(model.usingDefaultLocation)
    XCTAssertFalse(model.usingLastLocation)
  }

  @MainActor func testManualOverridePersistsAndCanReturnToCurrentLocation() throws {
    let suite = "WeatherAtlasTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppStore(configuration: .current, defaults: defaults)
    XCTAssertTrue(store.followsCurrentLocation)
    XCTAssertEqual(store.selectedTab, 1)
    store.selectForecastRegion("chosen")
    let relaunched = AppStore(configuration: .current, defaults: defaults)
    XCTAssertFalse(relaunched.followsCurrentLocation)
    XCTAssertEqual(relaunched.selectedRegionID, "chosen")
    let firstServer = store.serverURL
    relaunched.connect(to: URL(string: "http://another.iolan:18080")!)
    XCTAssertTrue(relaunched.followsCurrentLocation)
    relaunched.connect(to: firstServer)
    XCTAssertEqual(relaunched.selectedRegionID, "chosen")
    relaunched.useCurrentLocationForForecast()
    XCTAssertTrue(AppStore(configuration: .current, defaults: defaults).followsCurrentLocation)
  }

  @MainActor func testPendingLocationLoadsDefaultImmediatelyWithoutWaitingForGPS() async {
    let api = ForecastTestServer(extraRegions: [fallbackRegion()])
    let model = ForecastModel(api: api)
    await model.load(preferredID: "", location: nil)
    XCTAssertEqual(model.region?.id, "halifax")
    XCTAssertEqual(model.hourly?.regionId, "halifax")
    XCTAssertTrue(model.usingDefaultLocation)
    let calls = await api.calls
    XCTAssertEqual(calls, ["regions", "hourly:halifax"])
  }

  @MainActor func testPhoneCoordinatesGoToServerAndSelectBothForecasts() async {
    let api = ForecastTestServer()
    let model = ForecastModel(api: api)
    await model.load(
      preferredID: "",
      location: ForecastLocationFix(latitude: 46.1, longitude: -60.2, measuredAt: Date()),
      useDefaultLocation: true)
    XCTAssertEqual(model.region?.id, "nearby")
    XCTAssertEqual(model.hourly?.regionId, "nearby")
    XCTAssertEqual(model.nearbyDistanceKm, 3)
    XCTAssertFalse(model.usingDefaultLocation)
    let coordinates = await api.coordinates
    XCTAssertEqual(coordinates.first?.0, -60.2)
    XCTAssertEqual(coordinates.first?.1, 46.1)
    let calls = await api.calls
    XCTAssertEqual(calls, ["nearest", "hourly:nearby"])
  }

  @MainActor func testManualRegionDoesNotRequestLocationLookup() async {
    let api = ForecastTestServer()
    let model = ForecastModel(api: api)
    await model.load(
      preferredID: "chosen",
      location: ForecastLocationFix(latitude: 46.1, longitude: -60.2, measuredAt: Date()),
      useDefaultLocation: true)
    XCTAssertEqual(model.region?.id, "chosen")
    XCTAssertEqual(model.hourly?.regionId, "chosen")
    XCTAssertNil(model.nearbyDistanceKm)
    XCTAssertFalse(model.usingDefaultLocation)
    let calls = await api.calls
    XCTAssertEqual(calls, ["regions", "hourly:chosen"])
  }

  @MainActor func testLateLocationResponseCannotReplaceManualChoice() async {
    let api = ForecastTestServer(holdNearest: true)
    let model = ForecastModel(api: api)
    let pending = Task {
      await model.load(
        preferredID: "",
        location: ForecastLocationFix(latitude: 46.1, longitude: -60.2, measuredAt: Date()))
    }
    await api.waitForNearest()
    await model.load(preferredID: "chosen", location: nil)
    await api.releaseNearest()
    await pending.value
    XCTAssertEqual(model.region?.id, "chosen")
    XCTAssertEqual(model.hourly?.regionId, "chosen")
    let calls = await api.calls
    XCTAssertFalse(calls.contains("hourly:nearby"))
  }

  @MainActor func testMissingCoverageDoesNotInventForecasts() async {
    for detail in ["No collected forecast region within coverage"] {
      let api = ForecastTestServer(nearestError: .server(status: 404, message: detail))
      let model = ForecastModel(api: api)
      await model.load(
        preferredID: "",
        location: ForecastLocationFix(latitude: 0, longitude: 0, measuredAt: Date()))
      XCTAssertNil(model.region)
      XCTAssertNil(model.hourly)
      XCTAssertNotNil(model.error)
      let calls = await api.calls
      XCTAssertEqual(calls, ["nearest"])
    }
  }

  @MainActor func testMissingLocationEndpointFallsBackToServerHalifaxForecast() async {
    let api = ForecastTestServer(
      nearestError: .server(status: 404, message: "Not Found"),
      extraRegions: [fallbackRegion()])
    let model = ForecastModel(api: api)
    await model.load(
      preferredID: "",
      location: ForecastLocationFix(latitude: 46.1, longitude: -60.2, measuredAt: Date()))
    XCTAssertEqual(model.region?.id, "halifax")
    XCTAssertEqual(model.hourly?.regionId, "halifax")
    XCTAssertTrue(model.usingDefaultLocation)
    XCTAssertEqual(
      model.fallbackMessage, "Showing Halifax because this server cannot match your location yet.")
    XCTAssertNil(model.nearbyDistanceKm)
    XCTAssertNil(model.error)
    let calls = await api.calls
    XCTAssertEqual(calls, ["nearest", "regions", "hourly:halifax"])
  }

  @MainActor func testMissingEndpointAndMissingHalifaxShowAnHonestError() async {
    let api = ForecastTestServer(nearestError: .server(status: 404, message: "Not Found"))
    let model = ForecastModel(api: api)
    await model.load(
      preferredID: "",
      location: ForecastLocationFix(latitude: 46.1, longitude: -60.2, measuredAt: Date()))
    XCTAssertNil(model.region)
    XCTAssertNil(model.hourly)
    XCTAssertFalse(model.usingDefaultLocation)
    XCTAssertTrue(model.error?.contains("Halifax is unavailable") == true)
    let calls = await api.calls
    XCTAssertEqual(calls, ["nearest", "regions"])
  }

  @MainActor func testAlreadyAuthorizedLocationDoesNotRequestPermissionAgain() {
    let driver = ForecastTestLocationDriver()
    driver.authorizationStatus = .authorizedWhenInUse
    let location = ForecastLocation(manager: driver)
    location.start()
    XCTAssertEqual(driver.permissionRequests, 0)
    XCTAssertEqual(driver.starts, 1)
    location.receive([CLLocation(latitude: 46.1, longitude: -60.2)])
    XCTAssertNotNil(location.fix)
    XCTAssertFalse(location.shouldUseDefaultLocation)
    location.stop()
  }

  @MainActor func testRefreshingLocationRetainsARecentUsableFix() {
    let driver = ForecastTestLocationDriver()
    driver.authorizationStatus = .authorizedWhenInUse
    let location = ForecastLocation(manager: driver)
    location.start()
    location.receive([CLLocation(latitude: 46.1, longitude: -60.2)])
    let fix = location.fix
    location.refresh()
    XCTAssertEqual(location.fix, fix)
    XCTAssertFalse(location.locating)
    location.stop()
  }

  @MainActor func testLocationPermissionAndForegroundLifecycle() {
    let driver = ForecastTestLocationDriver()
    let location = ForecastLocation(manager: driver)
    location.start()
    XCTAssertEqual(driver.permissionRequests, 1)
    XCTAssertEqual(driver.starts, 0)
    driver.authorizationStatus = .authorizedWhenInUse
    location.updateAuthorization()
    XCTAssertEqual(driver.starts, 1)
    let now = Date()
    location.receive(
      [
        CLLocation(
          coordinate: .init(latitude: 46.1, longitude: -60.2), altitude: 0,
          horizontalAccuracy: 5_000, verticalAccuracy: -1, timestamp: now)
      ], now: now)
    XCTAssertEqual(location.fix?.latitude, 46.1)  // Approximate location is enough.
    XCTAssertFalse(location.locating)
    location.stop()
    location.receive([CLLocation(latitude: 40, longitude: -70)])
    XCTAssertEqual(location.fix?.latitude, 46.1)
    XCTAssertGreaterThan(driver.stops, 0)
  }

  @MainActor func testDeniedAndStaleLocationsAreNotUsed() {
    let driver = ForecastTestLocationDriver()
    driver.authorizationStatus = .denied
    let location = ForecastLocation(manager: driver)
    location.start()
    XCTAssertTrue(location.permissionDenied)
    XCTAssertTrue(location.shouldUseDefaultLocation)
    XCTAssertNil(location.fix)
    XCTAssertEqual(driver.starts, 0)
    driver.authorizationStatus = .authorizedWhenInUse
    location.updateAuthorization()
    XCTAssertFalse(location.shouldUseDefaultLocation)
    let now = Date()
    location.receive(
      [
        CLLocation(
          coordinate: .init(latitude: 46.1, longitude: -60.2), altitude: 0,
          horizontalAccuracy: 10, verticalAccuracy: -1, timestamp: now.addingTimeInterval(-600))
      ], now: now)
    XCTAssertNil(location.fix)
    location.stop()
  }

  private func fallbackRegion(
    id: String = "halifax", name: String = "Halifax Metro and Halifax County West",
    province: String = "NS"
  ) -> ForecastRegion {
    ForecastRegion(
      id: id, name: name, latitude: 44.65, longitude: -63.57, province: province,
      provinceName: province, issuedAt: Date(), stale: false, periods: [])
  }

  @MainActor func testUnavailableLocationLoadsHalifaxForDailyAndHourly() async {
    for name in ["Halifax Metro and Halifax County West", "Halifax Metro", "Halifax"] {
      let api = ForecastTestServer(extraRegions: [
        fallbackRegion(id: "east", name: "Halifax County - east of Porters Lake"),
        fallbackRegion(id: "other", name: name, province: "ON"),
        fallbackRegion(name: name),
      ])
      let model = ForecastModel(api: api)
      await model.load(preferredID: "", location: nil, useDefaultLocation: true)
      XCTAssertEqual(model.region?.id, "halifax")
      XCTAssertEqual(model.hourly?.regionId, "halifax")
      XCTAssertTrue(model.usingDefaultLocation)
      XCTAssertNil(model.nearbyDistanceKm)
      XCTAssertNil(model.error)
      let calls = await api.calls
      XCTAssertEqual(calls, ["regions", "hourly:halifax"])
      let coordinates = await api.coordinates
      XCTAssertTrue(coordinates.isEmpty)
    }
  }

  @MainActor func testFallbackDoesNotReplaceAnExplicitRegionWhenLocationIsMissing() async {
    let api = ForecastTestServer(extraRegions: [fallbackRegion()])
    let model = ForecastModel(api: api)
    await model.load(preferredID: "chosen", location: nil, useDefaultLocation: true)
    XCTAssertEqual(model.region?.id, "chosen")
    XCTAssertEqual(model.hourly?.regionId, "chosen")
    XCTAssertFalse(model.usingDefaultLocation)
  }

  @MainActor func testMissingHalifaxDoesNotChooseAnotherRegion() async {
    let api = ForecastTestServer(extraRegions: [
      fallbackRegion(id: "east", name: "Halifax County - east of Porters Lake"),
      fallbackRegion(province: "ON"),
    ])
    let model = ForecastModel(api: api)
    await model.load(preferredID: "", location: nil, useDefaultLocation: true)
    XCTAssertNil(model.region)
    XCTAssertNil(model.hourly)
    XCTAssertFalse(model.usingDefaultLocation)
    XCTAssertTrue(model.error?.contains("Halifax is unavailable") == true)
    let calls = await api.calls
    XCTAssertEqual(calls, ["regions"])
  }

  @MainActor func testARecoveredPhoneLocationReplacesHalifax() async {
    let api = ForecastTestServer(extraRegions: [fallbackRegion()])
    let model = ForecastModel(api: api)
    await model.load(preferredID: "", location: nil, useDefaultLocation: true)
    XCTAssertTrue(model.usingDefaultLocation)
    await model.load(
      preferredID: "",
      location: ForecastLocationFix(latitude: 46.1, longitude: -60.2, measuredAt: Date()))
    XCTAssertEqual(model.region?.id, "nearby")
    XCTAssertEqual(model.hourly?.regionId, "nearby")
    XCTAssertFalse(model.usingDefaultLocation)
    XCTAssertNil(model.fallbackMessage)
  }

  @MainActor func testLateHalifaxResponseCannotReplaceGPSOrManualChoice() async {
    for preferredID in ["", "chosen"] {
      let api = ForecastTestServer(extraRegions: [fallbackRegion()], holdRegions: true)
      let model = ForecastModel(api: api)
      let pending = Task {
        await model.load(preferredID: "", location: nil, useDefaultLocation: true)
      }
      await api.waitForRegions()
      await model.load(
        preferredID: preferredID,
        location: ForecastLocationFix(latitude: 46.1, longitude: -60.2, measuredAt: Date()))
      await api.releaseRegions()
      await pending.value
      XCTAssertEqual(model.region?.id, preferredID.isEmpty ? "nearby" : "chosen")
      XCTAssertEqual(model.hourly?.regionId, model.region?.id)
      XCTAssertFalse(model.usingDefaultLocation)
      let calls = await api.calls
      XCTAssertFalse(calls.contains("hourly:halifax"))
    }
  }

  @MainActor func testLocationTimeoutUsesFallbackUntilAFixArrives() {
    let driver = ForecastTestLocationDriver()
    let location = ForecastLocation(manager: driver)
    location.start()
    XCTAssertFalse(location.shouldUseDefaultLocation)  // Permission prompt is still pending.
    driver.authorizationStatus = .authorizedWhenInUse
    location.updateAuthorization()
    XCTAssertFalse(location.shouldUseDefaultLocation)  // Give GPS time to acquire a fix.
    location.locationWaitTimedOut()
    XCTAssertTrue(location.shouldUseDefaultLocation)
    XCTAssertFalse(location.locating)
    location.receive([CLLocation(latitude: 46.1, longitude: -60.2)])
    XCTAssertNotNil(location.fix)
    XCTAssertFalse(location.shouldUseDefaultLocation)
    location.stop()
  }

  @MainActor func testRestrictedAndFailedLocationEnableFallback() {
    let driver = ForecastTestLocationDriver()
    driver.authorizationStatus = .restricted
    let location = ForecastLocation(manager: driver)
    location.start()
    XCTAssertTrue(location.shouldUseDefaultLocation)
    driver.authorizationStatus = .authorizedWhenInUse
    location.updateAuthorization()
    XCTAssertFalse(location.shouldUseDefaultLocation)
    location.locationManager(CLLocationManager(), didFailWithError: CLError(.network))
    XCTAssertTrue(location.shouldUseDefaultLocation)
    location.stop()
  }
}

final class PrecipitationBehaviorTests: XCTestCase {
  private let issuedAt = Date(timeIntervalSince1970: 1_788_768_000)

  private func period(pop: Double? = 30, amount: String? = nil) -> ForecastPeriod {
    ForecastPeriod(
      name: "Today", start: issuedAt, end: issuedAt.addingTimeInterval(43_200),
      temperatureC: 22, temperatureClass: "high", relativeHumidityPercent: 65,
      popPercent: pop, precipitationAmount: amount, condition: "Chance of showers")
  }

  func testIssuedAmountsKeepRangesSnowUnitsAndZero() {
    for amount in ["5 to 10 mm", "2 cm", "0 mm"] {
      XCTAssertEqual(
        period(amount: amount).precipitationDescription(estimatedMm: 99, loading: true),
        "Precipitation: \(amount)")
      XCTAssertFalse(period(amount: amount).needsPrecipitationEstimate)
    }
    // An issued amount remains useful even when the bulletin omits POP.
    XCTAssertEqual(
      period(pop: nil, amount: "2 cm").precipitationDescription(estimatedMm: nil),
      "Precipitation: 2 cm")
  }

  func testWetPeriodsAlwaysShowAnAmountStateAndDryPeriodsDoNotInventOne() {
    for pop in [1.0, 30, 100] {
      XCTAssertEqual(
        period(pop: pop).precipitationDescription(estimatedMm: nil),
        "Precipitation: amount unavailable")
      XCTAssertEqual(
        period(pop: pop).precipitationDescription(estimatedMm: nil, loading: true),
        "Precipitation: loading amount…")
    }
    for pop in [0, nil] as [Double?] {
      XCTAssertNil(period(pop: pop).precipitationDescription(estimatedMm: nil))
      XCTAssertFalse(period(pop: pop).needsPrecipitationEstimate)
    }
    XCTAssertTrue(period(amount: " \n ").needsPrecipitationEstimate)
  }

  func testEstimatesDistinguishTraceZeroAndMissingAmounts() {
    XCTAssertEqual(
      period().precipitationDescription(estimatedMm: 0),
      "Precipitation: 0 mm")
    XCTAssertEqual(
      period().precipitationDescription(estimatedMm: 0.05),
      "Precipitation: <0.1 mm")
    XCTAssertEqual(
      period().precipitationDescription(estimatedMm: 12),
      "Precipitation: 12 mm")
    for amount in [-1, Double.nan, Double.infinity] {
      XCTAssertEqual(
        period().precipitationDescription(estimatedMm: amount),
        "Precipitation: amount unavailable")
    }
  }

  func testPrecipitationDecodingPreservesMissingAndZero() throws {
    let json = """
      {"regionId":"123","issuedAt":"2026-09-07T12:00:00Z","source":"ECCC GDPS",
      "generatedAt":"2026-09-07T12:00:00.123Z","periods":[
      {"start":"2026-09-07T09:00:00-03:00","end":"2026-09-08T00:00:00Z",
      "status":"complete","precipitationMm":0,"runTime":"2026-09-07T06:00:00Z"},
      {"start":"2026-09-08T00:00:00Z","end":"2026-09-08T12:00:00Z",
      "status":"missing","precipitationMm":null,"runTime":null}]}
      """
    let result = try WeatherAPI.decoder().decode(PrecipitationForecast.self, from: Data(json.utf8))
    XCTAssertEqual(result.periods[0].precipitationMm, 0)
    XCTAssertEqual(result.periods[0].start, result.issuedAt)
    XCTAssertNil(result.periods[1].precipitationMm)
    XCTAssertNil(result.periods[1].runTime)
  }

  func testOnlyCompleteEstimatesForTheSameBulletinAndPeriodAreUsed() {
    let selected = ForecastRegion(
      id: "chosen", name: "Chosen", latitude: 44.65, longitude: -63.57,
      province: "NS", provinceName: "Nova Scotia", issuedAt: issuedAt, stale: false,
      periods: [period()])
    func estimate(
      id: String = "chosen", issueOffset: Double = 0, endOffset: Double = 0,
      status: String = "complete", amount: Double? = 2, run: Date?
    ) -> Double? {
      PrecipitationForecast(
        regionId: id, issuedAt: issuedAt.addingTimeInterval(issueOffset), source: "ECCC GDPS",
        generatedAt: issuedAt,
        periods: [
          PrecipitationForecastPeriod(
            start: period().start, end: period().end.addingTimeInterval(endOffset),
            status: status, precipitationMm: amount, runTime: run)
        ]
      ).estimatedMm(for: period(), in: selected)
    }
    XCTAssertEqual(estimate(run: issuedAt), 2)
    XCTAssertEqual(estimate(amount: 0, run: issuedAt), 0)
    XCTAssertNil(estimate(id: "another", run: issuedAt))
    XCTAssertNil(estimate(issueOffset: -1, run: issuedAt))
    XCTAssertNil(estimate(endOffset: 1, run: issuedAt))
    for status in ["missing", "partial", "official", "unknown"] {
      XCTAssertNil(estimate(status: status, run: issuedAt))
    }
    for amount in [nil, -1, .nan, .infinity] as [Double?] {
      XCTAssertNil(estimate(amount: amount, run: issuedAt))
    }
    XCTAssertNil(estimate(run: nil))
    XCTAssertNil(estimate(run: issuedAt.addingTimeInterval(1)))
  }

  @MainActor func testServerAmountsLoadForWetPeriodsWithoutIssuedAmounts() async {
    let api = ForecastTestServer(periods: [period()])
    let model = ForecastModel(api: api)
    await model.load(preferredID: "chosen", location: nil)
    XCTAssertEqual(model.precipitation?.regionId, "chosen")
    XCTAssertEqual(
      model.precipitationDescription(for: period()), "Precipitation: 12 mm")
    XCTAssertTrue(model.hasPrecipitationEstimates)
    XCTAssertFalse(model.precipitationLoading)
    XCTAssertEqual(model.hourly?.regionId, "chosen")
    let calls = await api.calls
    XCTAssertTrue(calls.contains("precipitation:chosen"))
  }

  @MainActor func testNoEstimateRequestWhenDryOrAnIssuedAmountExists() async {
    let api = ForecastTestServer(periods: [period(pop: 0), period(amount: "5 to 10 mm")])
    let model = ForecastModel(api: api)
    await model.load(preferredID: "chosen", location: nil)
    let calls = await api.calls
    XCTAssertFalse(calls.contains("precipitation:chosen"))
    XCTAssertNil(model.precipitation)
    XCTAssertFalse(model.hasPrecipitationEstimates)
  }

  @MainActor func testFailedPrecipitationDoesNotHideTheDailyOrHourlyForecast() async {
    let api = ForecastTestServer(
      periods: [period()], precipitationError: .server(status: 404, message: "Not Found"))
    let model = ForecastModel(api: api)
    await model.load(preferredID: "chosen", location: nil)
    XCTAssertEqual(model.region?.id, "chosen")
    XCTAssertEqual(model.hourly?.regionId, "chosen")
    XCTAssertNil(model.error)
    XCTAssertNil(model.precipitation)
    XCTAssertFalse(model.precipitationLoading)
    XCTAssertEqual(
      model.precipitationDescription(for: period()), "Precipitation: amount unavailable")
  }

  @MainActor func testFailedHourlyForecastDoesNotHidePrecipitation() async {
    let api = ForecastTestServer(
      periods: [period()], hourlyError: .server(status: 503, message: "Temporarily unavailable"))
    let model = ForecastModel(api: api)
    await model.load(preferredID: "chosen", location: nil)
    XCTAssertNil(model.hourly)
    XCTAssertNotNil(model.error)
    XCTAssertTrue(model.hasPrecipitationEstimates)
    XCTAssertFalse(model.hourlyLoading)
  }

  @MainActor func testLatePrecipitationResponseCannotReplaceNewLocation() async {
    let api = ForecastTestServer(periods: [period()], holdPrecipitation: true)
    let model = ForecastModel(api: api)
    let pending = Task {
      await model.load(
        preferredID: "",
        location: ForecastLocationFix(latitude: 44.65, longitude: -63.57, measuredAt: Date()))
    }
    await api.waitForPrecipitation()
    XCTAssertTrue(model.precipitationLoading)
    await model.load(preferredID: "chosen", location: nil)
    await api.releasePrecipitation()
    await pending.value
    XCTAssertEqual(model.region?.id, "chosen")
    XCTAssertEqual(model.precipitation?.regionId, "chosen")
    XCTAssertFalse(model.precipitationLoading)
  }
}

@MainActor
private final class ForecastTestLocationDriver: ForecastLocationDriving {
  weak var delegate: (any CLLocationManagerDelegate)?
  var authorizationStatus: CLAuthorizationStatus = .notDetermined
  var desiredAccuracy: CLLocationAccuracy = 0
  var distanceFilter: CLLocationDistance = 0
  var permissionRequests = 0
  var starts = 0
  var stops = 0
  func requestWhenInUseAuthorization() { permissionRequests += 1 }
  func startUpdatingLocation() { starts += 1 }
  func stopUpdatingLocation() { stops += 1 }
}

actor ForecastTestServer: ForecastServing {
  private(set) var calls: [String] = []
  private(set) var coordinates: [(Double, Double)] = []
  let holdNearest: Bool
  let nearestError: WeatherAPIError?
  let periods: [ForecastPeriod]
  let precipitationError: WeatherAPIError?
  let hourlyError: WeatherAPIError?
  let holdPrecipitation: Bool
  let extraRegions: [ForecastRegion]
  private var holdNextRegions: Bool
  private let issuedAt = Date()
  private var pending: CheckedContinuation<NearbyForecast, any Error>?
  private var arrival: CheckedContinuation<Void, Never>?
  private var pendingPrecipitation: CheckedContinuation<Void, Never>?
  private var precipitationArrival: CheckedContinuation<Void, Never>?
  private var pendingRegions: CheckedContinuation<Void, Never>?
  private var regionsArrival: CheckedContinuation<Void, Never>?
  init(
    holdNearest: Bool = false, nearestError: WeatherAPIError? = nil,
    periods: [ForecastPeriod] = [], precipitationError: WeatherAPIError? = nil,
    hourlyError: WeatherAPIError? = nil, holdPrecipitation: Bool = false,
    extraRegions: [ForecastRegion] = [], holdRegions: Bool = false
  ) {
    self.holdNearest = holdNearest
    self.nearestError = nearestError
    self.periods = periods
    self.precipitationError = precipitationError
    self.hourlyError = hourlyError
    self.holdPrecipitation = holdPrecipitation
    self.extraRegions = extraRegions
    self.holdNextRegions = holdRegions
  }
  private func region(_ id: String) -> ForecastRegion {
    ForecastRegion(
      id: id, name: id, latitude: 46.1, longitude: -60.2, province: "NS",
      provinceName: "Nova Scotia", issuedAt: issuedAt, stale: false, periods: periods)
  }
  func forecastRegions() async throws -> ForecastRegionsResponse {
    calls.append("regions")
    regionsArrival?.resume()
    regionsArrival = nil
    if holdNextRegions {
      holdNextRegions = false
      await withCheckedContinuation { pendingRegions = $0 }
    }
    return ForecastRegionsResponse(
      generatedAt: Date(), timeZone: "America/Halifax", regions: [region("chosen")] + extraRegions)
  }
  func waitForRegions() async {
    guard !calls.contains("regions") else { return }
    await withCheckedContinuation { regionsArrival = $0 }
  }
  func releaseRegions() {
    pendingRegions?.resume()
    pendingRegions = nil
  }
  func nearestForecast(longitude: Double, latitude: Double) async throws -> NearbyForecast {
    calls.append("nearest")
    coordinates.append((longitude, latitude))
    arrival?.resume()
    arrival = nil
    if let nearestError { throw nearestError }
    if holdNearest { return try await withCheckedThrowingContinuation { pending = $0 } }
    return NearbyForecast(
      region: region("nearby"), distanceKm: 3, matchKind: "nearest_representative_point")
  }
  func waitForNearest() async {
    guard !calls.contains("nearest") else { return }
    await withCheckedContinuation { arrival = $0 }
  }
  func releaseNearest() {
    pending?.resume(
      returning: NearbyForecast(
        region: region("nearby"), distanceKm: 3, matchKind: "nearest_representative_point"))
    pending = nil
  }
  func hourlyForecast(areaID: String) async throws -> HourlyForecast {
    calls.append("hourly:\(areaID)")
    if let hourlyError { throw hourlyError }
    return HourlyForecast(
      regionId: areaID, source: "Test", generatedAt: Date(), start: Date(),
      end: Date(), availableHours: 0, completeHours: 0, hours: [])
  }
  func precipitationForecast(areaID: String) async throws -> PrecipitationForecast {
    calls.append("precipitation:\(areaID)")
    precipitationArrival?.resume()
    precipitationArrival = nil
    if let precipitationError { throw precipitationError }
    if holdPrecipitation && areaID == "nearby" {
      await withCheckedContinuation { pendingPrecipitation = $0 }
    }
    return PrecipitationForecast(
      regionId: areaID, issuedAt: issuedAt, source: "ECCC GDPS", generatedAt: issuedAt,
      periods: periods.map {
        PrecipitationForecastPeriod(
          start: $0.start, end: $0.end, status: "complete", precipitationMm: 12, runTime: $0.start)
      })
  }
  func waitForPrecipitation() async {
    guard !calls.contains("precipitation:nearby") else { return }
    await withCheckedContinuation { precipitationArrival = $0 }
  }
  func releasePrecipitation() {
    pendingPrecipitation?.resume()
    pendingPrecipitation = nil
  }
}
