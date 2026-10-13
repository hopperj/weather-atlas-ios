import Charts
import SwiftUI

protocol ForecastServing: Sendable {
  func forecastRegions() async throws -> ForecastRegionsResponse
  func halifaxForecast() async throws -> ForecastRegion?
  func defaultForecast(at place: SavedPlace) async throws -> ForecastRegion?
  func nearestForecast(longitude: Double, latitude: Double) async throws -> NearbyForecast
  func hourlyForecast(areaID: String) async throws -> HourlyForecast
  func precipitationForecast(areaID: String) async throws -> PrecipitationForecast
  func nearbyStations(longitude: Double, latitude: Double) async throws -> StationCollection
}

extension ForecastServing {
  func defaultForecast(at place: SavedPlace) async throws -> ForecastRegion? {
    try await forecastRegions().regions.first { $0.id == place.id }
  }
  func halifaxForecast() async throws -> ForecastRegion? {
    try await forecastRegions().regions.first(where: \.isHalifaxMetro)
  }
  func nearbyStations(longitude: Double, latitude: Double) async throws -> StationCollection {
    StationCollection(generatedAt: Date(), items: [], nextOffset: nil)
  }
}

extension WeatherAPI: ForecastServing {}

@MainActor
final class ForecastModel: ObservableObject {
  @Published var regions: [ForecastRegion] = []
  @Published private(set) var region: ForecastRegion?
  @Published private(set) var hourly: HourlyForecast?
  @Published private(set) var precipitation: PrecipitationForecast?
  @Published private(set) var nearbyStations: [WeatherStation] = []
  @Published private(set) var error: String?
  @Published private(set) var regionListError: String?
  @Published private(set) var loading = false
  @Published private(set) var hourlyLoading = false
  @Published private(set) var precipitationLoading = false
  @Published private(set) var observationsLoading = false
  @Published private(set) var regionListLoading = false
  @Published private(set) var nearbyDistanceKm: Double?
  @Published private(set) var usingDefaultLocation = false
  @Published private(set) var fallbackMessage: String?
  @Published private(set) var observationsMessage: String?
  @Published private(set) var usingLastLocation = false
  @Published private(set) var showingSavedData = false
  @Published private(set) var lastUpdated: Date?
  @Published private(set) var refreshIncomplete = false
  @Published var networkAvailable = true
  @Published private(set) var hourlyError: String?
  @Published private(set) var precipitationError: String?
  var isRefreshing: Bool { loading || hourlyLoading || precipitationLoading || observationsLoading }
  let api: any ForecastServing
  private var revision = 0
  private let cache: ForecastSnapshotStore?
  private var selectionID: String?
  private var defaultLocation: SavedPlace?
  private var defaultLocationName: String { defaultLocation?.displayName ?? "Halifax" }
  init(api: any ForecastServing, cache: ForecastSnapshotStore? = nil) {
    self.api = api
    self.cache = cache
  }

  /// Synchronous restoration lets the very first view show the previous forecast.
  func restore(preferredID: String, defaultLocation: SavedPlace? = nil) {
    guard selectionID != preferredID || self.defaultLocation != defaultLocation else { return }
    // Invalidate late responses immediately, before the next view update.
    cancel()
    selectionID = preferredID
    self.defaultLocation = defaultLocation
    region = nil
    hourly = nil
    precipitation = nil
    nearbyStations = []
    nearbyDistanceKm = nil
    usingDefaultLocation = false
    usingLastLocation = false
    fallbackMessage = nil
    observationsMessage = nil
    showingSavedData = false
    lastUpdated = nil
    error = nil
    refreshIncomplete = false
    hourlyError = nil
    precipitationError = nil
    guard
      let saved = cache?.read(
        selectionID: preferredID, defaultLocationID: defaultLocation?.id)
    else { return }
    region = saved.region
    hourly = saved.hourly.flatMap { $0.regionId == saved.region.id && $0.end > Date() ? $0 : nil }
    precipitation = saved.precipitation.flatMap {
      $0.regionId == saved.region.id && $0.issuedAt == saved.region.issuedAt ? $0 : nil
    }
    usingDefaultLocation = saved.usingDefaultLocation
    usingLastLocation = preferredID.isEmpty && !saved.usingDefaultLocation
    showingSavedData = true
    lastUpdated = saved.lastUpdated
  }

  /// Turn the displayed automatic forecast into a fixed region without a cache swap or blanking.
  @discardableResult func holdCurrentRegion() -> String {
    cancel()
    let id = region?.id ?? ""
    selectionID = id
    nearbyDistanceKm = nil
    usingDefaultLocation = false
    usingLastLocation = false
    fallbackMessage = nil
    saveSnapshot()
    return id
  }

  private func saveSnapshot() {
    guard let selectionID, let region else { return }
    cache?.save(
      ForecastSnapshot(
        storedAt: Date(), selectionID: selectionID, region: region,
        hourly: hourly, precipitation: precipitation, usingDefaultLocation: usingDefaultLocation,
        lastUpdated: lastUpdated, defaultLocationID: defaultLocation?.id))
  }

  func loadRegions() async {
    guard !regionListLoading else { return }
    regionListLoading = true
    regionListError = nil
    defer { regionListLoading = false }
    do {
      let result = try await api.forecastRegions()
      try Task.checkCancellation()
      regions = result.regions
    } catch {
      if !Task.isCancelled { regionListError = error.localizedDescription }
    }
  }

  func cancel() {
    revision += 1
    loading = false
    hourlyLoading = false
    precipitationLoading = false
    observationsLoading = false
  }

