import Foundation

/// Compile alongside the app's WeatherAPI.swift and Models/*.swift; no network or secrets.
@main struct ForecastDecodeBenchmark {
  static func main() throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    for _ in 0..<3 {
      let start = ContinuousClock.now
      let result = try WeatherAPI.decoder().decode(ForecastRegionsResponse.self, from: data)
      print(
        "bytes=\(data.count) regions=\(result.regions.count) decode=\(start.duration(to: .now))")
    }
  }
}
