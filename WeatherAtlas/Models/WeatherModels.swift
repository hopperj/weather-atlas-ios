import CoreLocation
import Foundation

struct APICollection<Item: Decodable & Sendable>: Decodable, Sendable {
  let items: [Item]
}

struct Product: Codable, Hashable, Identifiable, Sendable {
  let code: String
  let name: String
  let description: String?
  let kind: String
  let priority: Int
  let latestRunTime: Date?

  var id: String { code }
}

struct Domain: Codable, Hashable, Identifiable, Sendable {
  let code: String
  let name: String
  let bounds: [Double]?

  var id: String { code }
}

struct PaletteStop: Codable, Hashable, Sendable {
  let value: Double
  let color: String
  let label: String?
}

struct WeatherField: Codable, Hashable, Identifiable, Sendable {
  let code: String
  let variableCode: String
  let name: String
  let variableClass: String
  let levelCode: String
  let levelName: String
  let unit: String
  let palette: [PaletteStop]
  let defaultMin: Double
  let defaultMax: Double

  var id: String { code }
}

struct TimelineResponse: Decodable, Sendable {
  let items: [TimelineFrame]
  let truncated: Bool
}

struct TimelineFrame: Codable, Hashable, Identifiable, Sendable {
  let validTime: Date
  let runTime: Date
  let forecastHour: Int?
  let intervalStart: Date?
  let intervalEnd: Date?
  let timeKind: String

  var id: String { "\(runTime.timeIntervalSince1970)-\(validTime.timeIntervalSince1970)" }
}

struct Legend: Codable, Hashable, Sendable {
  let minimum: Double
  let maximum: Double
  let palette: [PaletteStop]

  /// Use the server's actual colour-stop values, not equal spacing between colours.
  func position(for value: Double) -> Double {
    guard minimum.isFinite, maximum.isFinite, value.isFinite, maximum > minimum else { return 0 }
    return min(1, max(0, (value - minimum) / (maximum - minimum)))
  }
}

struct ResolvedLayer: Codable, Hashable, Sendable {
  let product: String
  let domain: String
  let runTime: Date
  let validTime: Date
  let forecastHour: Int?
  let field: String
  let variable: String
  let level: String
  let unit: String
  let tileUrl: String
  let token: String
  let bounds: [Double]?
  let legend: Legend
}

struct SampleResponse: Codable, Hashable, Identifiable, Sendable {
  var id: String { "\(latitude),\(longitude),\(validTime.timeIntervalSince1970)" }
  let longitude: Double
  let latitude: Double
  let runTime: Date
  let validTime: Date
  let values: [SampleValue]
}

struct ImageryCatalogue: Decodable, Sendable {
  let items: [ImageryProduct]
}

struct NearbyForecast: Decodable, Sendable {
  let region: ForecastRegion
  let distanceKm: Double
  let matchKind: String
}

struct ImageryProduct: Decodable, Identifiable, Sendable {
  let code: String
  let name: String
  let kind: String
  let attribution: String
  let frames: [ImageryFrame]
  let stale: Bool
  var id: String { code }
}

struct ImageryFrame: Decodable, Identifiable, Hashable, Sendable {
  let id: String
  let validTime: Date
  let tileUrl: String
  let bounds: [Double]
  let legendUrl: String?
}

struct SampleValue: Codable, Hashable, Identifiable, Sendable {
  let field: String
  let variable: String
  let level: String
  let value: Double?
  let unit: String
  let nodata: Bool

  var id: String { field }
}

struct ForecastRegionsResponse: Codable, Sendable {
  let generatedAt: Date
  let timeZone: String
  let regions: [ForecastRegion]
}

struct ForecastRegion: Codable, Hashable, Identifiable, Sendable {
  let id: String
  let name: String
  let latitude: Double
  let longitude: Double
  let province: String
  let provinceName: String
  let issuedAt: Date
  let stale: Bool
  let periods: [ForecastPeriod]
  var locality: String? = nil
  var briefing: ForecastBriefing? = nil