  func load(
    preferredID: String, location: ForecastLocationFix?, useDefaultLocation: Bool = true,
    defaultLocation: SavedPlace? = nil, locationUnavailable: Bool = false
  ) async {
    restore(preferredID: preferredID, defaultLocation: defaultLocation)
    revision += 1
    let request = revision
    // Refresh in place; never blank an already useful forecast while GPS/network work runs.
    if region != nil { showingSavedData = true }
    error = nil
    refreshIncomplete = false
    hourlyError = nil
    precipitationError = nil
    loading = false
    hourlyLoading = false
    precipitationLoading = false
    observationsLoading = false
    guard !preferredID.isEmpty || location != nil || useDefaultLocation else { return }
    loading = true
    defer {
      if request == revision {
        loading = false
        hourlyLoading = false
        precipitationLoading = false
      }
    }
    do {
      let selected: ForecastRegion
      if preferredID.isEmpty, let location {
        do {
          let nearby = try await api.nearestForecast(
            longitude: location.longitude, latitude: location.latitude)
          try Task.checkCancellation()
          guard request == revision else { return }
          selected = nearby.region
          nearbyDistanceKm = nearby.distanceKm
          usingDefaultLocation = false
          usingLastLocation = false
          fallbackMessage = nil
        } catch {
          // An older server can have regional forecasts but no coordinate lookup.
          // This is different from a working lookup reporting no nearby coverage.
          guard case WeatherAPIError.server(let status, let detail) = error,
            status == 404, detail == "Not Found"
          else { throw error }
          try Task.checkCancellation()
          guard request == revision else { return }
          guard let matching = try await selectRegion(preferredID: "", request: request) else {
            return
          }
          selected = matching
          usingDefaultLocation = true
          usingLastLocation = false
          nearbyDistanceKm = nil
          fallbackMessage =
            "Showing \(defaultLocationName) because this server cannot match your location yet."
        }
      } else {
        let previousAutomaticID =
          preferredID.isEmpty && !usingDefaultLocation && !locationUnavailable
          ? region?.id : nil
        guard
          let matching = try await selectRegion(
            preferredID: previousAutomaticID ?? preferredID, request: request)
        else {
          return
        }
        selected = matching
        usingDefaultLocation = preferredID.isEmpty && previousAutomaticID == nil
        usingLastLocation = preferredID.isEmpty && previousAutomaticID != nil
        nearbyDistanceKm = nil
        fallbackMessage = nil
        if usingDefaultLocation {
          fallbackMessage = "Showing \(defaultLocationName) until your location is available."
        } else if usingLastLocation {
          fallbackMessage =
            "Showing your last forecast location while checking your current location."
        }
      }
      if region?.id != selected.id {
        hourly = nil
        precipitation = nil
        nearbyStations = []
        observationsMessage = nil
        lastUpdated = nil
        showingSavedData = false
      } else if precipitation?.issuedAt != selected.issuedAt {
        precipitation = nil
      }
      region = selected
      loading = false
      hourlyLoading = true
      precipitationLoading = selected.periods.contains(where: \.needsPrecipitationEstimate)
      observationsLoading = true
      // Neither optional forecast should delay or suppress the other.
      saveSnapshot()  // A successful bulletin is useful even if optional feeds later fail.
      async let hours = loadHourly(areaID: selected.id, request: request)
      async let amounts = loadPrecipitation(for: selected, request: request)
      async let observations = loadObservations(for: selected, request: request)
      let (hoursOK, amountsOK, observationsOK) = await (hours, amounts, observations)
      guard request == revision && !Task.isCancelled else { return }
      if hoursOK && amountsOK && observationsOK {
        lastUpdated = Date()
        showingSavedData = false
      } else {
        refreshIncomplete = true
      }
      saveSnapshot()
    } catch {
      guard request == revision && !Task.isCancelled else { return }
      refreshIncomplete = true
      if preferredID.isEmpty, location != nil,
        case WeatherAPIError.server(let status, let detail) = error,
        status == 404, detail != "Not Found"
      {
        usingLastLocation = region != nil && !usingDefaultLocation
        self.error =
          "No regional forecast is available near your current location."
          + (region == nil
            ? " Choose a region to see available coverage."
            : " The previous region is still shown.")
      } else {
        self.error =
          (region == nil ? "" : "Could not refresh; previously loaded data is still shown. ")
          + error.localizedDescription
      }
    }
  }

  private func selectRegion(preferredID: String, request: Int) async throws -> ForecastRegion? {
    let matching: ForecastRegion?
    if preferredID.isEmpty {
      if let defaultLocation {
        matching = try await api.defaultForecast(at: defaultLocation)
      } else {
        matching = try await api.halifaxForecast()
      }
    } else {
      let result = try await api.forecastRegions()
      try Task.checkCancellation()
      guard request == revision else { return nil }
      regions = result.regions
      matching = regions.first(where: { $0.id == preferredID })
    }
    try Task.checkCancellation()
    guard request == revision else { return nil }
    if matching == nil {
      error =
        preferredID.isEmpty
        ? "\(defaultLocationName) is unavailable on this server. Choose another default in Settings or choose a forecast region."
        : "Your chosen region is unavailable on this server. Choose another region or use your location."
    }
    return matching
  }

  func precipitationDescription(for period: ForecastPeriod) -> String? {
    period.precipitationDescription(
      estimatedMm: region.flatMap { precipitation?.estimatedMm(for: period, in: $0) },
      loading: precipitationLoading)
  }

  var hasPrecipitationEstimates: Bool {
    guard let region else { return false }
    return region.periods.contains {
      $0.needsPrecipitationEstimate && precipitation?.estimatedMm(for: $0, in: region) != nil
    }
  }

  var currentObservation: WeatherStation? {
    nearbyStations.first { !$0.isStale && $0.value(.temperatureC) != nil }
      ?? nearbyStations.first { !$0.isStale }
  }

