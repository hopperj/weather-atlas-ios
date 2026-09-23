import MapKit
import SwiftUI

/// Only the user's explicit pin is persisted, never a history of GPS positions.
struct ForecastMapPin: Codable, Equatable, Sendable {
  let regionID: String
  let latitude: Double
  let longitude: Double
  var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
  var isValid: Bool { CLLocationCoordinate2DIsValid(coordinate) }
}

protocol ForecastLocationMapServing: Sendable {
  func forecastRegions() async throws -> ForecastRegionsResponse
  func nearestForecast(longitude: Double, latitude: Double) async throws -> NearbyForecast
}
extension WeatherAPI: ForecastLocationMapServing {}

@MainActor final class ForecastLocationMapModel: ObservableObject {
  @Published private(set) var regions: [ForecastRegion]
  @Published private(set) var selected: ForecastRegion?
  @Published private(set) var pin: CLLocationCoordinate2D?
  @Published private(set) var focus: CLLocationCoordinate2D
  @Published private(set) var focusRevision = 0
  @Published private(set) var lookingUp = false
  @Published private(set) var loadingCities = false
  @Published private(set) var error: String?
  @Published private(set) var citiesError: String?
  private let api: any ForecastLocationMapServing
  private var lookup: Task<Void, Never>?
  private var revision = 0

  init(region: ForecastRegion, pin: ForecastMapPin?, api: any ForecastLocationMapServing) {
    regions = [region]
    selected = region
    let restoredPin = pin.flatMap { $0.regionID == region.id && $0.isValid ? $0.coordinate : nil }
    self.pin = restoredPin
    focus = restoredPin ?? region.coordinate
    self.api = api
  }

  var confirmedPin: ForecastMapPin? {
    guard let selected, let pin else { return nil }
    return ForecastMapPin(regionID: selected.id, latitude: pin.latitude, longitude: pin.longitude)
  }

  func cities(matching query: String) -> [ForecastRegion] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return regions.filter {
      query.isEmpty
        || "\($0.displayName) \($0.name) \($0.provinceName)".localizedCaseInsensitiveContains(query)
    }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }

  func loadCities() async {
    loadingCities = true
    citiesError = nil
    defer { loadingCities = false }
    do {
      let response = try await api.forecastRegions()
      try Task.checkCancellation()
      regions = response.regions
    } catch {
      guard !Task.isCancelled else { return }
      citiesError = "Could not load cities and towns. \(error.localizedDescription)"
    }
  }

  func choose(_ region: ForecastRegion) {
    cancel()
    selected = region
    pin = nil
    error = nil
    focus = region.coordinate
    focusRevision += 1
  }

  func dropPin(at coordinate: CLLocationCoordinate2D) {
    guard CLLocationCoordinate2DIsValid(coordinate) else { return }
    cancel()
    let ticket = revision
    pin = coordinate
    selected = nil
    error = nil
    lookingUp = true
    lookup = Task { [weak self, api] in
      do {
        let result = try await api.nearestForecast(
          longitude: coordinate.longitude, latitude: coordinate.latitude)
        guard let self, !Task.isCancelled, self.revision == ticket else { return }
        self.selected = result.region
        self.lookingUp = false
      } catch {
        guard let self, !Task.isCancelled, self.revision == ticket else { return }
        self.lookingUp = false
        if case WeatherAPIError.server(let status, let detail) = error, status == 404 {
          self.error =
            detail == "Not Found"
            ? "This server cannot look up pins yet. Choose a city or town instead."
            : "No forecast is available near this pin. Try another spot or choose a city or town."
        } else {
          self.error = "Could not find a forecast for this pin. \(error.localizedDescription)"
        }
      }
    }
  }

  func cancel() {
    revision += 1
    lookup?.cancel()
    lookup = nil
    lookingUp = false
  }
}

struct ForecastLocationMap: View {
  @StateObject private var model: ForecastLocationMapModel
  @Environment(\.dismiss) private var dismiss
  @State private var choosingCity = false
  @State private var query = ""
  let onConfirm: (ForecastRegion, ForecastMapPin?) -> Void

