import CryptoKit
import Foundation

/// Shared by the app and widget extension. Production never reads an endpoint
/// from preferences, widget files, deep links or launch arguments.
enum WeatherAtlasEndpoint {
  static let productionURL = URL(string: "https://weatheratlas.ioresearch.ca")!
  static let legacyAddresses = [
    "http://wolf359.iolan:18080", "http://wolf359.iolan:8080",
    "http://weatheratlas.ioresearch.ca", "https://weatheratlas.ioresearch.ca:8443",
    "http://localhost:18080", "http://localhost:8080",
    "http://127.0.0.1:18080", "http://127.0.0.1:8080",
    "http://10.0.0.146:18080", "https://wolf359.iolan:8443",
  ]

  static func normalized(_ value: String) -> String? {
    guard var parts = URLComponents(string: value),
      ["https", "http"].contains(parts.scheme), let host = parts.host,
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
      parts.path.isEmpty || parts.path == "/"
    else { return nil }
    parts.host = host.lowercased()
    if parts.port == (parts.scheme == "https" ? 443 : 80) { parts.port = nil }
    parts.path = ""
    return parts.url?.absoluteString
  }

  static func isKnownService(_ value: String) -> Bool {
    guard let address = normalized(value) else { return false }
    return address == productionURL.absoluteString || legacyAddresses.contains(address)
  }

  #if DEBUG && targetEnvironment(simulator)
    /// Narrow, explicit simulator fixture override; absent from device/Release builds.
    static func fixtureURL(_ value: String) -> URL? {
      guard let address = normalized(value), let url = URL(string: address),
        url.scheme == "http", ["localhost", "127.0.0.1"].contains(url.host),
        url.port == 8097
      else { return nil }
      return url
    }
  #endif

  static func launchURL(arguments: [String] = ProcessInfo.processInfo.arguments) -> URL {
    #if DEBUG && targetEnvironment(simulator)
      if let index = arguments.firstIndex(of: "-weatherAtlasTestServerURL"),
        arguments.indices.contains(index + 1), let url = fixtureURL(arguments[index + 1])
      {
        return url
      }
    #endif
    return productionURL
  }

  static func widgetURL(for storedAddress: String) -> URL? {
    #if DEBUG && targetEnvironment(simulator)
      if let url = fixtureURL(storedAddress) { return url }
    #endif
    return isKnownService(storedAddress) ? productionURL : nil
  }

  static func widgetSettings(_ old: WidgetSettings) -> WidgetSettings {
    guard let url = widgetURL(for: old.server) else {
      // An unrelated custom server may use incompatible region identifiers.
      return WidgetSettings(server: productionURL.absoluteString, saved: [])
    }
    var result = old
    result.server = url.absoluteString
    return result
  }
}

struct WidgetForecast: Codable, Sendable {
  struct Hour: Codable, Identifiable, Sendable {
    let time: Date
    let temperatureC: Double?
    let precipitationMm: Double?
    var id: Date { time }
  }
  struct Entry: Codable, Sendable {
    let date: Date
    let validUntil: Date
    let temperatureC: Double?
    let highC: Double?
    let lowC: Double?
    let condition: String
    let symbol: String
    let popPercent: Double?
    let precipitationMm: Double?
    let hours: [Hour]
  }
  let schemaVersion: Int
  let regionId: String
  let name: String
  let issuedAt: Date
  let modelIssuedAt: Date?
  let generatedAt: Date
  let expiresAt: Date
  let nextRefreshAt: Date
  let source: String
  let entries: [Entry]
  let contentVersion: String?
  let stale: Bool?
  var locality: String? = nil
  var displayName: String { ForecastLocationName.display(name, locality: locality) }

  func entry(at date: Date) -> Entry? {
    guard schemaVersion == 1, date < expiresAt else { return nil }
    return entries.last { $0.date <= date && date < $0.validUntil }
  }
}

struct WidgetLocationRecord: Codable, Hashable, Sendable {
  let id: String
  let name: String
  var displayName: String { ForecastLocationName.display(name) }
}

struct WidgetSettings: Codable, Sendable {
  var server: String
  var defaultLocation: WidgetLocationRecord?
  var lastLocation: WidgetLocationRecord?
  var saved: [WidgetLocationRecord]
}