  private func loadHourly(areaID: String, request: Int) async -> Bool {
    defer { if request == revision { hourlyLoading = false } }
    do {
      let result = try await api.hourlyForecast(areaID: areaID)
      try Task.checkCancellation()
      guard request == revision, result.regionId == areaID else { return false }
      hourly = result
      return true
    } catch {
      guard request == revision && !Task.isCancelled else { return false }
      self.error = error.localizedDescription
      hourlyError =
        "Model hours could not be refreshed. Previously loaded hours are shown only while valid."
      return false
    }
  }

  private func loadPrecipitation(for selected: ForecastRegion, request: Int) async -> Bool {
    guard selected.periods.contains(where: \.needsPrecipitationEstimate) else { return true }
    defer { if request == revision { precipitationLoading = false } }
    do {
      let result = try await api.precipitationForecast(areaID: selected.id)
      try Task.checkCancellation()
      guard request == revision, result.regionId == selected.id,
        result.issuedAt == selected.issuedAt
      else {
        guard request == revision && !Task.isCancelled else { return false }
        precipitationError = "Precipitation totals are waiting for the current bulletin's update."
        return false
      }
      precipitation = result
      return true
    } catch {
      guard request == revision && !Task.isCancelled else { return false }
      precipitationError =
        "Precipitation totals could not be refreshed. Issued bulletin amounts remain available."
      // Keep the issued bulletin and hourly forecast. Wet periods explicitly
      // say "amount unavailable" instead of interpreting a failed request as zero.
      return false
    }
  }

  private func loadObservations(for selected: ForecastRegion, request: Int) async -> Bool {
    defer { if request == revision { observationsLoading = false } }
    do {
      let result = try await api.nearbyStations(
        longitude: selected.longitude, latitude: selected.latitude)
      try Task.checkCancellation()
      guard request == revision else { return false }
      nearbyStations = result.items
      observationsMessage =
        result.items.isEmpty
        ? "No collected stations within 100 km of this forecast location." : nil
      return true
    } catch {
      guard request == revision && !Task.isCancelled else { return false }
      observationsMessage =
        nearbyStations.isEmpty
        ? "Nearby observations aren't available yet." : "Could not refresh the observations."
      return false
    }
  }
}

private enum ForecastViewMode {
  case daily, hourly
}

