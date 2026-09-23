import CoreLocation
import Foundation
import SwiftUI

struct GolfLimits: Codable, Hashable, Sendable {
  var minTemperatureC = 8.0
  var maxTemperatureC = 30.0
  var maxWindKmh = 25.0
  var maxRainMm = 1.0
  var maxPopPercent = 40.0
  var isValid: Bool {
    [minTemperatureC, maxTemperatureC, maxWindKmh, maxRainMm, maxPopPercent].allSatisfy(\.isFinite)
      && (-30...50).contains(minTemperatureC) && (-30...50).contains(maxTemperatureC)
      && minTemperatureC < maxTemperatureC && (0...150).contains(maxWindKmh)
      && (0...100).contains(maxRainMm) && (0...100).contains(maxPopPercent)
  }
}

struct GolfPreferences: Codable, Hashable, Sendable {
  var limits = GolfLimits()
  var latitude = 44.65
  var longitude = -63.57
  var siteName = "Halifax"
  var teeHour = 10
  var teeMinute = 0
  var timeZone = TimeZone.current.identifier
  var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
  var teeTime: String { String(format: "%02d:%02d", teeHour, teeMinute) }
  var isValid: Bool {
    limits.isValid && latitude.isFinite && longitude.isFinite
      && (-90...90).contains(latitude) && (-180...180).contains(longitude)
      && (0...23).contains(teeHour) && (0...59).contains(teeMinute)
      && TimeZone(identifier: timeZone) != nil && siteName.count <= 80
  }
}

@MainActor final class GolfSettingsStore: ObservableObject {
  @Published private(set) var value: GolfPreferences
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    value =
      defaults.data(forKey: "golfPreferences:v1").flatMap {
        try? JSONDecoder().decode(GolfPreferences.self, from: $0)
      }.flatMap { $0.isValid ? $0 : nil } ?? GolfPreferences()
  }
  func save(_ next: GolfPreferences) {
    guard next.isValid, let data = try? JSONEncoder().encode(next) else { return }
    value = next
    defaults.set(data, forKey: "golfPreferences:v1")
  }
}

struct GolfOutlook: Codable, Sendable {
  struct Context: Codable, Sendable {
    let name: String
    let distanceKm: Double
    let issuedAt: Date
    let stale: Bool
  }
  let generatedAt: Date
  let ruleVersion: String
  let latitude: Double
  let longitude: Double
  let timeZone: String
  let source: String
  let runTime: Date?
  let limits: GolfLimits
  let regionalContext: Context?
  let method: String
  let scoreMeaning: String
  let days: [GolfDay]
}

struct GolfDay: Codable, Identifiable, Sendable {
  struct ModelRow: Codable, Sendable {
    let time: Date
    let temperatureC: Double?
    let windKmh: Double?
    let gustKmh: Double?
  }
  struct RainInterval: Codable, Sendable {
    let start: Date
    let end: Date
    let field: String
    let mm: Double?
  }
  let date: String
  let teeTime: Date
  let endTime: Date
  let state: String
  let score: Int?
  let scoreCoverage: String?
  let probabilityNote: String?
  let segments: [GolfSegment]
  let reasons: [String]
  let briefingDetail: String?
  let modelRows: [ModelRow]
  let precipitationIntervals: [RainInterval]
  let regionalPeriods: [ForecastPeriod]
  let contentID: String
  var id: String { date }
  var round: GolfSegment? { segments.first { $0.name == "Round" } }
  var status: String {
    switch state {
    case "within", "partial": "Within your limits"
    case "outside": "Some limits exceeded"
    case "started": "Tee time has passed"
    case "invalid_time": "Invalid local tee time"
    case "stale": "Recent model data unavailable"
    default: "Incomplete assessment"
    }
  }
  var fallbackSummary: String {
    switch state {
    case "within", "partial":
      "The forecast fits your playing preferences. \(briefingDetail ?? "Temperature, wind and precipitation fit your limits before, during and after the round.")"
    case "outside":
      "Some forecast conditions exceed your weather limits. \(briefingDetail ?? "Review the round details to see which conditions are limiting.")"
    case "started":
      "This tee time has passed. Choose a later time or review an upcoming day."
    case "invalid_time":
      "This local tee time does not exist on this date because of a clock change. Choose another time."
    case "stale":
      "A recent model forecast is unavailable for this point. No weather-fit score can be provided yet."
    default:
      "Some required weather values are missing or their timing is too coarse. \(briefingDetail ?? "A full comparison against your limits isn't available for this window.")"
    }
  }
}

