import SwiftUI
import WidgetKit

struct SavedPlace: Codable, Identifiable, Hashable, Sendable {
  let id: String
  let name: String
  let province: String
  let latitude: Double
  let longitude: Double
  var displayName: String { ForecastLocationName.display(name) }
}

@MainActor
final class AppStore: ObservableObject {
  @Published private(set) var serverURL: URL
  // Forecast opens on every fresh launch; tab IDs are independent of visual order.
  @Published var selectedTab = 1
  @Published private(set) var forecast: ForecastModel
  let forecastSummary = ForecastSummaryModel()
  let golfSettings: GolfSettingsStore
  private(set) var api: WeatherAPI
  @Published private(set) var forecastRefresh = 0
  /// Empty follows the phone unless paused before the first forecast arrived.
  /// Explicit choices and a region held when location following stops are persisted.
  @Published private(set) var selectedRegionID = ""
  @Published private var locationFollowingPaused = false
  @Published private(set) var forecastMapPin: ForecastMapPin?
  /// Nil represents the built-in Halifax default, independent of server region IDs.
  @Published private(set) var defaultForecastLocation: SavedPlace?
  var defaultForecastName: String { defaultForecastLocation?.displayName ?? "Halifax" }
  @Published var mapPlace: SavedPlace? { didSet { mapRevision += 1 } }
  @Published private(set) var mapRevision = 0
  @Published private(set) var saved: [SavedPlace] = []
  private let defaults: UserDefaults

  init(configuration: AppConfiguration, defaults: UserDefaults = .standard) {
    let started = ContinuousClock.now
    WeatherDiagnostics.startup.notice("Creating forecast store")
    self.defaults = defaults
    golfSettings = GolfSettingsStore(defaults: defaults)
    let selectedURL = configuration.apiBaseURL
    if selectedURL == WeatherAtlasEndpoint.productionURL {
      Self.migrateHTTPSPreferences(defaults)
    }
    serverURL = selectedURL
    api = WeatherAPI(baseURL: selectedURL)
    forecast = ForecastModel(
      api: api,
      cache: ForecastSnapshotStore(serverURL: selectedURL, defaults: defaults))
    restorePlaces()
    restoreForecastSelection()
    if !locationFollowingPaused {
      forecast.restore(preferredID: selectedRegionID, defaultLocation: defaultForecastLocation)
    }
    syncWidgetSettings()
    WeatherDiagnostics.startup.notice(
      "Forecast store ready in \(String(describing: started.duration(to: .now)), privacy: .public); saved bulletin: \(self.forecast.region != nil)"
    )
  }