struct ForecastScreen: View {
  @ObservedObject private var model: ForecastModel
  @ObservedObject private var location: ForecastLocation
  @EnvironmentObject private var store: AppStore
  @Environment(\.openURL) private var openURL
  @Environment(\.calendar) private var calendar
  @Environment(\.timeZone) private var timeZone
  @Environment(\.locale) private var locale
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.scenePhase) private var scenePhase
  @State private var now = Date()
  @State private var choosingRegion = false
  @State private var mapRegion: ForecastRegion?
  @State private var query = ""
  @State private var forecastView: ForecastViewMode = .daily
  @State private var hourlyPlot: HourlyPlot = .temperature
  @State private var hourlyVisibleDuration: TimeInterval?
  @State private var hourlyZoomStartDuration: TimeInterval?
  @State private var hourlyScrollPosition: Date?
  init(model: ForecastModel, location: ForecastLocation) {
    self.model = model
    self.location = location
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          if store.followsCurrentLocation {
            if location.locating && model.region == nil {
              ProgressView("Finding your location…")
                .accessibilityIdentifier("forecastInitialLocationLoading")
            }
            if let message = location.message {
              StatusMessage(text: message, symbol: "location.slash")
              if location.permissionDenied {
                Button("Open iPhone Settings") {
                  openURL(URL(string: UIApplication.openSettingsURLString)!)
                }
              } else {
                Button("Try location again") { location.refresh() }
              }
            }
          }
          if model.loading && model.region == nil {
            ProgressView("Loading forecast…").frame(maxWidth: .infinity)
              .accessibilityIdentifier("forecastInitialLoading")
          }
          // Routine refreshes must not insert a row or move the forecast being read.
          // The issue timestamp remains visible; only failures need a notice.
          if model.showingSavedData && (model.refreshIncomplete || model.error != nil) {
            Text("Saved forecast · some updates unavailable")
              .font(.caption).foregroundStyle(.secondary)
              .accessibilityIdentifier("savedForecastNotice")
          }
          if let error = model.error { StatusMessage(text: error, symbol: "wifi.exclamationmark") }
          if let savedRegion = model.region {
            let region = ForecastRefreshPolicy.currentRegion(savedRegion, at: now)
            hero(region)
            if !model.networkAvailable {
              Label("Offline · saved data shown where still valid", systemImage: "wifi.slash")
                .font(.caption).foregroundStyle(.secondary)
            }
            if region.stale {
              Label("Forecast update overdue", systemImage: "clock.badge.exclamationmark")
                .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Forecast view", selection: $forecastView) {
              Text("Daily / Nightly").tag(ForecastViewMode.daily)
              Text("Hourly · 72h").tag(ForecastViewMode.hourly)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("forecastViewPicker")
            if !region.periods.isEmpty {
              ForecastInsightsView(region: region, summary: store.forecastSummary)
                .id(region.id)
            }
            if forecastView == .daily {
              hourlyCards(region)
              dailySection(region)
            } else {
              hourlySection
            }
            NearbyObservationsView(
              stations: model.nearbyStations, message: model.observationsMessage, api: store.api)
          } else if !model.loading && model.error == nil {
            ContentUnavailableView(
              store.followsCurrentLocation ? "Your local forecast" : "No forecasts available",
              systemImage: "location.circle",
              description: Text(
                store.followsCurrentLocation
                  ? "Finding your location. If it is unavailable, \(store.defaultForecastName) will be used. You can also choose a region."
                  : "No forecast data is currently available for your chosen region."))
          }
          if model.region == nil {
            Button("Choose a region") { choosingRegion = true }
              .buttonStyle(.borderedProminent)
          }
        }.padding()
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle("Forecast")
      .toolbar {
        ToolbarItemGroup(placement: .topBarTrailing) {
          if let region = model.region {
            Button {
              store.toggle(region)
            } label: {
              Image(
                systemName: store.saved.contains { $0.id == region.id }
                  ? "bookmark.fill" : "bookmark")
            }.accessibilityLabel("Save or unsave \(region.displayName)")
          }
          Button(
            store.followsCurrentLocation ? "Stop using my location" : "Use my location",
            systemImage: store.followsCurrentLocation ? "location.fill" : "location"
          ) {
            if store.followsCurrentLocation {
              location.stop()
              store.stopUsingCurrentLocationForForecast()
            } else {
              store.useCurrentLocationForForecast()
              location.start()
              store.refreshForecast()
            }
          }
          .accessibilityValue(forecastLocationMode)
          .accessibilityHint(
            store.followsCurrentLocation
              ? "Keep this forecast location without following your phone"
              : "Follow your phone's location for forecasts"
          )
          .accessibilityAddTraits(store.followsCurrentLocation ? .isSelected : [])
          .accessibilityIdentifier("useCurrentLocationForecast")
          Button("Choose region", systemImage: "magnifyingglass") { choosingRegion = true }
        }
      }
      .refreshable { store.refreshForecast() }
      .task(id: scenePhase) {
        guard scenePhase == .active else { return }
        now = Date()
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(60)) } catch { return }
          now = Date()
        }
      }
      .fullScreenCover(item: $mapRegion) { region in
        ForecastLocationMap(region: region, pin: store.forecastMapPin, api: store.api) {
          selected, pin in
          store.selectForecastRegion(selected.id, pin: pin)
          store.refreshForecast()
        }
        .id(store.serverURL)
      }
      .sheet(isPresented: $choosingRegion) {
        NavigationStack {
          List {
            if model.regionListLoading && model.regions.isEmpty { ProgressView("Loading regions…") }
            if let error = model.regionListError { Text(error).foregroundStyle(.secondary) }
            Button("Use my location", systemImage: "location") {
              store.useCurrentLocationForForecast()
              choosingRegion = false
            }
            ForEach(
              model.regions.filter {
                query.isEmpty
                  || "\($0.displayName) \($0.name) \($0.provinceName)"
                    .localizedCaseInsensitiveContains(query)
              }
            ) { region in
              Button {
                store.selectForecastRegion(region.id)
                choosingRegion = false
              } label: {
                VStack(alignment: .leading) {
                  Text(region.displayName)
                  Text(region.provinceName).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          }
          .task { await model.loadRegions() }
          .searchable(text: $query, prompt: "Region or province")
          .navigationTitle("Choose a region")
          .toolbar { Button("Done") { choosingRegion = false } }
        }
      }
    }
  }

  private var forecastLocationMode: String {
    model.usingDefaultLocation
      ? "Default location"
      : model.usingLastLocation
        ? "Last forecast location"
        : store.followsCurrentLocation ? "Current location" : "Chosen location"
  }

  private func hero(_ region: ForecastRegion) -> some View {
    let currentPeriod =
      region.periods.first { $0.start <= now && now < $0.end }
    let observation = model.currentObservation
    let icon = currentPeriod?.weatherIcon ?? .unknown
    let temperature = observation?.value(.temperatureC) ?? currentPeriod?.temperatureC
    let high = region.periods.first { $0.end > now && $0.temperatureClass == "high" }?.temperatureC
    let low = region.periods.first { $0.end > now && $0.temperatureClass == "low" }?.temperatureC
    return VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(region.displayName).font(.title2.bold())
            .accessibilityIdentifier("forecastLocationName")
          Text(region.provinceName).font(.caption).opacity(0.82)
        }
        Spacer(minLength: 4)
        if !dynamicTypeSize.isAccessibilitySize { forecastMapButton(region) }
      }

      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 14) {
            conditionIcon(icon, size: 38, width: 46)
            Text(metric(temperature, "°"))
              .font(.largeTitle.weight(.semibold)).monospacedDigit()
              .accessibilityLabel("Current temperature \(metric(temperature, " degrees"))")
              .accessibilityIdentifier("currentForecastTemperature")
          }
          Text(currentPeriod?.condition.nilIfEmpty ?? "Condition unavailable")
            .font(.headline).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("currentForecastCondition")
          HStack(spacing: 18) {
            Label("High \(metric(high, "°"))", systemImage: "arrow.up")
            Label("Low \(metric(low, "°"))", systemImage: "arrow.down")
          }
          .font(.subheadline.weight(.semibold)).monospacedDigit()
        }
      } else {
        HStack(alignment: .center, spacing: 14) {
          conditionIcon(icon, size: 52, width: 62)
          VStack(alignment: .leading, spacing: 2) {
            Text(metric(temperature, "°"))
              .font(.system(size: 54, weight: .medium, design: .rounded))
              .monospacedDigit()
              .accessibilityLabel("Current temperature \(metric(temperature, " degrees"))")
              .accessibilityIdentifier("currentForecastTemperature")
            Text(currentPeriod?.condition.nilIfEmpty ?? "Condition unavailable")
              .font(.headline).lineLimit(2)
              .accessibilityIdentifier("currentForecastCondition")
          }
          Spacer(minLength: 0)
          VStack(alignment: .trailing, spacing: 5) {
            Label("H \(metric(high, "°"))", systemImage: "arrow.up")
            Label("L \(metric(low, "°"))", systemImage: "arrow.down")
          }
          .font(.subheadline.weight(.semibold)).monospacedDigit()
        }
      }

      if let observation {
        Text(
          "Observed at \(observation.name) · \(observation.observation.observedAt.formatted(date: .omitted, time: .shortened))"
        )
        .font(.caption).opacity(0.85)
        .accessibilityIdentifier("currentObservationStation")
      } else if model.observationsLoading {
        Text("Finding a nearby observation…").font(.caption).opacity(0.85)
      } else {
        Text("Current regional forecast").font(.caption).opacity(0.85)
      }

      Divider().overlay(.white.opacity(0.32))
      AnyLayout(
        dynamicTypeSize.isAccessibilitySize
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
          : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
      ) {
        heroMetric(
          "Humidity",
          value: metric(
            observation?.value(.humidityPercent) ?? currentPeriod?.relativeHumidityPercent, "%"),
          symbol: "humidity")
        heroMetric(
          "Wind", value: observation?.formatted(.windKmh) ?? "Unavailable", symbol: "wind")
        heroMetric(
          "Pressure", value: observation?.formatted(.pressureHpa) ?? "Unavailable",
          symbol: "gauge.with.dots.needle.33percent")
      }
      Text("Forecast issued \(region.issuedAt.formatted(date: .abbreviated, time: .shortened))")
        .font(.caption2).opacity(0.78)
        .accessibilityIdentifier("forecastIssuedAt")
      Text(
        model.lastUpdated.map {
          "Last updated \($0.formatted(date: .abbreviated, time: .shortened))"
        } ?? "Waiting for forecast updates"
      )
      .font(.caption2).opacity(0.78)
      .accessibilityIdentifier("forecastLastUpdated")
      if dynamicTypeSize.isAccessibilitySize { forecastMapButton(region) }
    }
    .padding(18).foregroundStyle(.white)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      LinearGradient(
        colors: heroColors(for: icon),
        startPoint: .topLeading, endPoint: .bottomTrailing),
      in: RoundedRectangle(cornerRadius: 22)
    )
    .shadow(color: heroColors(for: icon).last!.opacity(0.18), radius: 12, y: 6)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("forecastHeader")
  }

  private func forecastMapButton(_ region: ForecastRegion) -> some View {
    Button("Map", systemImage: "map") { mapRegion = region }
      .font(.subheadline.weight(.semibold)).buttonStyle(.bordered).tint(.white)
      .accessibilityLabel("Show on map")
  }

  private func conditionIcon(_ icon: ForecastWeatherIcon, size: CGFloat, width: CGFloat)
    -> some View
  {
    ForecastConditionSymbol(icon: icon, onHero: true)
      .font(.system(size: size))
      .frame(width: width)
      .accessibilityLabel(icon.label)
      .accessibilityIdentifier("currentForecastConditionIcon")
  }

  private func heroMetric(_ title: String, value: String, symbol: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(title, systemImage: symbol)
        .font(.caption2.weight(.semibold)).opacity(0.78)
      Text(value).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.72)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func heroColors(for icon: ForecastWeatherIcon) -> [Color] {
    switch icon {
    case .clearDay, .partlyCloudyDay, .hazeDay:
      [Color(red: 0.05, green: 0.38, blue: 0.64), Color(red: 0.10, green: 0.61, blue: 0.68)]
    case .clearNight, .partlyCloudyNight, .hazeNight:
      [Color(red: 0.08, green: 0.13, blue: 0.34), Color(red: 0.18, green: 0.31, blue: 0.52)]
    case .rain, .drizzle, .thunderstorms, .sleet, .snow, .hail:
      [Color(red: 0.12, green: 0.24, blue: 0.38), Color(red: 0.22, green: 0.42, blue: 0.52)]
    default:
      [Color(red: 0.04, green: 0.22, blue: 0.3), Color(red: 0.02, green: 0.45, blue: 0.48)]
    }
  }

  private var currentHourly: HourlyForecast? {
    guard model.hourly?.regionId == model.region?.id else { return nil }
    return ForecastRefreshPolicy.upcomingHourly(model.hourly, at: now)
  }

  @ViewBuilder private func hourlyCards(_ region: ForecastRegion) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Next 24 hours").font(.title2.bold())
        Spacer()
        if let hourly = currentHourly {
          Text(hourly.source).font(.caption).foregroundStyle(.secondary)
        }
      }
      if let message = model.hourlyError {
        Text(message).font(.caption).foregroundStyle(.secondary)
      }
      if model.hourlyLoading && currentHourly == nil {
        ProgressView("Loading the next 24 hours…")
          .accessibilityIdentifier("hourlyCardsInitialLoading")
      } else if let hourly = currentHourly {
        let hours = Array(hourly.hours.prefix(24))
        ScrollView(.horizontal) {
          LazyHStack(spacing: 10) {
            ForEach(Array(hours.enumerated()), id: \.element.id) { index, hour in
              let period = region.periods.first { $0.start <= hour.time && hour.time < $0.end }
              VStack(spacing: 9) {
                Text(hour.time <= now ? "Now" : hour.time.formatted(.dateTime.hour()))
                  .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForecastConditionSymbol(icon: period?.weatherIcon ?? .unknown)
                  .font(.title2)
                  .frame(height: 28)
                  .accessibilityHidden(true)
                Text(metric(hour.temperatureC, "°"))
                  .font(.title3.bold()).monospacedDigit()
                Label(metric(hour.precipitationMm, " mm"), systemImage: "drop.fill")
                Label(metric(hour.relativeHumidityPercent, "%"), systemImage: "humidity")
              }
              .font(.caption2)
              .frame(width: 82, height: 148)
              .background(
                Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16)
              )
              .overlay(
                RoundedRectangle(cornerRadius: 16).stroke(
                  index == 0 ? Color.teal.opacity(0.5) : Color.clear, lineWidth: 1.5)
              )
              .accessibilityElement(children: .ignore)
              .accessibilityLabel(
                "\(hour.time <= now ? "Now" : hour.time.formatted(date: .omitted, time: .shortened)), \(period?.condition ?? "condition unavailable"), temperature \(metric(hour.temperatureC, " degrees")), precipitation \(metric(hour.precipitationMm, " millimetres")), humidity \(metric(hour.relativeHumidityPercent, " percent"))"
              )
              .accessibilityIdentifier("hourlyForecastCard-\(index)")
            }
          }.padding(.horizontal, 1)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("hourlyForecastCards")
      } else {
        Text("Hourly forecast unavailable. Pull down to try again.")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func dailySection(_ region: ForecastRegion) -> some View {
    let days = forecastDayGroups(region)
    return VStack(alignment: .leading, spacing: 10) {
      Text("7-day forecast").font(.title2.bold())
      if let message = model.precipitationError {
        Text(message).font(.caption).foregroundStyle(.secondary)
      }
      if days.isEmpty {
        Text("No current forecast periods are available.").foregroundStyle(.secondary)
      }
      VStack(spacing: 0) {
        ForEach(Array(days.enumerated()), id: \.offset) { index, periods in
          let daytime = periods.first { $0.temperatureClass == "high" } ?? periods[0]
          let night = periods.first { $0.temperatureClass == "low" }
          HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
              Text(ForecastRefreshPolicy.dayTitle(for: daytime, at: now, calendar: chartCalendar))
                .font(.subheadline.bold())
                .accessibilityIdentifier("forecast-day-\(daytime.name)")
              Text(daytime.start.formatted(.dateTime.month(.abbreviated).day()))
                .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 56, alignment: .leading)
            ForecastConditionSymbol(icon: daytime.weatherIcon)
              .font(.title2).frame(width: 36)
              .accessibilityLabel(daytime.weatherIcon.label)
              .accessibilityIdentifier("forecast-condition-\(daytime.name)")
            VStack(alignment: .leading, spacing: 3) {
              Text(daytime.condition.nilIfEmpty ?? "Condition not issued")
                .font(.subheadline.weight(.semibold)).lineLimit(2)
              if let night {
                Text("Night: \(night.condition.nilIfEmpty ?? "not issued")")
                  .font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
              ForEach(periods) { period in
                let part = period.temperatureClass == "low" ? "Night" : "Day"
                let likelihood = period.precipitationLikelihoodDescription
                let amount = model.precipitationDescription(for: period)
                if likelihood != nil || amount != nil {
                  HStack(spacing: 6) {
                    if let likelihood {
                      Label("\(part): \(likelihood)", systemImage: "drop")
                        .accessibilityLabel("\(part) precipitation: \(likelihood)")
                        .accessibilityIdentifier("precipitation-likelihood-\(period.name)")
                    } else {
                      Label("\(part):", systemImage: "drop")
                        .accessibilityHidden(true)
                    }
                    if let amount {
                      let value = amount.replacingOccurrences(of: "Precipitation: ", with: "")
                      Text(value)
                        .accessibilityLabel("\(part) precipitation amount: \(value)")
                        .accessibilityIdentifier("precipitation-\(period.name)")
                    }
                  }
                  .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
              Text(metric(periods.first { $0.temperatureClass == "high" }?.temperatureC, "°"))
                .font(.headline).monospacedDigit()
                .accessibilityIdentifier("forecast-temperature-\(daytime.name)")
              Text(metric(night?.temperatureC, "°"))
                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                .accessibilityIdentifier("forecast-low-temperature-\(daytime.name)")
            }
          }
          .padding(.horizontal, 14).padding(.vertical, 13)
          if index < days.count - 1 { Divider().padding(.leading, 118) }
        }
      }
      .background(.background, in: RoundedRectangle(cornerRadius: 18))
      if model.hasPrecipitationEstimates {
        Text(
          "Model estimates (ECCC GDPS) cover the full day or night at the region’s reference location. Amounts are in mm of water equivalent: rain plus melted snow, not snow depth."
        ).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func forecastDayGroups(_ region: ForecastRegion) -> [[ForecastPeriod]] {
    var groups: [[ForecastPeriod]] = []
    for period in region.periods.filter({ $0.end > now }).sorted(by: { $0.start < $1.start }) {
      let isNight = period.temperatureClass == "low"
      if isNight, !groups.isEmpty,
        !groups[groups.count - 1].contains(where: { $0.temperatureClass == "low" })
      {
        groups[groups.count - 1].append(period)
      } else {
        groups.append([period])
      }
      if groups.count == 7, groups.last?.contains(where: { $0.temperatureClass == "low" }) == true {
        break
      }
    }
    return Array(groups.prefix(7))
  }

  @ViewBuilder private var hourlySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Next 72 hours").font(.title2.bold())
      if let message = model.hourlyError {
        Text(message).font(.caption).foregroundStyle(.secondary)
      }
      if model.hourlyLoading && currentHourly == nil {
        ProgressView("Loading hourly forecast…")
          .accessibilityIdentifier("hourlyForecastInitialLoading")
      }
      if let hourly = currentHourly {
        let axis = HourlyDayAxis(start: hourly.start, end: hourly.end, calendar: chartCalendar)
        let fullDuration = axis.domain.upperBound.timeIntervalSince(axis.domain.lowerBound)
        Text("\(hourly.source) · \(hourly.completeHours) of \(hourly.hours.count) complete hours")
          .font(.caption).foregroundStyle(.secondary)
        Text(hourlyPlot.chartTitle).font(.headline)
          .accessibilityIdentifier("hourlyChartTitle")
        ZStack {
          hourlyChart(hourly)
        }
        .id(hourlyPlot)
        .frame(height: 170)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          "Hourly \(hourlyPlot.chartTitle) chart; all values are available in the table below"
        )
        .accessibilityValue(
          "\(hourlyViewportLabel(fullDuration: fullDuration)). Daily ticks at midnight: "
            + axis.ticks.map { axis.label(for: $0, locale: locale) }.joined(separator: ", ")
        )
        .accessibilityIdentifier("hourlyForecastChart")
        hourlyChartControls(fullDuration: fullDuration, start: hourly.start)
        Text(
          "Pinch to zoom, drag sideways to move through time, or tap a column header to change the chart."
        )
        .font(.caption).foregroundStyle(.secondary)
        ScrollView(.horizontal) {
          Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
              Text("Time").bold().accessibilityIdentifier("hourlyTimeHeader")
              ForEach(HourlyPlot.allCases) { plot in
                Button {
                  hourlyPlot = plot
                } label: {
                  Text(plot.columnTitle).bold()
                    .padding(.horizontal, 8)
                    .frame(minWidth: 44, minHeight: 44)
                    .foregroundStyle(hourlyPlot == plot ? Color.white : Color.primary)
                    .background(
                      hourlyPlot == plot
                        ? Color(red: 0, green: 0.40, blue: 0.44) : Color.teal.opacity(0.08),
                      in: RoundedRectangle(cornerRadius: 8)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Plot \(plot.title)")
                .accessibilityHint("Show \(plot.title.lowercased()) over the next 72 hours")
                .accessibilityAddTraits(hourlyPlot == plot ? .isSelected : [])
                .accessibilityIdentifier("hourlyPlot-\(plot.rawValue)")
              }
            }
            ForEach(hourly.hours) { hour in
              GridRow {
                Text(hour.time.formatted(.dateTime.weekday(.abbreviated).hour()))
                  .accessibilityIdentifier("hourlyForecastTime")
                Text(metric(hour.temperatureC))
                  .accessibilityIdentifier("hourlyForecastTemperature")
                Text(metric(hour.precipitationMm))
                Text(metric(hour.windKmh))
                Text(metric(hour.gustKmh))
                Text(metric(hour.relativeHumidityPercent))
              }
            }
          }.font(.caption).monospacedDigit().padding()
        }
        .accessibilityIdentifier("hourlyForecastTable")
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        Text(
          "— means unavailable, not zero. Hourly values are model forecasts. Updated \(hourly.generatedAt.formatted(date: .abbreviated, time: .shortened))."
        )
        .font(.caption).foregroundStyle(.secondary)
        .onChange(of: hourly.start) { _, _ in
          hourlyVisibleDuration = nil
          hourlyZoomStartDuration = nil
          hourlyScrollPosition = nil
        }
      } else if !model.hourlyLoading {
        Text("Hourly forecast unavailable. Pull down to try again.")
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private func hourlyChart(_ hourly: HourlyForecast) -> some View {
    let axis = HourlyDayAxis(start: hourly.start, end: hourly.end, calendar: chartCalendar)
    let fullDuration = axis.domain.upperBound.timeIntervalSince(axis.domain.lowerBound)
    let visibleDuration = effectiveHourlyVisibleDuration(fullDuration: fullDuration)
    let hourStride = HourlyChartScale.hourStride(
      visibleDuration: visibleDuration, fullDuration: fullDuration)
    let scrollPosition = Binding<Date>(
      get: { hourlyScrollPosition ?? hourly.start },
      set: { hourlyScrollPosition = $0 })
    Chart(hourly.hours) { hour in
      if let value = hourlyPlot.value(for: hour) {
        PointMark(x: .value("Time", hour.time), y: .value(hourlyPlot.title, value))
          .foregroundStyle(.teal).symbolSize(16)
      }
    }
    .chartXScale(domain: axis.domain)
    .chartScrollableAxes(.horizontal)
    .chartXVisibleDomain(length: visibleDuration)
    .chartScrollPosition(x: scrollPosition)
    .chartScrollTargetBehavior(.valueAligned(unit: 3_600))
    .chartXAxis {
      if let hourStride {
        AxisMarks(position: .bottom, values: .stride(by: .hour, count: hourStride)) { value in
          AxisGridLine()
          AxisTick()
          AxisValueLabel(collisionResolution: .greedy) {
            if let date = value.as(Date.self) {
              Text(hourlyTickLabel(for: date, axis: axis))
                .font(.caption2).multilineTextAlignment(.center).fixedSize()
            }
          }
        }
      } else {
        AxisMarks(position: .bottom, values: axis.ticks) { value in
          AxisGridLine()
          AxisTick()
          AxisValueLabel(centered: false, collisionResolution: .disabled) {
            if let date = value.as(Date.self) {
              Text(axis.label(for: date, locale: locale))
                .font(.caption2).multilineTextAlignment(.center).fixedSize()
                .accessibilityLabel("\(axis.label(for: date, locale: locale)), midnight")
                .accessibilityIdentifier("hourlyDayTick")
            }
          }
        }
      }
    }
    .chartYAxisLabel(hourlyPlot.unit)
    .accessibilityValue(
      "\(hourlyViewportLabel(fullDuration: fullDuration)). Daily ticks at midnight: "
        + axis.ticks.map { axis.label(for: $0, locale: locale) }.joined(separator: ", ")
    )
    .simultaneousGesture(
      MagnifyGesture()
        .onChanged { value in
          if hourlyZoomStartDuration == nil {
            hourlyZoomStartDuration = visibleDuration
            if hourlyVisibleDuration == nil { hourlyScrollPosition = hourly.start }
          }
          guard let start = hourlyZoomStartDuration else { return }
          setHourlyVisibleDuration(
            start / max(Double(value.magnification), 0.01), fullDuration: fullDuration)
        }
        .onEnded { _ in hourlyZoomStartDuration = nil }
    )
    .overlay {
      if !hourly.hours.contains(where: { hourlyPlot.value(for: $0) != nil }) {
        Text("No \(hourlyPlot.title.lowercased()) data available")
          .font(.callout).foregroundStyle(.secondary)
      }
    }
  }

  private func hourlyChartControls(fullDuration: TimeInterval, start: Date) -> some View {
    HStack(spacing: 10) {
      Text(hourlyViewportLabel(fullDuration: fullDuration))
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        .accessibilityIdentifier("hourlyChartViewport")
      Spacer()
      Button {
        zoomHourlyChart(by: 0.5, fullDuration: fullDuration, start: start)
      } label: {
        Image(systemName: "plus.magnifyingglass").frame(minWidth: 30, minHeight: 30)
      }
      .accessibilityLabel("Zoom into hourly chart")
      .accessibilityIdentifier("hourlyChartZoomIn")
      Button {
        zoomHourlyChart(by: 2, fullDuration: fullDuration, start: start)
      } label: {
        Image(systemName: "minus.magnifyingglass").frame(minWidth: 30, minHeight: 30)
      }
      .disabled(hourlyVisibleDuration == nil)
      .accessibilityLabel("Zoom out of hourly chart")
      .accessibilityIdentifier("hourlyChartZoomOut")
      Button("Show all") {
        hourlyVisibleDuration = nil
        hourlyZoomStartDuration = nil
        hourlyScrollPosition = nil
      }
      .disabled(hourlyVisibleDuration == nil)
      .accessibilityIdentifier("hourlyChartShowAll")
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  private func effectiveHourlyVisibleDuration(fullDuration: TimeInterval) -> TimeInterval {
    min(max(hourlyVisibleDuration ?? fullDuration, min(6 * 3_600, fullDuration)), fullDuration)
  }

  private func setHourlyVisibleDuration(_ duration: TimeInterval, fullDuration: TimeInterval) {
    let value = min(max(duration, min(6 * 3_600, fullDuration)), fullDuration)
    hourlyVisibleDuration = value >= fullDuration * 0.995 ? nil : value
  }

  private func zoomHourlyChart(by factor: Double, fullDuration: TimeInterval, start: Date) {
    let current = effectiveHourlyVisibleDuration(fullDuration: fullDuration)
    if hourlyVisibleDuration == nil && factor < 1 { hourlyScrollPosition = start }
    setHourlyVisibleDuration(current * factor, fullDuration: fullDuration)
  }

  private func hourlyViewportLabel(fullDuration: TimeInterval) -> String {
    guard hourlyVisibleDuration != nil else { return "Full range" }
    let hours = max(
      1, Int((effectiveHourlyVisibleDuration(fullDuration: fullDuration) / 3_600).rounded()))
    return "\(hours)-hour view"
  }

  private func hourlyTickLabel(for date: Date, axis: HourlyDayAxis) -> String {
    let hour = chartCalendar.component(.hour, from: date)
    return hour == 0 ? axis.label(for: date, locale: locale) : String(format: "%02d", hour)
  }

  private var chartCalendar: Calendar {
    var result = calendar
    result.timeZone = timeZone
    return result
  }
}

func metric(_ value: Double?, _ suffix: String = "") -> String {
  value.map { $0.formatted(.number.precision(.fractionLength(0...1))) + suffix } ?? "—"
}

/// Keep one weather palette across the hero, hourly cards and daily rows.
struct ForecastConditionSymbol: View {
  let icon: ForecastWeatherIcon
  var onHero = false
  @Environment(\.colorScheme) private var colorScheme

  private var colours: (Color, Color, Color) {
    let darkSurface = onHero || colorScheme == .dark
    let sun = Color(hex: "#ffd36f")
    let cloud = Color(hex: onHero ? "#d9e9ef" : darkSurface ? "#aec3d1" : "#7c94a6")
    let softCloud = Color(hex: onHero ? "#e9f3f6" : darkSurface ? "#c8d8e2" : "#95adbc")
    let rain = Color(hex: darkSurface ? "#76d6ff" : "#0878c9")
    let snow = Color(hex: darkSurface ? "#d7f6ff" : "#397694")
    let mist = Color(hex: darkSurface ? "#b9cdd7" : "#718b9b")
    let lightning = Color(hex: "#ffd15c")
    switch icon {
    case .clearDay, .clearNight: return (sun, sun, sun)
    case .partlyCloudyDay, .partlyCloudyNight: return (softCloud, sun, sun)
    case .cloudy: return (cloud, cloud, cloud)
    case .rain, .drizzle: return (cloud, rain, rain)
    case .thunderstorms: return (cloud, lightning, rain)
    case .snow, .hail: return (cloud, snow, snow)
    case .sleet: return (cloud, rain, snow)
    case .fog: return (cloud, mist, mist)
    case .hazeDay, .hazeNight: return (mist, sun, sun)
    case .smoke: return (mist, cloud, cloud)
    case .wind: return (rain, rain, rain)
    case .unknown: return (mist, mist, mist)
    }
  }

  var body: some View {
    if icon == .thunderstorms {
      // The rain/bolt symbol shares a palette layer for cloud and lightning.
      // Overlay the native bolt-only layer to colour it independently.
      ZStack {
        Image(systemName: icon.symbolName)
          .symbolRenderingMode(.palette)
          .foregroundStyle(colours.0, colours.2)
        Image(systemName: "cloud.bolt.fill")
          .symbolRenderingMode(.palette)
          .foregroundStyle(Color.clear, colours.1)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityAddTraits(.isImage)
      .accessibilityLabel(icon.label)
    } else {
      Image(systemName: icon.symbolName)
        .symbolRenderingMode(.palette)
        .foregroundStyle(colours.0, colours.1, colours.2)
    }
  }
}

struct StatusMessage: View {
  let text: String
  var symbol = "info.circle"
  var body: some View {
    Label(text, systemImage: symbol).font(.footnote)
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    let value = trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}