enum WidgetDataStore {
  static let group = "group.com.ior.weatheratlas"
  static let kind = "WeatherAtlasForecast"
  static var container: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
  }

  static func decoder() -> JSONDecoder {
    let result = JSONDecoder()
    result.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) {
        return date
      }
      if let date = try? Date.ISO8601FormatStyle().parse(value) { return date }
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
    }
    return result
  }
  static func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
  }
  static func settings() -> WidgetSettings? {
    guard let url = container?.appendingPathComponent("widget-settings-v1.json"),
      let data = try? Data(contentsOf: url)
    else { return nil }
    return (try? decoder().decode(WidgetSettings.self, from: data)).map(
      WeatherAtlasEndpoint.widgetSettings)
  }
  @discardableResult static func saveSettings(_ value: WidgetSettings) -> Bool {
    guard let url = container?.appendingPathComponent("widget-settings-v1.json"),
      let data = try? encoded(WeatherAtlasEndpoint.widgetSettings(value))
    else { return false }
    if (try? Data(contentsOf: url)) == data { return false }
    do {
      try data.write(
        to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      return true
    } catch { return false }
  }
  static func cacheURL(server: String, regionID: String, directory: URL? = container) -> URL? {
    let key = SHA256.hash(data: Data("\(server)|\(regionID)|v1".utf8))
      .map { String(format: "%02x", $0) }.joined()
    return directory?.appendingPathComponent("widget-\(key).json")
  }
  static func read(server: String, regionID: String, directory: URL? = container) -> WidgetForecast?
  {
    guard let url = cacheURL(server: server, regionID: regionID, directory: directory),
      let data = try? Data(contentsOf: url), data.count <= 256 * 1024,
      let result = try? decoder().decode(WidgetForecast.self, from: data),
      result.schemaVersion == 1, result.regionId == regionID
    else { return nil }
    return result
  }
  @discardableResult static func save(
    _ payload: WidgetForecast, server: String, directory: URL? = container
  ) -> Bool {
    guard payload.schemaVersion == 1, payload.entries.count <= 48,
      let url = cacheURL(server: server, regionID: payload.regionId, directory: directory),
      let data = try? encoded(payload), data.count <= 256 * 1024
    else { return false }
    var changed = false
    var error: NSError?
    // Coordinates the compare-and-replace across the app and extension processes.
    NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) {
      target in
      if let old = read(server: server, regionID: payload.regionId, directory: directory),
        old.generatedAt >= payload.generatedAt
          || (old.contentVersion != nil && old.contentVersion == payload.contentVersion)
      {
        return
      }
      do {
        try data.write(
          to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        changed = true
      } catch {}
    }
    return changed
  }
}

final class WidgetServerPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  let baseURL: URL
  init(_ url: URL) { baseURL = url }
  static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.scheme == rhs.scheme && lhs.host?.lowercased() == rhs.host?.lowercased()
      && (lhs.port ?? (lhs.scheme == "https" ? 443 : 80))
        == (rhs.port ?? (rhs.scheme == "https" ? 443 : 80))
      && lhs.user == nil && lhs.password == nil
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(request.url.map { Self.sameOrigin($0, baseURL) } == true ? request : nil)
  }
}

enum WidgetServerClient {
  static func fetch(server: String, regionID: String?) async throws -> WidgetForecast {
    guard let url = WeatherAtlasEndpoint.widgetURL(for: server),
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { throw URLError(.badURL) }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 12
    config.timeoutIntervalForResource = 15
    let session = URLSession(
      configuration: config, delegate: WidgetServerPolicy(url), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    func request<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
      var target = parts
      target.path = path
      target.queryItems = query
      var request = URLRequest(url: target.url!, cachePolicy: .reloadIgnoringLocalCacheData)
      request.setValue("application/json", forHTTPHeaderField: "Accept")
      let (bytes, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200,
        response.url.map({ WidgetServerPolicy.sameOrigin($0, url) }) == true,
        bytes.count <= 256 * 1024
      else { throw URLError(.badServerResponse) }
      return try WidgetDataStore.decoder().decode(T.self, from: bytes)
    }
    var area = regionID
    if area == nil {
      struct Match: Decodable {
        struct Region: Decodable {
          let id: String
          let name: String
        }
        let region: Region
      }
      let nearby: Match = try await request(
        "/api/v1/forecast/nearest",
        query: [
          .init(name: "longitude", value: "-63.57"), .init(name: "latitude", value: "44.65"),
        ])
      guard nearby.region.name.lowercased().contains("halifax") else {
        throw URLError(.badServerResponse)
      }
      area = nearby.region.id
    }
    let payload: WidgetForecast = try await request(
      "/api/v1/widgets/forecast", query: [.init(name: "area_id", value: area)])
    guard payload.schemaVersion == 1, payload.regionId == area, payload.entries.count <= 48 else {
      throw URLError(.badServerResponse)
    }
    return payload
  }
}