  private static func migrateHTTPSPreferences(_ defaults: UserDefaults) {
    let marker = "didMigrateFixedWeatherAtlasHTTPSv1"
    guard !defaults.bool(forKey: marker) else {
      defaults.removeObject(forKey: "serverURL")
      return
    }
    let destination = WeatherAtlasEndpoint.productionURL.absoluteString
    let previous = defaults.string(forKey: "serverURL")
    // Copy only namespaces belonging to this same service, never cached weather
    // or region identifiers from an unrelated user-configured server.
    let sources: [String]
    if let previous {
      sources =
        WeatherAtlasEndpoint.isKnownService(previous)
        ? [previous, WeatherAtlasEndpoint.normalized(previous)!] : []
    } else {
      sources = WeatherAtlasEndpoint.legacyAddresses.flatMap { [$0, $0 + "/"] }
    }
    for source in sources where source != destination {
      var keys = [
        "savedPlaces", "forecastRegion", "forecastLocationPaused", "forecastMapPin",
        "defaultForecastLocation",
      ].map {
        ("\($0):\(source)", "\($0):\(destination)")
      }
      keys += ["automatic", "manual"].map {
        ("forecastSnapshot:v1:\(source):\($0)", "forecastSnapshot:v1:\(destination):\($0)")
      }
      for (oldKey, newKey) in keys where defaults.object(forKey: newKey) == nil {
        if let value = defaults.object(forKey: oldKey) { defaults.set(value, forKey: newKey) }
      }
    }
    defaults.set(true, forKey: marker)
    defaults.removeObject(forKey: "serverURL")
  }
  var followsCurrentLocation: Bool { selectedRegionID.isEmpty && !locationFollowingPaused }
  private var forecastSelectionKey: String { "forecastRegion:\(serverURL.absoluteString)" }
  private var locationPausedKey: String { "forecastLocationPaused:\(serverURL.absoluteString)" }
  private var forecastPinKey: String { "forecastMapPin:\(serverURL.absoluteString)" }
  private var defaultForecastKey: String { "defaultForecastLocation:\(serverURL.absoluteString)" }
  func setDefaultForecastLocation(_ region: ForecastRegion?) {
    let place = region.flatMap { region in
      region.isHalifaxMetro
        ? nil
        : SavedPlace(
          id: region.id, name: region.displayName, province: region.province,
          latitude: region.latitude, longitude: region.longitude)
    }
    guard defaultForecastLocation != place else { return }
    forecastSummary.reset()
    defaultForecastLocation = place
    if let place {
      defaults.set(try? JSONEncoder().encode(place), forKey: defaultForecastKey)
    } else {
      defaults.removeObject(forKey: defaultForecastKey)
    }
    if !locationFollowingPaused {
      forecast.restore(preferredID: selectedRegionID, defaultLocation: place)
    }
    syncWidgetSettings()
    refreshForecast()
  }
  func selectForecastRegion(_ id: String, pin: ForecastMapPin? = nil) {
    locationFollowingPaused = false
    defaults.removeObject(forKey: locationPausedKey)
    if selectedRegionID != id { forecastSummary.reset() }
    selectedRegionID = id
    defaults.set(id, forKey: forecastSelectionKey)
    forecastMapPin = pin.flatMap { $0.regionID == id && $0.isValid ? $0 : nil }
    if let forecastMapPin {
      defaults.set(try? JSONEncoder().encode(forecastMapPin), forKey: forecastPinKey)
    } else {
      defaults.removeObject(forKey: forecastPinKey)
    }
    forecast.restore(preferredID: id, defaultLocation: defaultForecastLocation)
  }
  func useCurrentLocationForForecast() {
    locationFollowingPaused = false
    defaults.removeObject(forKey: locationPausedKey)
    forecastSummary.reset()
    selectedRegionID = ""
    forecastMapPin = nil
    defaults.removeObject(forKey: forecastPinKey)
    defaults.removeObject(forKey: forecastSelectionKey)
    forecast.restore(preferredID: "", defaultLocation: defaultForecastLocation)
  }
  func stopUsingCurrentLocationForForecast() {
    guard followsCurrentLocation else { return }
    // Keep the visible bulletin, optional forecasts and summary in place.
    // Invalidate old coordinate requests before publishing the manual selection.
    let id = forecast.holdCurrentRegion()
    selectedRegionID = id
    defaults.set(id, forKey: forecastSelectionKey)
    locationFollowingPaused = id.isEmpty
    if locationFollowingPaused {
      defaults.set(true, forKey: locationPausedKey)
    } else {
      defaults.removeObject(forKey: locationPausedKey)
    }
  }
  func refreshForecast() { forecastRefresh += 1 }
  private func restoreForecastSelection() {
    selectedRegionID = defaults.string(forKey: forecastSelectionKey) ?? ""
    locationFollowingPaused = selectedRegionID.isEmpty && defaults.bool(forKey: locationPausedKey)
    forecastMapPin = defaults.data(forKey: forecastPinKey).flatMap {
      try? JSONDecoder().decode(ForecastMapPin.self, from: $0)
    }.flatMap { $0.regionID == selectedRegionID && !$0.regionID.isEmpty && $0.isValid ? $0 : nil }
    defaultForecastLocation = defaults.data(forKey: defaultForecastKey).flatMap {
      try? JSONDecoder().decode(SavedPlace.self, from: $0)
    }
  }
  private var savedKey: String { "savedPlaces:\(serverURL.absoluteString)" }
  #if DEBUG
    /// Unit-test injection for cache isolation. Not present in App Store builds.
    func connect(to url: URL) {
      forecast.cancel()
      forecastSummary.reset()
      serverURL = url
      defaults.set(url.absoluteString, forKey: "serverURL")
      restoreForecastSelection()
      api = WeatherAPI(baseURL: url)
      forecast = ForecastModel(
        api: api,
        cache: ForecastSnapshotStore(serverURL: url, defaults: defaults))
      if !locationFollowingPaused {
        forecast.restore(preferredID: selectedRegionID, defaultLocation: defaultForecastLocation)
      }
      mapPlace = nil
      restorePlaces()
      syncWidgetSettings()
    }
  #endif
  private func restorePlaces() {
    saved =
      defaults.data(forKey: savedKey).flatMap {
        try? JSONDecoder().decode([SavedPlace].self, from: $0)
      } ?? []
  }
  func toggle(_ region: ForecastRegion) {
    if let index = saved.firstIndex(where: { $0.id == region.id }) {
      saved.remove(at: index)
    } else {
      saved.append(
        SavedPlace(
          id: region.id, name: region.displayName, province: region.province,
          latitude: region.latitude, longitude: region.longitude))
    }
    persist()
  }
  func remove(at offsets: IndexSet) {
    saved.remove(atOffsets: offsets)
    persist()
  }
  private func persist() {
    defaults.set(try? JSONEncoder().encode(saved), forKey: savedKey)
    syncWidgetSettings()
  }

