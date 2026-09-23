import Foundation
import OSLog

enum WeatherDiagnostics {
  static let startup = Logger(subsystem: "com.ior.weatheratlas", category: "startup")
  static let network = Logger(subsystem: "com.ior.weatheratlas", category: "network")
}

/// Every weather request stays on the configured server, including redirects and tiles.
struct WeatherAPI: Sendable {
  let baseURL: URL
  private let transport: WeatherTransport
  var session: URLSession { transport.session }

  init(baseURL: URL, session: URLSession? = nil) {
    self.baseURL = baseURL
    transport = WeatherTransport(baseURL: baseURL, session: session)
  }

  fileprivate static var configuration: URLSessionConfiguration {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 25
    config.timeoutIntervalForResource = 60
    config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 64 * 1024 * 1024)
    return config
  }

  static func validatedBaseURL(_ text: String) throws -> URL {
    guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let scheme = parts.scheme, ["https", "http"].contains(scheme),
      let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil,
      parts.path.isEmpty || parts.path == "/", let url = parts.url
    else {
      throw WeatherAPIError.invalidBaseURL
    }
    return url
  }

  func products() async throws -> [Product] { try await collection("/api/v1/products") }
  func domains(product: String) async throws -> [Domain] {
    try await collection("/api/v1/products/\(product)/domains")
  }
  func fields(product: String) async throws -> [WeatherField] {
    try await collection("/api/v1/products/\(product)/fields")
  }
  func timeline(product: String, domain: String, field: String, past: Bool = false) async throws
    -> TimelineResponse
  {
    var query: [URLQueryItem] = [
      .init(name: "domain", value: domain), .init(name: "field", value: field),
      .init(name: "limit", value: "1000"),
    ]
    if past {
      query += [
        .init(name: "start", value: Date().addingTimeInterval(-7 * 86400).ISO8601Format()),
        .init(name: "end", value: Date().ISO8601Format()),
      ]
    }
    return try await get("/api/v1/products/\(product)/timeline", query: query)
  }
  func resolveLayer(product: String, domain: String, frame: TimelineFrame, field: String)
    async throws -> ResolvedLayer
  {
    try await get(
      "/api/v1/layers/resolve",
      query: [
        .init(name: "product", value: product), .init(name: "domain", value: domain),
        .init(name: "run", value: frame.runTime.ISO8601Format()),
        .init(name: "field", value: field),
        .init(name: "valid_time", value: frame.validTime.ISO8601Format()),
        .init(name: "format", value: "png"), .init(name: "style", value: "default"),
      ])
  }
  func sample(
    product: String, domain: String, frame: TimelineFrame, fields: [String], longitude: Double,
    latitude: Double
  ) async throws -> SampleResponse {
    var query: [URLQueryItem] = [
      .init(name: "product", value: product), .init(name: "domain", value: domain),
      .init(name: "run", value: frame.runTime.ISO8601Format()),
      .init(name: "valid_time", value: frame.validTime.ISO8601Format()),
      .init(name: "longitude", value: String(longitude)),
      .init(name: "latitude", value: String(latitude)),
    ]
    query += fields.map { .init(name: "field", value: $0) }
    return try await get("/api/v1/sample", query: query)
  }
  func forecastRegions() async throws -> ForecastRegionsResponse {
    try await get("/api/v1/forecast/regions")
  }
  func halifaxForecast() async throws -> ForecastRegion? {
    do {
      let nearby = try await nearestForecast(longitude: -63.57, latitude: 44.65)
      // A default coordinate lookup must never silently choose another region.
      return nearby.region.isHalifaxMetro ? nearby.region : nil
    } catch WeatherAPIError.server(let status, let detail)
      where status == 404 && detail == "Not Found"
    {
      return try await forecastRegions().regions.first(where: \.isHalifaxMetro)
    }
  }
  func defaultForecast(at place: SavedPlace) async throws -> ForecastRegion? {
    do {
      let nearby = try await nearestForecast(longitude: place.longitude, latitude: place.latitude)
      if nearby.region.id == place.id { return nearby.region }
    } catch WeatherAPIError.server(let status, _) where status == 404 {
      // Older servers and changed regional coverage can require the full catalogue.
    }
    // Never substitute a different region for the user's saved default.
    return try await forecastRegions().regions.first { $0.id == place.id }
  }
  func hourlyForecast(areaID: String) async throws -> HourlyForecast {
    try await get("/api/v1/forecast/hourly", query: [.init(name: "area_id", value: areaID)])
  }
  func precipitationForecast(areaID: String) async throws -> PrecipitationForecast {
    try await get("/api/v1/forecast/precipitation", query: [.init(name: "area_id", value: areaID)])
  }
  func imagery() async throws -> ImageryCatalogue { try await get("/api/v1/imagery") }
  func hotspots(date: String) async throws -> HotspotCollection {
    try await get("/api/v1/hotspots", query: date.isEmpty ? [] : [.init(name: "date", value: date)])
  }
  func hotspotDates() async throws -> HotspotDates { try await get("/api/v1/hotspots/dates") }
  func wind(product: String, domain: String, frame: TimelineFrame, bounds: [Double]) async throws
    -> WindCollection
  {
    try await get(
      "/api/v1/wind-vectors",
      query: [
        .init(name: "product", value: product), .init(name: "domain", value: domain),
        .init(name: "run", value: frame.runTime.ISO8601Format()),
        .init(name: "valid_time", value: frame.validTime.ISO8601Format()),
        .init(name: "west", value: String(bounds[0])),
        .init(name: "south", value: String(bounds[1])),
        .init(name: "east", value: String(bounds[2])),
        .init(name: "north", value: String(bounds[3])),
        .init(name: "columns", value: "12"), .init(name: "rows", value: "10"),
      ])
  }
  func nearestForecast(longitude: Double, latitude: Double) async throws -> NearbyForecast {
    try await get(
      "/api/v1/forecast/nearest",
      query: [
        .init(name: "longitude", value: String(longitude)),
        .init(name: "latitude", value: String(latitude)),
      ])
  }

  /// Preserve template braces for the map tile renderer.
  func tileTemplate(_ template: String) throws -> String {
    let probe = template.replacingOccurrences(of: "{z}", with: "0")
      .replacingOccurrences(of: "{x}", with: "0").replacingOccurrences(of: "{y}", with: "0")
    guard let url = URL(string: probe, relativeTo: baseURL)?.absoluteURL,
      Self.sameOrigin(url, baseURL), template.contains("{z}"),
      template.contains("{x}"), template.contains("{y}")
    else { throw WeatherAPIError.externalResource }
    if template.hasPrefix("/") && !template.hasPrefix("//") {
      return baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        + template
    }
    guard template.hasPrefix(baseURL.scheme! + "://") else {
      throw WeatherAPIError.externalResource
    }
    return template
  }

  static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    func port(_ url: URL) -> Int { url.port ?? (url.scheme == "https" ? 443 : 80) }
    return lhs.scheme == rhs.scheme && lhs.host?.lowercased() == rhs.host?.lowercased()
      && port(lhs) == port(rhs) && lhs.user == nil && lhs.password == nil
  }

  private func collection<T: Decodable & Sendable>(_ path: String) async throws -> [T] {
    let value: APICollection<T> = try await get(path)
    return value.items
  }
  func get<T: Decodable & Sendable>(
    _ path: String, query: [URLQueryItem] = [], timeout: TimeInterval? = nil
  ) async throws -> T {
    let started = ContinuousClock.now
    guard var parts = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw WeatherAPIError.invalidBaseURL
    }
    parts.path = path
    parts.queryItems = query.isEmpty ? nil : query
    guard let url = parts.url else { throw WeatherAPIError.invalidBaseURL }
    var request = URLRequest(url: url)
    if let timeout { request.timeoutInterval = timeout }
    // The explicit forecast snapshot provides instant display. Refreshes must
    // actually check the server rather than reuse a still-fresh HTTP response.
    if path.hasPrefix("/api/v1/forecast/") {
      request.cachePolicy = .reloadIgnoringLocalCacheData
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: request)
    let received = ContinuousClock.now
    guard let http = response as? HTTPURLResponse else { throw WeatherAPIError.invalidResponse }
    guard 200..<300 ~= http.statusCode else {
      let message =
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
      throw WeatherAPIError.server(status: http.statusCode, message: message)
    }
    let result = try Self.decoder().decode(T.self, from: data)
    // Only the endpoint path is logged: never GPS query parameters or credentials.
    WeatherDiagnostics.network.debug(
      "\(path, privacy: .public): received \(data.count) bytes in \(String(describing: started.duration(to: received)), privacy: .public); decoded in \(String(describing: received.duration(to: .now)), privacy: .public)"
    )
    return result
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    // Value-type parsers avoid constructing thousands of ICU date formatters.
    let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      if let date = try? whole.parse(value) { return date }
      if let date = try? fractional.parse(value) { return date }
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid ISO-8601 timestamp")
    }
    return decoder
  }
}

