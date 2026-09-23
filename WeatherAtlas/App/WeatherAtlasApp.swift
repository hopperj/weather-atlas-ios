import SwiftUI

@main
struct WeatherAtlasApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView(configuration: .current)
    }
  }
}

struct AppConfiguration: Sendable {
  let apiBaseURL: URL

  init(apiBaseURL: URL = WeatherAtlasEndpoint.productionURL) {
    #if DEBUG
      self.apiBaseURL = apiBaseURL
    #else
      self.apiBaseURL = WeatherAtlasEndpoint.productionURL
    #endif
  }

  static var current: AppConfiguration {
    AppConfiguration(apiBaseURL: WeatherAtlasEndpoint.launchURL())
  }
}