  /// Refresh display labels without changing saved identities or coordinates.
  func updateLocationNames(from regions: [ForecastRegion]) {
    let names = Dictionary(
      regions.map { ($0.id, $0.displayName) }, uniquingKeysWith: { _, new in new })
    func renamed(_ place: SavedPlace) -> SavedPlace {
      guard let name = names[place.id], name != place.name else { return place }
      return SavedPlace(
        id: place.id, name: name, province: place.province,
        latitude: place.latitude, longitude: place.longitude)
    }
    let updated = saved.map(renamed)
    if updated != saved {
      saved = updated
      persist()
    }
    if let place = defaultForecastLocation, renamed(place) != place {
      defaultForecastLocation = renamed(place)
      defaults.set(try? JSONEncoder().encode(renamed(place)), forKey: defaultForecastKey)
      syncWidgetSettings()
    }
  }

  private func syncWidgetSettings() {
    let old = WidgetDataStore.settings()
    let oldHalifax =
      old?.server == serverURL.absoluteString
        && old?.defaultLocation?.name.lowercased().contains("halifax") == true
      ? old?.defaultLocation : nil
    let current = forecast.region.map { WidgetLocationRecord(id: $0.id, name: $0.displayName) }
    let fallback =
      defaultForecastLocation.map { WidgetLocationRecord(id: $0.id, name: $0.name) }
      ?? (forecast.region?.isHalifaxMetro == true ? current : oldHalifax)
    let config = WidgetSettings(
      server: serverURL.absoluteString, defaultLocation: fallback,
      lastLocation: current ?? (old?.server == serverURL.absoluteString ? old?.lastLocation : nil),
      saved: saved.map { WidgetLocationRecord(id: $0.id, name: $0.name) })
    if WidgetDataStore.saveSettings(config) {
      WidgetCenter.shared.reloadTimelines(ofKind: WidgetDataStore.kind)
    }
  }

  func refreshWidgetData() async {
    guard let region = forecast.region else { return }
    let server = serverURL
    let requestedDefault = defaultForecastLocation
    syncWidgetSettings()
    do {
      let payload: WidgetForecast = try await api.get(
        "/api/v1/widgets/forecast", query: [.init(name: "area_id", value: region.id)])
      guard !Task.isCancelled, serverURL == server, forecast.region?.id == region.id,
        payload.regionId == region.id
      else { return }
      var changed = WidgetDataStore.save(payload, server: server.absoluteString)
      if let settings = WidgetDataStore.settings(), settings.defaultLocation?.id != region.id {
        if let fallback = try? await WidgetServerClient.fetch(
          server: server.absoluteString, regionID: settings.defaultLocation?.id)
        {
          guard !Task.isCancelled, serverURL == server else { return }
          changed = WidgetDataStore.save(fallback, server: server.absoluteString) || changed
          if defaultForecastLocation == requestedDefault, requestedDefault == nil,
            var config = WidgetDataStore.settings(), config.server == server.absoluteString
          {
            config.defaultLocation = WidgetLocationRecord(
              id: fallback.regionId, name: fallback.displayName)
            changed = WidgetDataStore.saveSettings(config) || changed
          }
        }
      }
      if changed { WidgetCenter.shared.reloadTimelines(ofKind: WidgetDataStore.kind) }
    } catch {
      // Optional widget updates never replace the main forecast's status.
    }
  }

  func openWidgetURL(_ url: URL) {
    guard url.scheme == "weatheratlas", url.host == "forecast",
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return }
    selectedTab = 1
    if let server = parts.queryItems?.first(where: { $0.name == "server" })?.value,
      server != serverURL.absoluteString
        && !(serverURL == WeatherAtlasEndpoint.productionURL
          && WeatherAtlasEndpoint.isKnownService(server))
    {
      return
    }
    guard let id = parts.queryItems?.first(where: { $0.name == "region" })?.value,
      id.range(of: "^[a-f0-9]{16}$", options: .regularExpression) != nil
    else { return }
    selectForecastRegion(id)
    refreshForecast()
  }
}
