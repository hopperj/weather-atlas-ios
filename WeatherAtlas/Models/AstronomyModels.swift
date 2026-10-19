import CoreLocation
import Foundation

struct ObservingSite: Codable, Hashable, Identifiable, Sendable {
  var name: String
  let latitude: Double
  let longitude: Double
  var id: String { "\(latitude)|\(longitude)" }
  var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
  var isValid: Bool { CLLocationCoordinate2DIsValid(coordinate) && name.count <= 120 }
}

struct AstronomyForecast: Decodable, Sendable {
  struct Interval: Decodable, Sendable, Identifiable {
    let start: Date
    let end: Date
    let minutes: Int
    var id: Date { start }
  }
  struct Night: Decodable, Sendable, Identifiable {
    let date: String
    let start: Date
    let end: Date
    let state: String
    let summary: String
    let events: [String: Date?]
    let darkness: [Interval]
    let moonlessDarkness: [Interval]
    let windows: [Interval]
    let moonIlluminatedPercent: Double
    let moonPhaseName: String?
    var id: String { date }
    var bestWindow: Interval? { windows.max { $0.minutes < $1.minutes } }
  }
  struct Frame: Decodable, Sendable, Identifiable {
    let time: Date
    let cloudPercent: Double?
    let temperatureC: Double?
    let humidityPercent: Double?
    let dewPointC: Double?
    let dewRisk: Bool?
    let windKmh: Double?
    let gustKmh: Double?
    let rainMm: Double?
    let rainStart: Date?
    let sunAltitudeDegrees: Double
    let moonAltitudeDegrees: Double
    let moonIlluminatedPercent: Double
    var id: Date { time }
  }
  struct Sample: Decodable, Sendable {
    let latitude: Double
    let longitude: Double
    let pixelSize: [Double]
    let crs: String
  }
  let schemaVersion: Int
  let generatedAt: Date
  let preview: Bool
  let latitude: Double
  let longitude: Double
  let timeZone: String
  let product: String
  let source: String
  let runTime: Date?
  let stale: Bool
  let mode: String
  let ruleVersion: String
  let method: String
  let limitations: [String]
  let sample: Sample?
  let frames: [Frame]
  let nights: [Night]
  var zone: TimeZone { TimeZone(identifier: timeZone) ?? .gmt }
}

extension WeatherAPI {
  func astronomy(site: ObservingSite, product: String, mode: String, cloud: Int, wind: Int)
    async throws -> AstronomyForecast
  {
    guard site.isValid else { throw WeatherAPIError.invalidBaseURL }
    let result: AstronomyForecast = try await get(
      "/api/v1/astronomy/forecast",
      query: [
        .init(name: "latitude", value: String(site.latitude)),
        .init(name: "longitude", value: String(site.longitude)),
        .init(name: "product", value: product), .init(name: "mode", value: mode),
        .init(name: "max_cloud_percent", value: String(cloud)),
        .init(name: "max_wind_kmh", value: String(wind)),
      ], timeout: 60)
    guard result.schemaVersion == 1, abs(result.latitude - site.latitude) < 1e-7,
      abs(result.longitude - site.longitude) < 1e-7, result.product == product,
      result.mode == mode, TimeZone(identifier: result.timeZone) != nil
    else { throw WeatherAPIError.invalidResponse }
    return result
  }
}

@MainActor final class AstronomySettings: ObservableObject {
  @Published private(set) var site: ObservingSite
  @Published private(set) var saved: [ObservingSite]
  @Published var followsGPS: Bool { didSet { defaults.set(followsGPS, forKey: key + ":gps") } }
  private let defaults: UserDefaults
  private let key: String
  init(
    seed: ObservingSite, server: String, defaults: UserDefaults = .standard,
    restoreLast: Bool = true
  ) {
    self.defaults = defaults
    key = "astronomy:v1:\(server)"
    if restoreLast, let data = defaults.data(forKey: key + ":site"),
      let restored = try? JSONDecoder().decode(ObservingSite.self, from: data), restored.isValid
    {
      site = restored
    } else {
      site = seed
    }
    saved =
      defaults.data(forKey: key + ":saved").flatMap {
        try? JSONDecoder().decode([ObservingSite].self, from: $0)
      }?.filter(\.isValid).prefix(30).map { $0 } ?? []
    followsGPS = restoreLast && defaults.bool(forKey: key + ":gps")
  }
  func choose(_ next: ObservingSite, manual: Bool = true) {
    guard next.isValid else { return }
    if manual { followsGPS = false }
    site = next
    defaults.set(try? JSONEncoder().encode(next), forKey: key + ":site")
  }
  func save() {
    saved.removeAll { $0.id == site.id }
    saved.append(site)
    saved = Array(saved.suffix(30))
    persistSaved()
  }
  func remove(_ site: ObservingSite) {
    saved.removeAll { $0.id == site.id }
    persistSaved()
  }
  private func persistSaved() {
    defaults.set(try? JSONEncoder().encode(saved), forKey: key + ":saved")
  }
}