  var displayName: String { ForecastLocationName.display(name, locality: locality) }

  var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
  var isHalifaxMetro: Bool {
    province == "NS"
      && ["Halifax Metro and Halifax County West", "Halifax Metro", "Halifax"].contains {
        name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare($0)
          == .orderedSame
      }
  }
}

struct ForecastBriefing: Codable, Hashable, Sendable {
  let overview: String
  let precipitation: String
  let temperatures: String
  let validUntil: Date
  var paragraph: String { [overview, precipitation, temperatures].joined(separator: " ") }
}

struct ForecastPeriod: Codable, Hashable, Identifiable, Sendable {
  let name: String
  let start: Date
  let end: Date
  let temperatureC: Double?
  let temperatureClass: String?
  let relativeHumidityPercent: Double?
  let popPercent: Double?
  let precipitationAmount: String?
  let condition: String

  var id: String { "\(name)-\(start.timeIntervalSince1970)" }

  var weatherIcon: ForecastWeatherIcon {
    let isNight =
      name.localizedCaseInsensitiveContains("night")
      || name.localizedCaseInsensitiveContains("evening")
      || temperatureClass?.lowercased() == "low"
    return ForecastWeatherIcon(condition: condition, isNight: isNight)
  }

  var issuedPrecipitationAmount: String? {
    guard let amount = precipitationAmount?.trimmingCharacters(in: .whitespacesAndNewlines),
      !amount.isEmpty
    else { return nil }
    return amount
  }

  var needsPrecipitationEstimate: Bool {
    // An omitted probability is not zero. Amounts are a separate server product.
    issuedPrecipitationAmount == nil
  }

  var precipitationLikelihoodDescription: String? {
    if let pop = popPercent, pop.isFinite, (0...100).contains(pop) {
      return "\(pop.formatted(.number.precision(.fractionLength(0))))%"
    }
    return precipitationOutlookDescription
  }

  private var precipitationOutlookDescription: String? {
    // Restate recognized bulletin wording, never infer a numerical probability.
    // Keep this conservative: unrecognized/negated descriptions remain untouched.
    var text = condition.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let possible = text.hasPrefix("chance of ") || text.hasPrefix("risk of ")
    for prefix in ["chance of ", "risk of ", "periods of ", "a few "] {
      if text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
    }
    let kind: String
    switch text {
    case "rain", "showers", "rain showers", "drizzle", "rain or drizzle", "drizzle or rain",
      "showers or drizzle":
      kind = "Rain"
    case "snow", "wet snow", "flurries", "snow flurries", "snow showers", "snow and blowing snow":
      kind = "Snow"
    case "rain or snow", "snow or rain", "rain mixed with snow", "snow mixed with rain",
      "wet snow mixed with rain", "flurries or rain showers", "rain showers or flurries",
      "rain showers or wet flurries":
      kind = "Rain or snow"
    case "freezing rain": kind = "Freezing rain"
    case "freezing drizzle": kind = "Freezing drizzle"
    case "ice pellets", "sleet": kind = "Ice pellets"
    case "thunderstorms", "thundershowers": kind = "Thunderstorms"
    case "hail": kind = "Hail"
    default: return nil
    }
    return "\(kind) \(possible ? "possible" : "expected")"
  }

  func precipitationDescription(estimatedMm: Double?, loading: Bool = false) -> String? {
    // Keep issued ranges and units, including snow depth, exactly as supplied.
    if let amount = issuedPrecipitationAmount { return "Precipitation: \(amount)" }
    if let amount = estimatedMm, amount.isFinite, amount >= 0 {
      let number =
        amount > 0 && amount < 0.1
        ? "<0.1" : amount.formatted(.number.precision(.fractionLength(0...1)))
      return "Precipitation: \(number) mm"
    }
    guard (popPercent ?? 0) > 0 || precipitationOutlookDescription != nil else { return nil }
    return loading ? "Precipitation: loading amount…" : "Precipitation: amount unavailable"
  }
}

