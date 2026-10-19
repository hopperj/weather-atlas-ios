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
      && TimeZone(identifier: timeZone) != nil && siteName.count <= 120
  }
}

@MainActor final class GolfSettingsStore: ObservableObject {
  @Published private(set) var value: GolfPreferences
  @Published private(set) var rounds: [GolfRound]
  private let defaults: UserDefaults
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.arguments.contains("-golfResetSavedRounds") {
        defaults.removeObject(forKey: "golfRounds:v1")
        defaults.removeObject(forKey: "golfPreferences:v1")
      }
    #endif
    value =
      defaults.data(forKey: "golfPreferences:v1").flatMap {
        try? JSONDecoder().decode(GolfPreferences.self, from: $0)
      }.flatMap { $0.isValid ? $0 : nil } ?? GolfPreferences()
    let saved =
      defaults.data(forKey: "golfRounds:v1").flatMap {
        try? JSONDecoder().decode([RestoredGolfRound].self, from: $0).compactMap(\.round)
      } ?? []
    var seen = Set<UUID>()
    rounds = Self.chronologicalRounds(saved.filter { $0.isValid && seen.insert($0.id).inserted })
  }
  func save(_ next: GolfPreferences) {
    guard next.isValid, let data = try? JSONEncoder().encode(next) else { return }
    value = next
    defaults.set(data, forKey: "golfPreferences:v1")
  }
  @discardableResult func saveRound(_ round: GolfRound) -> Bool {
    guard round.isValid else { return false }
    var next = rounds.filter { $0.id != round.id }
    next.append(round)
    next = Self.chronologicalRounds(next)
    guard let data = try? JSONEncoder().encode(next) else { return false }
    defaults.set(data, forKey: "golfRounds:v1")
    rounds = next
    return true
  }
  func deleteRound(_ id: UUID) {
    let next = rounds.filter { $0.id != id }
    guard let data = try? JSONEncoder().encode(next) else { return }
    defaults.set(data, forKey: "golfRounds:v1")
    rounds = next
  }

  /// Count saved rounds, not editor taps or repeated saves of the same round.
  var frequentCourses: [GolfCourse] {
    let groups = Dictionary(grouping: rounds.filter(\.isValid), by: { $0.course.bookingKey })
    let ranked = groups.map { key, rounds in
      let latest = Self.chronologicalRounds(rounds).last!
      return (course: latest.course, count: rounds.count, latest: latest.teeDate!, key: key)
    }.sorted {
      if $0.count != $1.count { return $0.count > $1.count }
      if $0.latest != $1.latest { return $0.latest > $1.latest }
      return $0.key < $1.key
    }
    return ranked.prefix(5).map(\.course)
  }

  private static func chronologicalRounds(_ rounds: [GolfRound]) -> [GolfRound] {
    rounds.sorted {
      // Compare actual instants, not wall-clock strings from different provinces.
      let first = $0.teeDate ?? .distantFuture
      let second = $1.teeDate ?? .distantFuture
      // Keep simultaneous rounds stable even when an edit upserts one of them.
      return first == second ? $0.id.uuidString < $1.id.uuidString : first < second
    }
  }
}

/// A damaged record must not discard the other independently saved tee times.
private struct RestoredGolfRound: Decodable {
  let round: GolfRound?
  init(from decoder: any Decoder) throws { round = try? GolfRound(from: decoder) }
}

struct GolfCourse: Codable, Hashable, Identifiable, Sendable {
  enum Kind: String, Codable, Sendable { case course, pin }
  var name: String
  let locality: String
  let latitude: Double
  let longitude: Double
  let timeZone: String
  let countryCode: String
  let kind: Kind
  var id: String { "\(latitude)|\(longitude)|\(name)" }
  var bookingKey: String {
    let title = name.folding(
      options: [.caseInsensitive, .diacriticInsensitive], locale: .init(identifier: "en_US_POSIX")
    )
    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    // Ignore insignificant coordinate/name formatting changes in repeated searches.
    return "\(title)|\((latitude * 100_000).rounded())|\((longitude * 100_000).rounded())"
  }
  var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
  var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }
  var isValid: Bool {
    countryCode == "CA" && CLLocationCoordinate2DIsValid(coordinate)
      && latitude.isFinite && longitude.isFinite && TimeZone(identifier: timeZone) != nil
      && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120
      && locality.count <= 160
  }
}

