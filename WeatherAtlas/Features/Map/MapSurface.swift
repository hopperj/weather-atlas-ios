import MapKit
import SwiftUI

struct MapSurface: UIViewRepresentable {
  let frame: MapFramePresentation?
  let requestID: String
  let contextID: String
  let api: WeatherAPI
  var place: SavedPlace?
  var placeRequest = 0
  var locationRequest = 0
  var bounds: [Double]?
  var fitRequest = 0
  var sampleCoordinate: CLLocationCoordinate2D?
  var points: [DisplayPoint] = []
  var onStationTap: (String) -> Void = { _ in }
  var onViewportChange: ([Double]) -> Void = { _ in }
  var onLocationError: (String) -> Void = { _ in }
  var onFrameState: (String, MapFrameState) -> Void = { _, _ in }
  let onTap: (CLLocationCoordinate2D) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

  func makeUIView(context: Context) -> MKMapView {
    let map = MKMapView(frame: .zero)
    map.delegate = context.coordinator
    context.coordinator.map = map
    MapAppearance.configure(map, weatherOverlay: context.coordinator.rasterOverlay)
    map.setRegion(
      MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 45.1, longitude: -63.1),
        span: MKCoordinateSpan(latitudeDelta: 5.0, longitudeDelta: 7.0)
      ),
      animated: false
    )
    let gesture = UITapGestureRecognizer(
      target: context.coordinator, action: #selector(Coordinator.mapTapped(_:)))
    gesture.cancelsTouchesInView = false
    map.addGestureRecognizer(gesture)
    context.coordinator.locationManager.delegate = context.coordinator
    return map
  }

  func updateUIView(_ map: MKMapView, context: Context) {
    context.coordinator.onTap = onTap
    context.coordinator.onStationTap = onStationTap
    context.coordinator.onViewportChange = onViewportChange
    context.coordinator.onLocationError = onLocationError
    context.coordinator.onFrameState = onFrameState
    context.coordinator.updateIndependentPoints(points)
    context.coordinator.update(frame: frame, requestID: requestID, contextID: contextID, api: api)
    context.coordinator.navigate(
      place: place, placeRequest: placeRequest, request: locationRequest, bounds: bounds,
      fit: fitRequest, sample: sampleCoordinate)
  }

  static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
    coordinator.cancelPreparation()
    map.delegate = nil
  }

  final class Coordinator: NSObject, MKMapViewDelegate, @preconcurrency CLLocationManagerDelegate {
    var onTap: (CLLocationCoordinate2D) -> Void
    var onStationTap: (String) -> Void = { _ in }
    weak var map: MKMapView?
    let locationManager = CLLocationManager()
    private var locationRequest = 0
    private var fitRequest = 0
    private var placeRequest = 0
    private var marker: MKPointAnnotation?
    var onViewportChange: ([Double]) -> Void = { _ in }
    var onLocationError: (String) -> Void = { _ in }
    private var points: [DisplayPoint] = []
    private var annotations: [WeatherAnnotation] = []
    let rasterOverlay = BufferedRasterOverlay()
    private lazy var rasterRenderer = BufferedRasterRenderer(overlay: rasterOverlay)
    private let loader = RasterFrameLoader()
    private let presentationFence = MapPresentationFence()
    private var loadTask: Task<Void, Never>?
    private var generation = 0
    private var requestID = ""
    private var contextID = ""
    private var frame: MapFramePresentation?
    private var api: WeatherAPI?
    private var preparedLayers: [MapRasterLayer] = []
    private var independentPoints: [DisplayPoint] = []
    private var presentedWind: [DisplayPoint] = []
    private var moving = false
    var onFrameState: (String, MapFrameState) -> Void = { _, _ in }

    init(onTap: @escaping (CLLocationCoordinate2D) -> Void) {
      self.onTap = onTap
    }

    func update(frame: MapFramePresentation?, requestID: String, contextID: String, api: WeatherAPI)
    {
      let changed =
        self.requestID != requestID || preparedLayers != (frame?.layers ?? [])
        || self.frame?.wind != frame?.wind
      if self.contextID != contextID {
        // Do not retain an unrelated product under a new title or map mode.
        rasterRenderer.install([], viewport: .null, onDrawn: {})
        presentedWind = []
        updatePoints(independentPoints)
        self.contextID = contextID
      }
      self.frame = frame
      self.requestID = requestID
      self.api = api
      guard changed else { return }
      preparedLayers = frame?.layers ?? []
      prepareFrame()
    }

    func cancelPreparation() {
      generation += 1
      loadTask?.cancel()
      presentationFence.cancel()
    }

    private func prepareFrame() {
      cancelPreparation()
      let generation = generation
      let id = requestID
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generation == generation else { return }
        self.onFrameState(id, .loading)
      }
      guard !moving, let frame, let api, let map, map.bounds.width > 0 else { return }
      if frame.layers.isEmpty {
        // A standalone wind-direction frame has only annotations. It does not
        // fetch a hidden raster or inherit the previous weather overlay.
        rasterRenderer.install([], viewport: .null, onDrawn: {})
        presentedWind = frame.wind
        updatePoints(frame.wind)
        presentationFence.wait { [weak self] in
          guard let self, generation == self.generation else { return }
          self.onFrameState(id, .displayed)
        }
        return
      }
      let viewport = map.visibleMapRect
      let tiles = RasterTile.covering(viewport, viewWidth: map.bounds.width)
      loadTask = Task { [weak self, loader] in
        do {
          let prepared = try await loader.prepare(layers: frame.layers, tiles: tiles, api: api)
          try Task.checkCancellation()
          guard let self, generation == self.generation else { return }
          self.presentedWind = frame.wind
          self.updatePoints(self.independentPoints + frame.wind)
          self.rasterRenderer.install(prepared, viewport: viewport) { [weak self] in
            Task { @MainActor [weak self] in
              guard let self, generation == self.generation else { return }
              self.presentationFence.wait { [weak self] in
                guard let self, generation == self.generation else { return }
                self.onFrameState(id, .displayed)
              }
            }
          }
        } catch {
          guard let self, !Task.isCancelled, generation == self.generation else { return }
          self.onFrameState(
            id,
            .failed("The complete map frame could not be loaded. Playback is paused. Please retry.")
          )
        }
      }
    }

    func updateIndependentPoints(_ points: [DisplayPoint]) {
      independentPoints = points
      updatePoints(points + presentedWind)
    }

    func navigate(
      place: SavedPlace?, placeRequest: Int, request: Int, bounds: [Double]?, fit: Int,
      sample: CLLocationCoordinate2D?
    ) {
      if let place, self.placeRequest != placeRequest {
        self.placeRequest = placeRequest
        map?.setRegion(
          .init(
            center: .init(latitude: place.latitude, longitude: place.longitude),
            span: .init(latitudeDelta: 2, longitudeDelta: 3)), animated: true)
      }
      if request != locationRequest {
        locationRequest = request
        switch locationManager.authorizationStatus {
        case .notDetermined: locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: locationManager.requestLocation()
        default:
          DispatchQueue.main.async { [weak self] in
            self?.onLocationError(
              "Location access is disabled. Enable it for Weather Atlas in iPhone Settings, or use a saved place."
            )
          }
        }
      }
      if fit != fitRequest, let bounds, bounds.count == 4 {
        fitRequest = fit
        map?.setRegion(
          .init(
            center: .init(
              latitude: (bounds[1] + bounds[3]) / 2,
              longitude: (bounds[0] + bounds[2]) / 2),
            span: .init(
              latitudeDelta: min(160, max(1, bounds[3] - bounds[1])),
              longitudeDelta: min(359, max(1, bounds[2] - bounds[0])))), animated: true)
      }
      if let marker {
        map?.removeAnnotation(marker)
        self.marker = nil
      }
      if let sample {
        let pin = MKPointAnnotation()
        pin.coordinate = sample
        map?.addAnnotation(pin)
        marker = pin
      }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
      if locationRequest > 0
        && [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus)
      {
        manager.requestLocation()
      }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
      if let coordinate = locations.last?.coordinate {
        map?.showsUserLocation = true
        map?.setRegion(
          .init(center: coordinate, span: .init(latitudeDelta: 2, longitudeDelta: 3)),
          animated: true)
      }
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
      onLocationError("Your location is unavailable. \(error.localizedDescription)")
    }
    func updatePoints(_ newPoints: [DisplayPoint]) {
      guard newPoints != points else { return }
      map?.removeAnnotations(annotations)
      points = newPoints
      annotations = newPoints.map(WeatherAnnotation.init)
      map?.addAnnotations(annotations)
    }
    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
      moving = true
      prepareFrame()  // Invalidate the viewing timer as soon as the camera moves.
    }
    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
      moving = false
      prepareFrame()
      let r = mapView.region
      let west = max(-180, r.center.longitude - r.span.longitudeDelta / 2)
      let east = min(180, r.center.longitude + r.span.longitudeDelta / 2)
      let bounds = [
        west, max(-85, r.center.latitude - r.span.latitudeDelta / 2),
        east, min(85, r.center.latitude + r.span.latitudeDelta / 2),
      ]
      for annotation in annotations {
        if let bearing = annotation.point.bearing {
          mapView.view(for: annotation)?.transform = CGAffineTransform(
            rotationAngle: (bearing - mapView.camera.heading) * .pi / 180)
        }
      }
      // MapKit can call this synchronously inside updateUIView; publish next turn.
      DispatchQueue.main.async { [weak self] in self?.onViewportChange(bounds) }
    }
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
      if let cluster = annotation as? MKClusterAnnotation {
        let view = MKMarkerAnnotationView(annotation: cluster, reuseIdentifier: nil)
        view.glyphText = String(cluster.memberAnnotations.count)
        view.markerTintColor = .systemTeal
        return view
      }
      guard let point = annotation as? WeatherAnnotation else { return nil }
      if point.point.stationID != nil {
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: "station") as? MKMarkerAnnotationView
          ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "station")
        view.annotation = annotation
        view.glyphImage = UIImage(systemName: "thermometer.medium")
        view.markerTintColor = point.point.stale ? .systemGray : .systemTeal
        view.clusteringIdentifier = "stations"
        view.canShowCallout = true
        view.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
        return view
      }
      if let bearing = point.point.bearing {
        let view =
          mapView.dequeueReusableAnnotationView(withIdentifier: "wind")
          ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "wind")
        view.annotation = annotation
        view.image = MapAppearance.windImage(speed: point.point.windSpeedMetresPerSecond)
        view.transform = CGAffineTransform(
          rotationAngle: (bearing - mapView.camera.heading) * .pi / 180)
        view.canShowCallout = true
        return view
      }
      let view =
        mapView.dequeueReusableAnnotationView(withIdentifier: "hotspot") as? MKMarkerAnnotationView
        ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "hotspot")
      view.annotation = annotation
      view.glyphImage = UIImage(systemName: "flame.fill")
      view.markerTintColor = .systemOrange
      view.clusteringIdentifier = "hotspots"
      view.canShowCallout = true
      return view
    }

    func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                 calloutAccessoryControlTapped control: UIControl) {
      if let annotation = view.annotation as? WeatherAnnotation, let id = annotation.point.stationID {
        onStationTap(id)
      }
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
      if overlay is BufferedRasterOverlay { return rasterRenderer }
      if let coastline = overlay as? MKMultiPolyline {
        return ReferenceCoastlineRenderer(multiPolyline: coastline)
      }
      return MKOverlayRenderer(overlay: overlay)
    }

    @objc func mapTapped(_ recognizer: UITapGestureRecognizer) {
      guard recognizer.state == .ended, let map = recognizer.view as? MKMapView else { return }
      onTap(map.convert(recognizer.location(in: map), toCoordinateFrom: map))
    }
  }
}

final class WeatherAnnotation: NSObject, MKAnnotation {
  let point: DisplayPoint
  var coordinate: CLLocationCoordinate2D {
    .init(latitude: point.latitude, longitude: point.longitude)
  }
  var title: String? { point.title }
  var subtitle: String? { point.subtitle }
  init(_ point: DisplayPoint) { self.point = point }
}