/// Presentation of the issued description only; never a new weather prediction.
enum ForecastWeatherIcon: CaseIterable, Hashable, Sendable {
  case clearDay, clearNight, partlyCloudyDay, partlyCloudyNight, cloudy
  case rain, drizzle, thunderstorms, snow, sleet, hail, fog, hazeDay, hazeNight, smoke, wind,
    unknown

  init(condition: String, isNight: Bool) {
    let text = condition.lowercased()
    func contains(_ phrases: [String]) -> Bool { phrases.contains { text.contains($0) } }
    let snow = contains(["snow", "flurr", "blizzard"])
    let rain = contains(["rain", "shower", "drizzle"])
    if contains(["thunder", "lightning"]) {
      self = .thunderstorms
    } else if contains(["hail"]) {
      self = .hail
    } else if contains(["freezing rain", "freezing drizzle", "ice pellet", "sleet"])
      || (snow && rain)
    {
      self = .sleet
    } else if snow {
      self = .snow
    } else if contains(["drizzle"]) {
      self = .drizzle
    } else if rain {
      self = .rain
    } else if contains(["fog", "mist"]) {
      self = .fog
    } else if contains(["smoke"]) {
      self = .smoke
    } else if contains(["haze", "hazy"]) {
      self = isNight ? .hazeNight : .hazeDay
    } else if contains([
      "partly cloudy", "cloudy periods", "a few clouds", "sun and cloud", "sunny breaks",
    ]) {
      self = isNight ? .partlyCloudyNight : .partlyCloudyDay
    } else if contains(["cloud", "overcast"]) {
      self = .cloudy
    } else if contains(["sunny", "clear"]) {
      self = isNight ? .clearNight : .clearDay
    } else if contains(["windy", "wind"]) {
      self = .wind
    } else {
      self = .unknown
    }
  }

  var symbolName: String {
    switch self {
    case .clearDay: "sun.max.fill"
    case .clearNight: "moon.stars.fill"
    case .partlyCloudyDay: "cloud.sun.fill"
    case .partlyCloudyNight: "cloud.moon.fill"
    case .cloudy: "cloud.fill"
    case .rain: "cloud.rain.fill"
    case .drizzle: "cloud.drizzle.fill"
    case .thunderstorms: "cloud.bolt.rain.fill"
    case .snow: "cloud.snow.fill"
    case .sleet: "cloud.sleet.fill"
    case .hail: "cloud.hail.fill"
    case .fog: "cloud.fog.fill"
    case .hazeDay: "sun.haze.fill"
    case .hazeNight: "moon.haze.fill"
    case .smoke: "smoke.fill"
    case .wind: "wind"
    case .unknown: "questionmark.circle"
    }
  }

  var label: String {
    switch self {
    case .clearDay: "Sunny"
    case .clearNight: "Clear night"
    case .partlyCloudyDay, .partlyCloudyNight: "Partly cloudy"
    case .cloudy: "Cloudy"
    case .rain: "Rain"
    case .drizzle: "Drizzle"
    case .thunderstorms: "Thunderstorms"
    case .snow: "Snow"
    case .sleet: "Mixed or freezing precipitation"
    case .hail: "Hail"
    case .fog: "Fog"
    case .hazeDay, .hazeNight: "Haze"
    case .smoke: "Smoke"
    case .wind: "Windy"
    case .unknown: "See forecast details"
    }
  }
}

struct PrecipitationForecast: Codable, Sendable {
  let regionId: String
  let issuedAt: Date
  let source: String
  let generatedAt: Date
  let periods: [PrecipitationForecastPeriod]

  func estimatedMm(for period: ForecastPeriod, in region: ForecastRegion) -> Double? {
    // Never attach a total from another region, bulletin, or day/night interval.
    guard regionId == region.id, issuedAt == region.issuedAt,
      let estimate = periods.first(where: { $0.start == period.start && $0.end == period.end }),
      estimate.status == "complete", let run = estimate.runTime, run <= period.start,
      period.end > period.start,
      let amount = estimate.precipitationMm, amount.isFinite, amount >= 0
    else { return nil }
    return amount
  }
}

