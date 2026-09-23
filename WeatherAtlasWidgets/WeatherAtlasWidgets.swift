import AppIntents
import SwiftUI
import WidgetKit

struct ForecastWidgetLocation: AppEntity {
  let id: String
  let name: String
  static var typeDisplayRepresentation: TypeDisplayRepresentation { "Forecast location" }
  static var defaultQuery: LocationQuery { LocationQuery() }
  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct LocationQuery: EntityQuery {
  func suggestedEntities() async throws -> [ForecastWidgetLocation] {
    [
      .init(id: "default", name: "App default location"),
      .init(id: "last", name: "Last app location"),
    ]
      + (WidgetDataStore.settings()?.saved ?? []).map { .init(id: $0.id, name: $0.displayName) }
  }
  func entities(for identifiers: [String]) async throws -> [ForecastWidgetLocation] {
    let choices = try await suggestedEntities()
    return identifiers.map { id in
      choices.first { $0.id == id } ?? .init(id: id, name: "Saved location")
    }
  }
  func defaultResult() async -> ForecastWidgetLocation? {
    .init(id: "default", name: "App default location")
  }
}

struct ForecastWidgetIntent: WidgetConfigurationIntent {
  static var title: LocalizedStringResource { "Forecast location" }
  static var description: IntentDescription {
    "Choose a saved location, the app default, or the last location used in the app. No background GPS is used."
  }
  @Parameter(title: "Location") var location: ForecastWidgetLocation?
}

struct ForecastWidgetEntry: TimelineEntry {
  let date: Date
  let payload: WidgetForecast?
  let weather: WidgetForecast.Entry?
  let message: String?
  let locationMode: String
  var server: String? = nil
  var url: URL? {
    guard let id = payload?.regionId else { return URL(string: "weatheratlas://forecast") }
    var parts = URLComponents()
    parts.scheme = "weatheratlas"
    parts.host = "forecast"
    parts.queryItems = [.init(name: "region", value: id), .init(name: "server", value: server)]
    return parts.url
  }
}

struct ForecastWidgetProvider: AppIntentTimelineProvider {
  typealias Intent = ForecastWidgetIntent
  typealias Entry = ForecastWidgetEntry
  func placeholder(in context: Context) -> Entry {
    Entry(
      date: Date(), payload: nil, weather: nil, message: "Weather Atlas", locationMode: "Forecast")
  }
  func snapshot(for configuration: Intent, in context: Context) async -> Entry {
    await entries(configuration).first ?? placeholder(in: context)
  }
  func timeline(for configuration: Intent, in context: Context) async -> Timeline<Entry> {
    let rows = await entries(configuration)
    return Timeline(entries: rows, policy: .after(Date().addingTimeInterval(45 * 60)))
  }
  private func entries(_ configuration: Intent) async -> [Entry] {
    let now = Date()
    guard let settings = WidgetDataStore.settings() else {
      return [
        Entry(
          date: now, payload: nil, weather: nil,
          message: "Open Weather Atlas to set up your forecast.", locationMode: "Forecast")
      ]
    }
    let choice = configuration.location?.id ?? "default"
    let region =
      choice == "default"
      ? settings.defaultLocation?.id
      : choice == "last" ? settings.lastLocation?.id : choice
    let mode = choice == "last" ? "Last app location" : "Forecast"
    var payload = region.flatMap { WidgetDataStore.read(server: settings.server, regionID: $0) }
    var message: String?
    do {
      let fresh = try await WidgetServerClient.fetch(server: settings.server, regionID: region)
      WidgetDataStore.save(fresh, server: settings.server)
      payload = WidgetDataStore.read(server: settings.server, regionID: fresh.regionId) ?? fresh
    } catch { message = "Saved forecast · temporarily offline" }
    guard let payload else {
      return [
        Entry(
          date: now, payload: nil, weather: nil,
          message: "Check your internet connection and open Weather Atlas.", locationMode: mode)
      ]
    }
    var entries = [
      Entry(
        date: now, payload: payload, weather: payload.entry(at: now),
        message: message, locationMode: mode)
    ]
    for item in payload.entries where item.date > now && item.date < payload.expiresAt {
      entries.append(
        Entry(
          date: item.date, payload: payload, weather: item, message: message, locationMode: mode))
    }
    for item in payload.entries where item.validUntil > now && item.validUntil < payload.expiresAt {
      if payload.entry(at: item.validUntil) == nil {
        entries.append(
          Entry(
            date: item.validUntil, payload: payload, weather: nil,
            message: "Forecast coverage unavailable · open the app", locationMode: mode))
      }
    }
    if payload.expiresAt > now {
      entries.append(
        Entry(
          date: payload.expiresAt, payload: payload, weather: nil,
          message: "Forecast expired · open Weather Atlas to update", locationMode: mode))
    }
    return entries.sorted { $0.date < $1.date }.map { item in
      var result = item
      result.server = settings.server
      return result
    }
  }
}

struct ForecastWidgetView: View {
  let entry: ForecastWidgetEntry
  @Environment(\.widgetFamily) private var family
  private func temperature(_ value: Double?) -> String {
    value.map { "\(Int($0.rounded()))°" } ?? "—"
  }
  var body: some View {
    Group {
      if let weather = entry.weather, let payload = entry.payload {
        switch family {
        case .accessoryInline:
          Text("\(payload.displayName): \(temperature(weather.temperatureC)) · Forecast")
        case .accessoryCircular:
          VStack(spacing: 2) {
            Image(systemName: weather.symbol)
            Text(temperature(weather.temperatureC)).bold()
            Text("Fcst").font(.caption2)
          }
        case .accessoryRectangular:
          VStack(alignment: .leading) {
            Text(payload.displayName).font(.headline).lineLimit(1)
            Label(
              "\(temperature(weather.temperatureC)) · H \(temperature(weather.highC)) L \(temperature(weather.lowC))",
              systemImage: weather.symbol)
            Text(
              "Forecast · \((payload.modelIssuedAt ?? payload.issuedAt).formatted(date: .omitted, time: .shortened))"
            ).font(.caption2)
          }
        default:
          VStack(alignment: .leading, spacing: 5) {
            Text(payload.displayName).font(.headline).lineLimit(2).minimumScaleFactor(0.75)
            HStack {
              Image(systemName: weather.symbol).font(.title2)
              Text(temperature(weather.temperatureC)).font(.largeTitle.bold()).minimumScaleFactor(
                0.7)
              Spacer(minLength: 0)
              if family == .systemMedium { Text(weather.condition).font(.caption).lineLimit(2) }
            }
            Text("H \(temperature(weather.highC))   L \(temperature(weather.lowC))").font(.caption)
            if family == .systemMedium {
              HStack {
                ForEach(weather.hours.prefix(6)) { hour in
                  VStack(spacing: 2) {
                    Text(hour.time, format: .dateTime.hour()).font(.caption2)
                    Text(temperature(hour.temperatureC)).font(.caption.bold())
                    if let rain = hour.precipitationMm, rain > 0 {
                      Text("\(rain.formatted(.number.precision(.fractionLength(0...1)))) mm").font(
                        .caption2)
                    }
                  }.frame(maxWidth: .infinity)
                }
              }
            }
            Text(
              "\(entry.message == nil ? entry.locationMode : "Saved · offline") · issued \((payload.modelIssuedAt ?? payload.issuedAt).formatted(date: .abbreviated, time: .shortened))"
            )
            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
          }
        }
      } else {
        VStack(alignment: .leading, spacing: 5) {
          Label("Weather Atlas", systemImage: "cloud.sun")
          Text(entry.message ?? "Forecast unavailable · open the app").font(.caption)
        }
      }
    }
    .containerBackground(.background, for: .widget)
    .widgetURL(entry.url)
    .privacySensitive()
  }
}

@main
struct WeatherAtlasWidgets: Widget {
  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: WidgetDataStore.kind, intent: ForecastWidgetIntent.self,
      provider: ForecastWidgetProvider()
    ) { entry in ForecastWidgetView(entry: entry) }
    .configurationDisplayName("Weather Atlas Forecast")
    .description(
      "Canadian forecasts for your chosen location. Updates use a secure internet connection to Weather Atlas."
    )
    .supportedFamilies([
      .systemSmall, .systemMedium, .accessoryInline, .accessoryCircular, .accessoryRectangular,
    ])
  }
}