  init(
    region: ForecastRegion, pin: ForecastMapPin?, api: WeatherAPI,
    onConfirm: @escaping (ForecastRegion, ForecastMapPin?) -> Void
  ) {
    _model = StateObject(wrappedValue: ForecastLocationMapModel(region: region, pin: pin, api: api))
    self.onConfirm = onConfirm
  }

  var body: some View {
    NavigationStack {
      ForecastLocationMapSurface(
        regions: model.regions, selectedID: model.selected?.id, pin: model.pin,
        focus: model.focus, focusRevision: model.focusRevision,
        onDropPin: model.dropPin, onSelectCity: model.choose
      )
      .ignoresSafeArea(edges: .bottom)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(alignment: .leading, spacing: 10) {
          Text("Tap or hold the map to drop a pin, or choose a city or town.")
            .font(.caption).foregroundStyle(.secondary)
          if model.lookingUp {
            ProgressView("Finding forecast…")
          } else if let error = model.error {
            Text(error).font(.subheadline).accessibilityIdentifier("forecastPinError")
            if let pin = model.pin {
              Button("Try again") { model.dropPin(at: pin) }
            }
          } else if let selected = model.selected {
            Text(selected.displayName).font(.headline)
              .accessibilityIdentifier("forecastMapSelection")
            if model.pin != nil {
              Text("Nearest available regional forecast to your pin.")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          Button("Use this forecast") {
            guard let selected = model.selected, !model.lookingUp else { return }
            onConfirm(selected, model.confirmedPin)
            dismiss()
          }
          .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
          .disabled(model.selected == nil || model.lookingUp)
          .accessibilityIdentifier("useMapForecast")
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
      }
      .navigationTitle("Forecast location").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
          Button("Choose city or town", systemImage: "magnifyingglass") { choosingCity = true }
            .accessibilityIdentifier("forecastMapCitySearch")
        }
      }
      .task { await model.loadCities() }
      .onDisappear { model.cancel() }
      .sheet(isPresented: $choosingCity) {
        NavigationStack {
          List {
            if model.loadingCities { ProgressView("Loading cities and towns…") }
            if let error = model.citiesError {
              Text(error).font(.caption)
              Button("Try again") { Task { await model.loadCities() } }
            }
            ForEach(model.cities(matching: query)) { region in
              Button {
                model.choose(region)
                choosingCity = false
              } label: {
                VStack(alignment: .leading) {
                  Text(region.displayName)
                  Text(region.provinceName).font(.caption).foregroundStyle(.secondary)
                }
              }.accessibilityIdentifier("forecast-map-city-\(region.id)")
            }
            if !model.loadingCities && model.cities(matching: query).isEmpty {
              Text("No matching forecasts on this server.").foregroundStyle(.secondary)
            }
          }
          .navigationTitle("Cities and towns").navigationBarTitleDisplayMode(.inline)
          .searchable(text: $query, prompt: "City, town or province")
          .toolbar { Button("Done") { choosingCity = false } }
        }
      }
    }
  }
}