struct PrecipitationForecastPeriod: Codable, Sendable {
  let start: Date
  let end: Date
  let status: String
  let precipitationMm: Double?
  let runTime: Date?
}

struct HourlyForecast: Codable, Sendable {
  let regionId: String
  let source: String
  let generatedAt: Date
  let start: Date
  let end: Date
  let availableHours: Int
  let completeHours: Int
  let hours: [HourlyForecastHour]
}

struct HourlyForecastHour: Codable, Hashable, Identifiable, Sendable {
  let time: Date
  let runTime: Date?
  let precipitationStart: Date
  let status: String
  let temperatureC: Double?
  let relativeHumidityPercent: Double?
  let precipitationMm: Double?
  let windKmh: Double?
  let gustKmh: Double?

  var id: Date { time }
}

/// Calendar-day ticks use local midnight, not fixed 24-hour steps (DST-safe).
struct HourlyDayAxis {
  let domain: ClosedRange<Date>
  let ticks: [Date]
  private let calendar: Calendar

  init(start: Date, end: Date, calendar: Calendar = .current) {
    self.calendar = calendar
    let firstDay = calendar.startOfDay(for: start)
    let upperBound = max(end, start.addingTimeInterval(1))
    domain = firstDay...upperBound
    var days: [Date] = []
    var day = firstDay
    while day < upperBound {
      days.append(day)
      guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
      day = calendar.startOfDay(for: next)
    }
    ticks = days
  }

  func label(for date: Date, locale: Locale = .current) -> String {
    let style = Date.FormatStyle(
      date: .omitted, time: .omitted, locale: locale, calendar: calendar,
      timeZone: calendar.timeZone)
    let hour = String(format: "%02d", calendar.component(.hour, from: date))
    return date.formatted(style.weekday(.abbreviated)) + "\n"
      + date.formatted(style.month(.abbreviated).day()) + " \(hour)"
  }
}

/// The full range stays uncluttered; progressively closer views expose more hourly detail.
struct HourlyChartScale {
  static func hourStride(visibleDuration: TimeInterval, fullDuration: TimeInterval) -> Int? {
    guard fullDuration > 0, visibleDuration < fullDuration * 0.995 else { return nil }
    if visibleDuration > 48 * 3_600 { return 12 }
    if visibleDuration > 24 * 3_600 { return 6 }
    if visibleDuration > 12 * 3_600 { return 3 }
    return 1
  }
}

/// Display selection only: values are read directly from the server's hourly rows.
enum HourlyPlot: String, CaseIterable, Identifiable, Sendable {
  case temperature, precipitation, wind, gust, humidity

  var id: String { rawValue }

  var columnTitle: String {
    switch self {
    case .temperature: "°C"
    case .precipitation: "Precip mm"
    case .wind: "Wind km/h"
    case .gust: "Gust km/h"
    case .humidity: "RH %"
    }
  }

  var title: String {
    switch self {
    case .temperature: "Temperature"
    case .precipitation: "Precipitation"
    case .wind: "Wind speed"
    case .gust: "Wind gusts"
    case .humidity: "Relative humidity"
    }
  }

  var unit: String {
    switch self {
    case .temperature: "°C"
    case .precipitation: "mm"
    case .wind, .gust: "km/h"
    case .humidity: "%"
    }
  }

  var chartTitle: String { "\(title) (\(unit))" }

  func value(for hour: HourlyForecastHour) -> Double? {
    let value: Double? =
      switch self {
      case .temperature: hour.temperatureC
      case .precipitation: hour.precipitationMm
      case .wind: hour.windKmh
      case .gust: hour.gustKmh
      case .humidity: hour.relativeHumidityPercent
      }
    return value.flatMap { $0.isFinite ? $0 : nil }
  }
}
