import Foundation

struct ForecastChanges: Decodable, Sendable {
  struct Bulletin: Decodable, Equatable, Sendable {
    let id: String
    let latitude: Double
    let longitude: Double
    let issuedAt: Date
    let periods: [ForecastPeriod]
  }
  struct Bulletins: Decodable, Equatable, Sendable {
    let state: String
    let current: Bulletin?
    let previous: Bulletin?
    var assessment: String? = nil
    var importantFacts: [String]? = nil
  }
  struct Group: Decodable, Identifiable, Sendable {
    let source: String
    let state: String
    let currentIssuedAt: Date
    let previousIssuedAt: Date?
    let matchedPeriods: Int
    let comparableValues: Int
    let highlights: [Change]
    let details: [Change]
    var id: String { source }
    var explanation: String {
      switch state {
      case "changed": "Compared with the previous published forecast"
      case "unchanged": "No significant changes in comparable periods"
      case "building_history": "Building forecast history"
      case "location_changed": "The forecast location changed; a new baseline is needed"
      default: "Not enough matching data to compare yet"
      }
    }
  }
  struct Change: Decodable, Identifiable, Sendable {
    let id: String
    let field: String
    let start: Date
    let end: Date
    let before: Double
    let after: Double
    let delta: Double
    let unit: String
    let summary: String
  }
  let regionId: String
  let generatedAt: Date
  let stale: Bool
  let groups: [Group]
  var bulletins: Bulletins? = nil
}

enum StationField: String, CaseIterable, Identifiable, Sendable {
  case temperatureC, windKmh, gustKmh, precipitationMm, humidityPercent, pressureHpa
  var id: String { rawValue }
  var title: String {
    switch self {
    case .temperatureC: "Temperature"
    case .windKmh: "Wind"
    case .gustKmh: "Gusts"
    case .precipitationMm: "Precipitation · past hour"
    case .humidityPercent: "Humidity"
    case .pressureHpa: "Sea-level pressure"
    }
  }
  var unit: String {
    switch self {
    case .temperatureC: "°C"
    case .windKmh, .gustKmh: "km/h"
    case .precipitationMm: "mm"
    case .humidityPercent: "%"
    case .pressureHpa: "hPa"
    }
  }
}

struct WeatherStation: Decodable, Identifiable, Sendable {
  struct Observation: Decodable, Sendable {
    struct Quality: Decodable, Sendable {
      let state: String
      let sourceField: String
      let unit: String?
    }
    struct Interval: Decodable, Sendable {
      let start: Date
      let end: Date
    }
    let observedAt: Date
    let expiresAt: Date
    let expectedIntervalMinutes: Int
    let values: [String: Double?]
    let quality: [String: Quality]
    let intervals: [String: Interval]
  }
  let id: String
  let name: String
  let longitude: Double
  let latitude: Double
  let elevationM: Double?
  let source: String
  let attribution: String
  let distanceKm: Double?
  let stale: Bool
  let observation: Observation
  var isStale: Bool { stale || observation.expiresAt < Date() }
  func value(_ field: StationField) -> Double? { observation.values[field.rawValue] ?? nil }
  func formatted(_ field: StationField) -> String {
    if let value = value(field) {
      return "\(value.formatted(.number.precision(.fractionLength(0...1)))) \(field.unit)"
    }
    return observation.quality[field.rawValue]?.state == "trace" ? "Trace" : "Unavailable"
  }
}

struct StationCollection: Decodable, Sendable {
  let generatedAt: Date
  let items: [WeatherStation]
  let nextOffset: Int?
}

struct StationHistory: Decodable, Sendable {
  struct Item: Decodable, Identifiable, Sendable {
    let time: Date
    let value: Double?
    var id: Date { time }
  }
  let stationId: String
  let field: String
  let items: [Item]
}

extension WeatherAPI {
  func forecastChanges(areaID: String) async throws -> ForecastChanges {
    try await get(
      "/api/v1/forecast/changes",
      query: [
        .init(name: "area_id", value: areaID), .init(name: "include_forecasts", value: "true"),
      ])
  }
  func nearbyStations(longitude: Double, latitude: Double) async throws -> StationCollection {
    try await get(
      "/api/v1/observations/nearby",
      query: [
        .init(name: "longitude", value: String(longitude)),
        .init(name: "latitude", value: String(latitude)),
      ])
  }
  func weatherStations(bounds: [Double], field: StationField, offset: Int = 0) async throws
    -> StationCollection
  {
    try await get(
      "/api/v1/observations/stations",
      query: [
        .init(name: "bbox", value: bounds.map { String($0) }.joined(separator: ",")),
        .init(name: "field", value: field.rawValue), .init(name: "offset", value: String(offset)),
      ])
  }
  func stationHistory(id: String, field: StationField) async throws -> StationHistory {
    try await get(
      "/api/v1/observations/stations/\(id)/history",
      query: [.init(name: "field", value: field.rawValue)])
  }
}