/// Deliberately separate from MapSurface: no raster, radar, satellite, station or sample machinery.
struct ForecastLocationMapSurface: UIViewRepresentable {
  let regions: [ForecastRegion]
  let selectedID: String?
  let pin: CLLocationCoordinate2D?
  let focus: CLLocationCoordinate2D
  let focusRevision: Int
  let onDropPin: (CLLocationCoordinate2D) -> Void
  let onSelectCity: (ForecastRegion) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> MKMapView {
    let map = MKMapView(frame: .zero)
    let config = MKStandardMapConfiguration(elevationStyle: .flat)
    config.pointOfInterestFilter = .excludingAll
    config.showsTraffic = false
    map.preferredConfiguration = config
    map.accessibilityIdentifier = "forecastLocationMap"
    map.delegate = context.coordinator
    let tap = UITapGestureRecognizer(
      target: context.coordinator, action: #selector(Coordinator.drop(_:)))
    tap.delegate = context.coordinator
    tap.cancelsTouchesInView = false
    map.addGestureRecognizer(tap)
    let hold = UILongPressGestureRecognizer(
      target: context.coordinator, action: #selector(Coordinator.drop(_:)))
    hold.delegate = context.coordinator
    map.addGestureRecognizer(hold)
    return map
  }
  func updateUIView(_ map: MKMapView, context: Context) {
    context.coordinator.parent = self
    context.coordinator.update(map)
  }
  static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) { map.delegate = nil }

  final class CityAnnotation: NSObject, MKAnnotation {
    let region: ForecastRegion
    var coordinate: CLLocationCoordinate2D { region.coordinate }
    var title: String? { region.displayName }
    init(_ region: ForecastRegion) { self.region = region }
  }

  final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
    var parent: ForecastLocationMapSurface
    private var displayedRegions: [ForecastRegion] = []
    private var focusRevision: Int?
    private var pin: MKPointAnnotation?
    init(_ parent: ForecastLocationMapSurface) { self.parent = parent }
    func update(_ map: MKMapView) {
      if focusRevision != parent.focusRevision {
        map.setRegion(
          .init(
            center: parent.focus,
            span: .init(latitudeDelta: 1.2, longitudeDelta: 1.6)), animated: focusRevision != nil)
        focusRevision = parent.focusRevision
      }
      if displayedRegions != parent.regions {
        map.removeAnnotations(map.annotations.compactMap { $0 as? CityAnnotation })
        map.addAnnotations(parent.regions.map(CityAnnotation.init))
        displayedRegions = parent.regions
      }
      if let coordinate = parent.pin {
        if pin == nil {
          let annotation = MKPointAnnotation()
          annotation.title = "Dropped pin"
          annotation.coordinate = coordinate
          pin = annotation
          map.addAnnotation(annotation)
        } else {
          pin?.coordinate = coordinate
        }
      } else if let pin {
        map.removeAnnotation(pin)
        self.pin = nil
      }
      for case let city as CityAnnotation in map.annotations {
        (map.view(for: city) as? MKMarkerAnnotationView)?.markerTintColor =
          city.region.id == parent.selectedID ? .systemTeal : .systemBlue
      }
    }
    func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
      let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
      view.canShowCallout = false
      if let city = annotation as? CityAnnotation {
        view.glyphImage = UIImage(systemName: "building.2.fill")
        view.markerTintColor = city.region.id == parent.selectedID ? .systemTeal : .systemBlue
        view.clusteringIdentifier = "forecastCities"
        view.accessibilityLabel = city.region.displayName
        view.accessibilityIdentifier = "forecast-city-marker-\(city.region.id)"
      } else if annotation is MKClusterAnnotation {
        view.markerTintColor = .systemBlue
      } else {
        view.glyphImage = UIImage(systemName: "mappin")
        view.markerTintColor = .systemRed
        view.displayPriority = .required
        view.accessibilityLabel = "Dropped pin"
        view.accessibilityIdentifier = "forecastDroppedPin"
      }
      return view
    }
    func mapView(_ map: MKMapView, didSelect view: MKAnnotationView) {
      if let city = view.annotation as? CityAnnotation { parent.onSelectCity(city.region) }
      if let cluster = view.annotation as? MKClusterAnnotation {
        map.showAnnotations(cluster.memberAnnotations, animated: true)
      }
      if let annotation = view.annotation { map.deselectAnnotation(annotation, animated: false) }
    }
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      var view = touch.view
      while let current = view {
        if current is MKAnnotationView || current is UIControl { return false }
        view = current.superview
      }
      return true
    }
    @objc func drop(_ gesture: UIGestureRecognizer) {
      let triggered =
        gesture is UILongPressGestureRecognizer ? gesture.state == .began : gesture.state == .ended
      guard triggered, let map = gesture.view as? MKMapView else { return }
      parent.onDropPin(map.convert(gesture.location(in: map), toCoordinateFrom: map))
    }
  }
}