/// No URLSession/cache disk setup during SwiftUI construction. A single transport
/// is shared by copies of an API, and initialized on its first network request.
private final class WeatherTransport: @unchecked Sendable {
  private let lock = NSLock()
  private let baseURL: URL
  private var storedSession: URLSession?
  init(baseURL: URL, session: URLSession?) {
    self.baseURL = baseURL
    storedSession = session
  }
  var session: URLSession {
    lock.lock()
    defer { lock.unlock() }
    if let storedSession { return storedSession }
    let created = URLSession(
      configuration: WeatherAPI.configuration,
      delegate: ServerRedirectPolicy(baseURL: baseURL), delegateQueue: nil)
    storedSession = created
    return created
  }
}

final class ServerRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  let baseURL: URL
  init(baseURL: URL) { self.baseURL = baseURL }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(
      request.url.map { WeatherAPI.sameOrigin($0, baseURL) } == true ? request : nil)
  }
}

enum WeatherAPIError: LocalizedError {
  case invalidBaseURL, invalidResponse, externalResource
  case server(status: Int, message: String?)
  var errorDescription: String? {
    switch self {
    case .invalidBaseURL:
      "Enter an HTTP or HTTPS server address, such as http://wolf359.iolan:18080, without a path, query or embedded credentials."
    case .invalidResponse: "The server returned an invalid response."
    case .externalResource: "This layer points outside your Weather Atlas server."
    case .server(let status, let message):
      message ?? "The server could not supply this data (HTTP \(status))."
    }
  }
}