struct GolfSegment: Codable, Identifiable, Sendable {
  struct Rain: Codable, Sendable {
    let minimumMm: Double
    let maximumMm: Double
    let coverStart: Date
    let coverEnd: Date
  }
  struct Check: Codable, Identifiable, Sendable {
    let field: String
    let label: String
    let state: String
    let fit: Double?
    var id: String { field }
  }
  let name: String
  let start: Date
  let end: Date
  let temperatureRangeC: [Double]?
  let maxWindKmh: Double?
  let maxGustKmh: Double?
  let rain: Rain?
  let popPercent: Double?
  let checks: [Check]
  let rainTimingUncertain: Bool
  var id: String { name }
}

extension WeatherAPI {
  func golfOutlook(_ preferences: GolfPreferences, firstDate: String) async throws -> GolfOutlook {
    let p = preferences
    return try await get(
      "/api/v1/golf/outlook",
      query: [
        .init(name: "latitude", value: String(p.latitude)),
        .init(name: "longitude", value: String(p.longitude)),
        .init(name: "local_date", value: firstDate), .init(name: "tee_time", value: p.teeTime),
        .init(name: "time_zone", value: p.timeZone), .init(name: "days", value: "7"),
        .init(name: "min_temperature_c", value: String(p.limits.minTemperatureC)),
        .init(name: "max_temperature_c", value: String(p.limits.maxTemperatureC)),
        .init(name: "max_wind_kmh", value: String(p.limits.maxWindKmh)),
        .init(name: "max_rain_mm", value: String(p.limits.maxRainMm)),
        .init(name: "max_pop_percent", value: String(p.limits.maxPopPercent)),
      ], timeout: 55)
  }
}

@MainActor final class GolfModel: ObservableObject {
  @Published private(set) var outlook: GolfOutlook?
  @Published private(set) var loading = false
  @Published private(set) var error: String?
  @Published private(set) var narratives: [String: ForecastSummaryModel] = [:]
  private var scope: String?
  private var ticket = UUID()

  func load(preferences: GolfPreferences, firstDate: String, api: WeatherAPI) async {
    let identity = "\(api.baseURL)|\(preferences)|\(firstDate)"
    if scope != identity {
      cancel()
      outlook = nil
      narratives = [:]
      scope = identity
    }
    let request = UUID()
    ticket = request
    loading = true
    error = nil
    do {
      let result = try await api.golfOutlook(preferences, firstDate: firstDate)
      guard !Task.isCancelled, ticket == request else { return }
      guard result.latitude == preferences.latitude, result.longitude == preferences.longitude,
        result.timeZone == preferences.timeZone, result.limits == preferences.limits
      else { throw URLError(.cannotParseResponse) }
      outlook = result
      loading = false
      for day in result.days where narratives[day.id] == nil {
        narratives[day.id] = ForecastSummaryModel()
      }
    } catch {
      guard !Task.isCancelled, ticket == request else { return }
      loading = false
      self.error =
        outlook == nil
        ? "Couldn't load the golf forecast. Please try again."
        : "Couldn't refresh. The dated forecast below is retained."
    }
  }

  func explain(server: String, weeklySummary: ForecastSummaryModel) async {
    guard let outlook else { return }
    let request = ticket
    do {
      for day in outlook.days {
        while weeklySummary.isGenerating { try await Task.sleep(for: .milliseconds(150)) }
        try Task.checkCancellation()
        guard ticket == request else { return }
        guard let summary = narratives[day.id] else { continue }
        summary.prepare(ForecastSummaryInput(golf: day, outlook: outlook, server: server))
        while summary.isGenerating { try await Task.sleep(for: .milliseconds(150)) }
      }
    } catch {
      // A cancelled old refresh must not cancel a newer pin/settings request.
      if ticket == request { cancel() }
    }
  }

  func cancel() {
    ticket = UUID()
    loading = false
    narratives.values.forEach { $0.cancel() }
  }
}
