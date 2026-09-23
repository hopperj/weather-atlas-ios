import Foundation

struct ForecastSnapshot: Codable {
  let storedAt: Date
  let selectionID: String
  let region: ForecastRegion
  let hourly: HourlyForecast?
  let precipitation: PrecipitationForecast?
  let usingDefaultLocation: Bool
  let lastUpdated: Date?
  var defaultLocationID: String? = nil

  private enum CodingKeys: String, CodingKey {
    case storedAt, selectionID, region, hourly, precipitation, lastUpdated, defaultLocationID
    // Preserve forecasts saved before the default became configurable.
    case usingDefaultLocation = "usingHalifaxFallback"
  }
}

/// Only the latest automatic and latest manually chosen forecasts per server.
/// This stores public regional forecasts, not a history of phone coordinates.
@MainActor final class ForecastSnapshotStore {
  private let defaults: UserDefaults
  private let prefix: String
  static let maximumAge: TimeInterval = 24 * 60 * 60

  init(serverURL: URL, defaults: UserDefaults = .standard) {
    self.defaults = defaults
    prefix = "forecastSnapshot:v1:\(serverURL.absoluteString):"
  }
  private func key(_ selectionID: String) -> String {
    prefix + (selectionID.isEmpty ? "automatic" : "manual")
  }
  func read(
    selectionID: String, defaultLocationID: String? = nil, now: Date = Date()
  ) -> ForecastSnapshot? {
    guard let data = defaults.data(forKey: key(selectionID)),
      let snapshot = try? JSONDecoder().decode(ForecastSnapshot.self, from: data),
      snapshot.selectionID == selectionID,
      !selectionID.isEmpty || snapshot.defaultLocationID == defaultLocationID,
      selectionID.isEmpty || snapshot.region.id == selectionID,
      now.timeIntervalSince(snapshot.storedAt) >= -60,
      now.timeIntervalSince(snapshot.storedAt) <= Self.maximumAge,
      snapshot.region.periods.contains(where: { $0.end > now })
    else { return nil }
    return snapshot
  }
  func save(_ snapshot: ForecastSnapshot) {
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    defaults.set(data, forKey: key(snapshot.selectionID))
  }
}

struct ForecastRequest: Hashable {
  let serverURL: URL
  let selectedID: String
  let location: ForecastLocationFix?
  let useDefaultLocation: Bool
  let defaultLocation: SavedPlace?
  let locationUnavailable: Bool
  let enabled: Bool
  let refresh: Int
}

enum ForecastRefreshPolicy {
  static let interval: Duration = .seconds(300)

  /// GPS can start immediately, but its arrival must not cancel the only request
  /// that can put a first bulletin on screen. Failures release the gate as well.
  static func locationForRequest(
    fix: ForecastLocationFix?, followsLocation: Bool,
    hasBulletin: Bool, initialRequestFailed: Bool, now: Date = Date()
  ) -> ForecastLocationFix? {
    guard followsLocation, hasBulletin || initialRequestFailed, let fix,
      now.timeIntervalSince(fix.measuredAt) >= -5,
      now.timeIntervalSince(fix.measuredAt) <= 300
    else { return nil }
    return fix
  }

  /// The root view owns this task so switching tabs cannot restart its clock.
  @MainActor static func run(
    active: Bool,
    sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    refresh: () -> Void
  ) async {
    guard active else { return }
    while !Task.isCancelled {
      do { try await sleep(interval) } catch { return }
      guard !Task.isCancelled else { return }
      refresh()
    }
  }
}
