import SwiftUI

struct ContentView: View {
  @StateObject private var store: AppStore
  @StateObject private var location = ForecastLocation()
  @Environment(\.scenePhase) private var scenePhase
  @State private var hasOpenedMap = false
  init(configuration: AppConfiguration) {
    _store = StateObject(wrappedValue: AppStore(configuration: configuration))
  }

  var body: some View {
    TabView(selection: $store.selectedTab) {
      ForecastScreen(model: store.forecast, location: location)
        .tabItem { Label("Forecast", systemImage: "cloud.sun") }
        .tag(1)

      Group {
        if hasOpenedMap || store.selectedTab == 0 {
          MapScreen(api: store.api)
        } else {
          Color.clear
        }
      }
      .tabItem { Label("Map", systemImage: "map") }
      .tag(0)

      GolfScreen(settings: store.golfSettings)
        .tabItem { Label("Golf", systemImage: "figure.golf") }
        .tag(4)

      SavedScreen()
        .tabItem { Label("Saved", systemImage: "bookmark") }
        .tag(2)

      SettingsScreen()
        .tabItem { Label("Settings", systemImage: "gearshape") }
        .tag(3)
    }
    .id(store.serverURL)
    .tint(Color(red: 0.0, green: 0.47, blue: 0.52))
    .onAppear { WeatherDiagnostics.startup.notice("Forecast root appeared") }
    .onOpenURL { store.openWidgetURL($0) }
    .onChange(of: store.selectedTab) { _, tab in if tab == 0 { hasOpenedMap = true } }
    .background {
      ForecastLoader(model: store.forecast, location: location, enabled: scenePhase == .active)
        .id(store.serverURL)
    }
    .task(id: locationEnabled) {
      guard locationEnabled else {
        location.stop()
        return
      }
      // First paint/network tasks must not wait on Core Location service setup.
      do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      location.start()
    }
    .task(id: scenePhase) {
      await ForecastRefreshPolicy.run(active: scenePhase == .active) { store.refreshForecast() }
    }
    .environmentObject(store)
  }

  private var locationEnabled: Bool {
    scenePhase == .active && store.selectedTab == 1 && store.followsCurrentLocation
  }
}

/// Observe bulletin readiness without rebuilding the TabView for every field update.
private struct ForecastLoader: View {
  @ObservedObject var model: ForecastModel
  @ObservedObject var location: ForecastLocation
  @EnvironmentObject private var store: AppStore
  @State private var initialFailureReleasedLocation = false
  let enabled: Bool
  private var request: ForecastRequest {
    ForecastRequest(
      serverURL: store.serverURL, selectedID: store.selectedRegionID,
      location: ForecastRefreshPolicy.locationForRequest(
        fix: location.fix, followsLocation: store.followsCurrentLocation,
        hasBulletin: model.region != nil, initialRequestFailed: initialFailureReleasedLocation),
      useDefaultLocation: store.followsCurrentLocation,
      defaultLocation: store.defaultForecastLocation,
      locationUnavailable: location.shouldUseDefaultLocation,
      enabled: enabled, refresh: store.forecastRefresh)
  }
  var body: some View {
    Color.clear.frame(width: 0, height: 0)
      .onChange(of: model.error) { _, error in
        if error != nil { initialFailureReleasedLocation = true }
      }
      .onChange(of: model.region?.id) { old, new in
        if old != new,
          store.forecastSummary.currentInput?.scope
            != "\(store.serverURL.absoluteString)|\(new ?? "")"
        {
          store.forecastSummary.reset()
        }
      }
      .onDisappear { store.forecastSummary.cancel() }
      .task(id: request) {
        let next = request
        guard next.enabled else {
          model.cancel()
          store.forecastSummary.cancel()
          return
        }
        // The user can stop following GPS before any region has loaded.
        guard !next.selectedID.isEmpty || next.useDefaultLocation else {
          model.cancel()
          return
        }
        await model.load(
          preferredID: next.selectedID, location: next.location,
          useDefaultLocation: next.useDefaultLocation, defaultLocation: next.defaultLocation,
          locationUnavailable: next.locationUnavailable)
        if !Task.isCancelled {
          if let region = model.region {
            store.updateLocationNames(from: model.regions + [region])
            store.forecastSummary.prepare(
              ForecastSummaryInput(
                region: region, hourly: model.hourly, precipitation: model.precipitation,
                server: next.serverURL.absoluteString))
          }
          await store.refreshWidgetData()
        }
      }
  }
}
#Preview {
  ContentView(
    configuration: AppConfiguration(apiBaseURL: URL(string: "https://weather.example.test")!))
}
