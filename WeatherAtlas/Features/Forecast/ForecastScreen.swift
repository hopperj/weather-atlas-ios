import Charts
import SwiftUI

protocol ForecastServing: Sendable {
  func forecastRegions() async throws -> ForecastRegionsResponse
  func halifaxForecast() async throws -> ForecastRegion?
  func defaultForecast(at place: SavedPlace) async throws -> ForecastRegion?
  func nearestForecast(longitude: Double, latitude: Double) async throws -> NearbyForecast
  func hourlyForecast(areaID: String) async throws -> HourlyForecast
  func precipitationForecast(areaID: String) async throws -> PrecipitationForecast
}

extension ForecastServing {
  func defaultForecast(at place: SavedPlace) async throws -> ForecastRegion? {
    try await forecastRegions().regions.first { $0.id == place.id }
  }
  func halifaxForecast() async throws -> ForecastRegion? {
    try await forecastRegions().regions.first(where: \.isHalifaxMetro)
  }
}

extension WeatherAPI: ForecastServing {}

@MainActor
final class ForecastModel: ObservableObject {
  @Published var regions: [ForecastRegion] = []
  @Published private(set) var region: ForecastRegion?
  @Published private(set) var hourly: HourlyForecast?
  @Published private(set) var precipitation: PrecipitationForecast?
  @Published private(set) var error: String?
  @Published private(set) var regionListError: String?
  @Published private(set) var loading = false
  @Published private(set) var hourlyLoading = false
  @Published private(set) var precipitationLoading = false
  @Published private(set) var regionListLoading = false
  @Published private(set) var nearbyDistanceKm: Double?
  @Published private(set) var usingDefaultLocation = false
  @Published private(set) var fallbackMessage: String?
  @Published private(set) var usingLastLocation = false
  @Published private(set) var showingSavedData = false
  @Published private(set) var lastUpdated: Date?
  @Published private(set) var refreshIncomplete = false
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
    nearbyDistanceKm = nil
    usingDefaultLocation = false
    usingLastLocation = false
    fallbackMessage = nil
    showingSavedData = false
    lastUpdated = nil
    error = nil
    refreshIncomplete = false
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
    loading = false
    hourlyLoading = false
    precipitationLoading = false
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
        lastUpdated = nil
        showingSavedData = false
      } else if precipitation?.issuedAt != selected.issuedAt {
        precipitation = nil
      }
      region = selected
      loading = false
      hourlyLoading = true
      precipitationLoading = selected.periods.contains(where: \.needsPrecipitationEstimate)
      // Neither optional forecast should delay or suppress the other.
      saveSnapshot()  // A successful bulletin is useful even if optional feeds later fail.
      async let hours = loadHourly(areaID: selected.id, request: request)
      async let amounts = loadPrecipitation(for: selected, request: request)
      let (hoursOK, amountsOK) = await (hours, amounts)
      guard request == revision && !Task.isCancelled else { return }
      if hoursOK && amountsOK {
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
      else { return false }
      precipitation = result
      return true
    } catch {
      // Keep the issued bulletin and hourly forecast. Wet periods explicitly
      // say "amount unavailable" instead of interpreting a failed request as zero.
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
  @State private var choosingRegion = false
  @State private var mapRegion: ForecastRegion?
  @State private var query = ""
  @State private var forecastView: ForecastViewMode = .daily
  @State private var hourlyPlot: HourlyPlot = .temperature
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
          if let region = model.region {
            hero(region)
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
            ForecastInsightsView(region: region, summary: store.forecastSummary)
              .id(region.id)
            if forecastView == .daily {
              dailySection(region)
            } else {
              hourlySection
            }
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
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
      : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
    return layout {
      VStack(alignment: .leading, spacing: 4) {
        Text(region.displayName).font(.title2.bold())
          .accessibilityIdentifier("forecastLocationName")
        Text("Issued \(region.issuedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption).opacity(0.85)
          .accessibilityIdentifier("forecastIssuedAt")
      }.frame(maxWidth: .infinity, alignment: .leading)
      Button("Show on map", systemImage: "map") {
        mapRegion = region
      }
      .font(.subheadline).buttonStyle(.bordered).tint(.white)
      .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
    }
    .padding(16).foregroundStyle(.white)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      LinearGradient(
        colors: [
          Color(red: 0.04, green: 0.22, blue: 0.3),
          Color(red: 0.02, green: 0.45, blue: 0.48),
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing),
      in: RoundedRectangle(cornerRadius: 16)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("forecastHeader")
  }

  private func dailySection(_ region: ForecastRegion) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("The week ahead").font(.title2.bold())
      if region.periods.isEmpty {
        Text("No current forecast periods are available.").foregroundStyle(.secondary)
      }
      ForEach(region.periods) { period in
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text(period.name).font(.headline)
            Spacer()
            HStack(spacing: 8) {
              Image(systemName: period.weatherIcon.symbolName)
                // Multicolor weather symbols have white clouds that vanish on light cards.
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.tint)
                .font(.title2)
                .frame(minWidth: 32)
                .accessibilityLabel(period.weatherIcon.label)
                .accessibilityIdentifier("forecast-condition-\(period.name)")
              Text(metric(period.temperatureC, "°")).font(.title2.bold())
                .accessibilityIdentifier("forecast-temperature-\(period.name)")
            }.fixedSize()
          }
          Text(period.condition.isEmpty ? "Condition not issued" : period.condition).font(
            .subheadline)
          HStack(spacing: 14) {
            Label(metric(period.popPercent, "%"), systemImage: "drop")
            Text("Humidity \(metric(period.relativeHumidityPercent, "%"))")
            Spacer(minLength: 0)
          }.font(.caption).foregroundStyle(.secondary)
          if let amount = model.precipitationDescription(for: period) {
            Text(amount).font(.caption).foregroundStyle(.secondary)
              .accessibilityIdentifier("precipitation-\(period.name)")
          }
        }.padding().background(.background, in: RoundedRectangle(cornerRadius: 16))
      }
      if model.hasPrecipitationEstimates {
        Text(
          "Model estimates (ECCC GDPS) cover the full day or night at the region’s reference location. Amounts are in mm of water equivalent: rain plus melted snow, not snow depth."
        ).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private var hourlySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Next 72 hours").font(.title2.bold())
      if model.hourlyLoading && model.hourly == nil {
        ProgressView("Loading hourly forecast…")
          .accessibilityIdentifier("hourlyForecastInitialLoading")
      }
      if let hourly = model.hourly {
        Text("\(hourly.source) · \(hourly.completeHours) of \(hourly.hours.count) complete hours")
          .font(.caption).foregroundStyle(.secondary)
        Text(hourlyPlot.chartTitle).font(.headline)
          .accessibilityIdentifier("hourlyChartTitle")
        hourlyChart(hourly)
          .id(hourlyPlot)
          .frame(height: 170)
          .accessibilityLabel(
            "Hourly \(hourlyPlot.chartTitle) chart; all values are available in the table below"
          )
          .accessibilityIdentifier("hourlyForecastChart")
        Text("Tap a column header to change the chart.")
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
      } else if !model.hourlyLoading {
        Text("Hourly forecast unavailable. Pull down to try again.")
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private func hourlyChart(_ hourly: HourlyForecast) -> some View {
    let axis = HourlyDayAxis(start: hourly.start, end: hourly.end, calendar: chartCalendar)
    Chart(hourly.hours) { hour in
      if let value = hourlyPlot.value(for: hour) {
        PointMark(x: .value("Time", hour.time), y: .value(hourlyPlot.title, value))
          .foregroundStyle(.teal).symbolSize(16)
      }
    }
    .chartXScale(domain: axis.domain)
    .chartXAxis {
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
    .chartYAxisLabel(hourlyPlot.unit)
    .accessibilityValue(
      "Daily ticks at midnight: "
        + axis.ticks.map { axis.label(for: $0, locale: locale) }.joined(separator: ", ")
    )
    .overlay {
      if !hourly.hours.contains(where: { hourlyPlot.value(for: $0) != nil }) {
        Text("No \(hourlyPlot.title.lowercased()) data available")
          .font(.callout).foregroundStyle(.secondary)
      }
    }
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

struct StatusMessage: View {
  let text: String
  var symbol = "info.circle"
  var body: some View {
    Label(text, systemImage: symbol).font(.footnote)
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
  }
}
