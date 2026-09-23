import CoreLocation
import SwiftUI

struct ForecastLocationFix: Hashable, Sendable {
  let latitude: Double
  let longitude: Double
  let measuredAt: Date
}

@MainActor
protocol ForecastLocationDriving: AnyObject {
  var delegate: (any CLLocationManagerDelegate)? { get set }
  var authorizationStatus: CLAuthorizationStatus { get }
  var desiredAccuracy: CLLocationAccuracy { get set }
  var distanceFilter: CLLocationDistance { get set }
  func requestWhenInUseAuthorization()
  func startUpdatingLocation()
  func stopUpdatingLocation()
}

extension CLLocationManager: ForecastLocationDriving {}

/// Foreground location for selecting server forecasts, never a weather collection job.
@MainActor
final class ForecastLocation: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate
{
  @Published private(set) var fix: ForecastLocationFix?
  @Published private(set) var locating = false
  @Published private(set) var message: String?
  @Published private(set) var permissionDenied = false
  private var storedManager: (any ForecastLocationDriving)?
  private let makeManager: @MainActor () -> any ForecastLocationDriving
  private var manager: any ForecastLocationDriving {
    if let storedManager { return storedManager }
    let started = ContinuousClock.now
    WeatherDiagnostics.startup.notice("Starting location service after initial presentation")
    let created = makeManager()
    storedManager = created
    created.delegate = self
    created.desiredAccuracy = kCLLocationAccuracyKilometer
    created.distanceFilter = 1_000
    WeatherDiagnostics.startup.notice(
      "Location service ready in \(String(describing: started.duration(to: .now)), privacy: .public)"
    )
    return created
  }
  private var active = false
  private var updating = false
  private var timeout: Task<Void, Never>?

  /// Indicates failed acquisition for location UI; forecast startup no longer waits on this.
  var shouldUseDefaultLocation: Bool {
    fix == nil && !locating && message != nil
  }

  init(
    makeManager: @escaping @MainActor () -> any ForecastLocationDriving = { CLLocationManager() }
  ) {
    self.makeManager = makeManager
    super.init()
  }

  convenience init(manager: any ForecastLocationDriving) {
    self.init(makeManager: { manager })
  }

  func start() {
    guard !active else { return }
    active = true
    // A recent foreground fix remains usable while a new one is acquired.
    if let fix, Date().timeIntervalSince(fix.measuredAt) > 300 { self.fix = nil }
    message = nil
    updateAuthorization()
  }

  func stop() {
    guard active else { return }
    active = false
    stopUpdates()
    locating = false
  }

  func refresh() {
    guard active else { return }
    stop()
    start()
  }

  func updateAuthorization() {
    guard active else { return }
    permissionDenied = false
    switch manager.authorizationStatus {
    case .notDetermined:
      locating = true
      manager.requestWhenInUseAuthorization()
    case .authorizedAlways, .authorizedWhenInUse:
      guard !updating else { return }
      locating = fix == nil
      message = nil
      updating = true
      manager.startUpdatingLocation()
      timeout?.cancel()
      timeout = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(20)) } catch { return }
        self?.locationWaitTimedOut()
      }
    case .denied, .restricted:
      stopUpdates()
      fix = nil
      locating = false
      permissionDenied = true
      message = "Location access is unavailable. Enable it in iPhone Settings or choose a region."
    @unknown default:
      stopUpdates()
      fix = nil
      locating = false
      message = "Your location is unavailable. Choose a region to see its forecast."
    }
  }

  func locationWaitTimedOut() {
    guard active, updating, fix == nil else { return }
    locating = false
    message = "Your location is unavailable. Try again or choose a region."
    // Keep foreground updates running so a later fix can replace the fallback.
  }

  private func stopUpdates() {
    if updating { storedManager?.stopUpdatingLocation() }
    updating = false
    timeout?.cancel()
    timeout = nil
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    updateAuthorization()
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    receive(locations)
  }

  func receive(_ locations: [CLLocation], now: Date = Date()) {
    guard active, updating,
      let latest = locations.last(where: {
        $0.horizontalAccuracy >= 0 && CLLocationCoordinate2DIsValid($0.coordinate)
          && now.timeIntervalSince($0.timestamp) >= -5
          && now.timeIntervalSince($0.timestamp) <= 120
      })
    else { return }
    if let fix,
      latest.distance(from: CLLocation(latitude: fix.latitude, longitude: fix.longitude)) < 1_000,
      now.timeIntervalSince(fix.measuredAt) < 300
    {
      return
    }
    timeout?.cancel()
    timeout = nil
    fix = ForecastLocationFix(
      latitude: latest.coordinate.latitude, longitude: latest.coordinate.longitude,
      measuredAt: latest.timestamp)
    locating = false
    message = nil
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard active else { return }
    if (error as? CLError)?.code == .denied {
      updateAuthorization()
    } else if (error as? CLError)?.code != .locationUnknown {
      locating = false
      message = "Your location is unavailable. Try again or choose a region."
    }
  }
}