/// Store the course-local date and wall-clock time, not a transient screen date.
/// A clock-change gap is rejected instead of silently moving the tee time.
struct GolfRound: Codable, Hashable, Identifiable, Sendable {
  var id = UUID()
  var course: GolfCourse
  var localDate: String
  var teeHour: Int
  var teeMinute: Int
  var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = course.zone
    return calendar
  }
  var teeTime: String { String(format: "%02d:%02d", teeHour, teeMinute) }
  var teeDate: Date? {
    let values = localDate.split(separator: "-").compactMap { Int($0) }
    guard values.count == 3, localDate.count == 10,
      (0...23).contains(teeHour), (0...59).contains(teeMinute),
      let date = calendar.date(
        from: DateComponents(
          year: values[0], month: values[1], day: values[2], hour: teeHour, minute: teeMinute))
    else { return nil }
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    guard parts.year == values[0], parts.month == values[1], parts.day == values[2],
      parts.hour == teeHour, parts.minute == teeMinute,
      Self.dateString(date, zone: course.zone) == localDate
    else { return nil }
    return date
  }
  var isValid: Bool { course.isValid && teeDate != nil }
  static func dateString(_ date: Date, zone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }
  enum Availability: Equatable { case ready, pending, passed, invalid }
  func availability(at now: Date = Date()) -> Availability {
    guard let teeDate, isValid else { return .invalid }
    guard teeDate > now else { return .passed }
    let days =
      calendar.dateComponents(
        [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: teeDate)
      ).day ?? 0
    return days <= 6 ? .ready : .pending
  }
  func preferences(limits: GolfLimits) -> GolfPreferences {
    GolfPreferences(
      limits: limits, latitude: course.latitude, longitude: course.longitude,
      siteName: course.name, teeHour: teeHour, teeMinute: teeMinute, timeZone: course.timeZone)
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

enum GolfRating: String, CaseIterable, Codable, Sendable {
  case excellent, good, mixed, poor
  case veryPoor = "very_poor"
  var label: String {
    switch self {
    case .excellent: "Excellent"
    case .good: "Good"
    case .mixed: "Mixed"
    case .poor: "Poor"
    case .veryPoor: "Very poor"
    }
  }
  var column: Int { Self.allCases.firstIndex(of: self)! }
  var colour: Color {
    switch self {
    case .excellent, .good: .teal
    case .mixed: .orange
    case .poor, .veryPoor: .red
    }
  }
}

enum GolfIssue: String, Codable, Sendable {
  case wind, cold, heat, rain
  var label: String {
    switch self {
    case .wind: "Wind"
    case .cold: "Cold"
    case .heat: "Heat"
    case .rain: "Rain or rain risk"
    }
  }
  var atlasRow: Int {
    switch self {
    case .wind: 1
    case .cold: 2
    case .rain: 3
    case .heat: 0
    }
  }
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
  var rating: String? = nil
  var primaryIssue: String? = nil
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
  var outlookRating: GolfRating? {
    guard ["within", "outside", "partial"].contains(state), score != nil else { return nil }
    return rating.flatMap(GolfRating.init(rawValue:))
  }
  var outlookIssue: GolfIssue? {
    guard let outlookRating, outlookRating.column >= 2 else { return nil }
    return primaryIssue.flatMap(GolfIssue.init(rawValue:))
  }
  var qualitativeOpening: String? {
    guard let outlookRating else { return nil }
    switch outlookRating {
    case .excellent: return "Excellent golf weather, comfortably within your preferences."
    case .good: return "Good golf weather overall, with a few possible drawbacks."
    case .mixed: return "Mixed golf weather, with some noticeable drawbacks."
    case .poor: return "Poor golf weather for your preferences."
    case .veryPoor: return "Very poor golf weather for your preferences."
    }
  }
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
    if let qualitativeOpening {
      return
        "\(qualitativeOpening) \(briefingDetail ?? "Review the round details for the weather and preference checks.")"
    }
    return switch state {
    case "within", "partial":
      "The forecast fits your playing preferences. \(briefingDetail ?? "Temperature, wind and precipitation fit your limits before, during and after the round.")"
    case "outside":
      "Some forecast conditions exceed your weather limits. \(briefingDetail ?? "Review the round details to see which conditions are limiting.")"
    case "started":
      "This tee time has passed. Choose a later time or review an upcoming day."
    case "invalid_time":
      "This local tee time does not exist on this date because of a clock change. Choose another time."
    case "stale":
      "A recent model forecast is unavailable for this point. No outlook can be provided yet."
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
  func golfOutlook(_ preferences: GolfPreferences, firstDate: String, days: Int = 7) async throws
    -> GolfOutlook
  {
    let p = preferences
    return try await get(
      "/api/v1/golf/outlook",
      query: [
        .init(name: "latitude", value: String(p.latitude)),
        .init(name: "longitude", value: String(p.longitude)),
        .init(name: "local_date", value: firstDate), .init(name: "tee_time", value: p.teeTime),
        .init(name: "time_zone", value: p.timeZone), .init(name: "days", value: String(days)),
        .init(name: "min_temperature_c", value: String(p.limits.minTemperatureC)),
        .init(name: "max_temperature_c", value: String(p.limits.maxTemperatureC)),
        .init(name: "max_wind_kmh", value: String(p.limits.maxWindKmh)),
        .init(name: "max_rain_mm", value: String(p.limits.maxRainMm)),
        .init(name: "max_pop_percent", value: String(p.limits.maxPopPercent)),
      ], timeout: 55)
  }
}

protocol GolfOutlookServing: Sendable {
  var baseURL: URL { get }
  func golfOutlook(_ preferences: GolfPreferences, firstDate: String, days: Int) async throws
    -> GolfOutlook
}
extension WeatherAPI: GolfOutlookServing {}

@MainActor final class GolfModel: ObservableObject {
  @Published private(set) var outlook: GolfOutlook?
  @Published private(set) var loading = false
  @Published private(set) var error: String?
  @Published private(set) var narratives: [String: ForecastSummaryModel] = [:]
  private var scope: String?
  private var ticket = UUID()
  @Published private(set) var availability: GolfRound.Availability = .pending

  func currentOutlook(for round: GolfRound, limits: GolfLimits) -> GolfOutlook? {
    guard round.availability() == .ready, let outlook,
      outlook.latitude == round.course.latitude, outlook.longitude == round.course.longitude,
      outlook.timeZone == round.course.timeZone, outlook.limits == limits,
      outlook.days.count == 1, let day = outlook.days.first,
      day.date == round.localDate, day.teeTime == round.teeDate
    else { return nil }
    return outlook
  }

  func load(round: GolfRound, limits: GolfLimits, api: any GolfOutlookServing, now: Date = Date())
    async
  {
    availability = round.availability(at: now)
    guard availability == .ready else {
      cancel()
      outlook = nil
      error = nil
      narratives = [:]
      return
    }
    await load(preferences: round.preferences(limits: limits), firstDate: round.localDate, api: api)
  }

  func load(preferences: GolfPreferences, firstDate: String, api: any GolfOutlookServing) async {
    guard preferences.isValid else {
      cancel()
      outlook = nil
      return
    }
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
      let result = try await api.golfOutlook(preferences, firstDate: firstDate, days: 1)
      guard !Task.isCancelled, ticket == request else { return }
      guard result.latitude == preferences.latitude, result.longitude == preferences.longitude,
        result.timeZone == preferences.timeZone, result.limits == preferences.limits,
        result.days.count == 1, result.days.first?.date == firstDate,
        let day = result.days.first,
        GolfRound.dateString(day.teeTime, zone: TimeZone(identifier: preferences.timeZone)!)
          == firstDate
      else { throw URLError(.cannotParseResponse) }
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: preferences.timeZone)!
      guard calendar.component(.hour, from: day.teeTime) == preferences.teeHour,
        calendar.component(.minute, from: day.teeTime) == preferences.teeMinute
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
    for narrative in narratives.values { narrative.cancel() }
  }
}
