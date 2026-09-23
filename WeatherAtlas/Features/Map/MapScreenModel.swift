import Combine
import CoreLocation
import Foundation

struct MapRasterLayer: Identifiable, Hashable, Sendable {
  let id: String
  let template: String
  let opacity: Double
}

enum MapMode: String, CaseIterable, Identifiable {
  case none = "None"
  case models = "Models"
  case radar = "Radar"
  case satellite = "Satellite"
  case hotspots = "Fire hotspots"
  case stations = "Weather stations"
  var id: String { rawValue }
}

@MainActor
final class MapScreenModel: ObservableObject {
  @Published private(set) var products: [Product] = []
  @Published private(set) var domains: [Domain] = []
  @Published private(set) var fields: [WeatherField] = []
  @Published private(set) var frames: [TimelineFrame] = []
  @Published private(set) var resolved: [ResolvedLayer] = []
  @Published private(set) var imagery: [ImageryProduct] = []
  @Published private(set) var imageryUnavailable: String?
  @Published private(set) var mode: MapMode = .models
  @Published private(set) var selectedProductCode = ""
  @Published private(set) var selectedDomainCode = ""
  @Published private(set) var selectedFieldCode = ""
  @Published private(set) var selectedOptionID = "field:air_temperature_2m"
  @Published private(set) var fieldCatalogues: [String: [WeatherField]] = [:]
  @Published private(set) var catalogueLoading = false
  @Published private(set) var catalogueError: String?
  @Published private(set) var imageryCode = ""
  @Published var selectedFrameIndex = 0
  @Published var opacity = MapAppearance.weatherOpacity {
    didSet { if opacity != oldValue { displayRevision += 1 } }
  }
  @Published var past = false
  @Published var playing = false {
    didSet { if playing != oldValue { displayRevision += 1 } }
  }
  @Published var playbackSpeed: MapPlaybackSpeed = .normal {
    didSet { if playbackSpeed != oldValue { displayRevision += 1 } }
  }
  @Published private(set) var isFrameDisplayed = false
  @Published private(set) var displayedFrame: MapFramePresentation?
  @Published private(set) var displayRevision = 0
  @Published private(set) var windLoading = false
  @Published private(set) var isLoading = false
  @Published var errorMessage: String?
  @Published var sampleResult: SampleResponse?
  @Published var sampleCoordinate: CLLocationCoordinate2D?
  @Published var timelineTruncated = false
  @Published private(set) var hotspotDate = ""
  @Published private(set) var hotspotLoading = false
  @Published var hotspotDates: [String] = []
  @Published private(set) var windPoints: [DisplayPoint] = []
  @Published private(set) var hotspotPoints: [DisplayPoint] = []
  @Published private(set) var stations: [WeatherStation] = []
  @Published var selectedStation: WeatherStation?
  @Published var stationField = StationField.temperatureC {
    didSet { if stationField != oldValue { refreshStations() } }
  }
  @Published var featureError: String?

  let api: WeatherAPI
  private var didLoad = false
  private var task: Task<Void, Never>?
  private var sampleTask: Task<Void, Never>?
  private var revision = 0
  private var windTask: Task<Void, Never>?
  private var hotspotTask: Task<Void, Never>?
  private var stationTask: Task<Void, Never>?
  private var catalogueTask: Task<Void, Never>?
  private var lastModelOptionID = "field:air_temperature_2m"
  private var lastImageryCodes: [MapMode: String] = [:]
  private var windFailed = false
  private var viewport = [-67.0, 42.0, -59.0, 48.0]
  var showWind: Bool { mode == .models && selectedOptionID == "wind" }
  var showsNoOverlay: Bool { mode == .none }
  var showHotspots: Bool { mode == .hotspots }
  var showStations: Bool { mode == .stations }
  var stationPoints: [DisplayPoint] {
    stations.map { station in
      DisplayPoint(
        id: "station:\(station.id)", longitude: station.longitude, latitude: station.latitude,
        title: "\(station.name) · \(station.formatted(stationField))",
        subtitle:
          "Observed \(station.observation.observedAt.formatted(date: .abbreviated, time: .shortened))\(station.isStale ? " · Stale" : "")",
        bearing: nil, stationID: station.id, stale: station.isStale)
    }
  }
  var isImagery: Bool { mode == .radar || mode == .satellite }
  // Standalone fire observations remain accessible in the non-imagery data list.
  var navigationMode: MapMode { isImagery ? mode : .models }
  var selectedFieldCodes: [String] { selectedFieldCode.isEmpty ? [] : [selectedFieldCode] }
  var dataOptions: [MapDataOption] {
    MapDataOption.catalogue(products: products, fields: fieldCatalogues, imagery: imagery)
  }
  var selectedOption: MapDataOption? { dataOptions.first { $0.id == selectedOptionID } }
  func source(for option: MapDataOption) -> MapDataSource? {
    option.sources.first(where: { $0.product.code == selectedProductCode }) ?? option.sources.first
  }
  func sourceLabel(for option: MapDataOption) -> String {
    source(for: option)?.label ?? option.sourceLabel
  }
  var sourceLabel: String { selectedOption.map { sourceLabel(for: $0) } ?? "" }

  init(api: WeatherAPI) { self.api = api }
  var selectedProduct: Product? { products.first { $0.code == selectedProductCode } }
  var selectedDomain: Domain? { domains.first { $0.code == selectedDomainCode } }
  var selectedField: WeatherField? { fields.first { $0.code == selectedFieldCodes.first } }
  var selectedFrame: TimelineFrame? {
    frames.indices.contains(selectedFrameIndex) ? frames[selectedFrameIndex] : nil
  }
  var imageryChoices: [ImageryProduct] { imagery.filter { $0.kind == mode.rawValue.lowercased() } }
  var selectedImagery: ImageryProduct? {
    imageryChoices.first { $0.code == imageryCode }
  }
  var imageryFrame: ImageryFrame? {
    guard let frames = selectedImagery?.frames, frames.indices.contains(selectedFrameIndex) else {
      return nil
    }
    return frames[selectedFrameIndex]
  }
  var frameCount: Int {
    mode == .models ? frames.count : isImagery ? selectedImagery?.frames.count ?? 0 : 0
  }
  var frameTime: Date? { mode == .models ? selectedFrame?.validTime : imageryFrame?.validTime }
  var presentationContextID: String {
    mode == .models
      ? "\(mode)-\(selectedOptionID)-\(selectedProductCode)-\(selectedDomainCode)"
      : "\(mode)-\(selectedImagery?.code ?? "")-\(hotspotDate)"
  }
  var requestedFrameID: String {
    "\(presentationContextID)-\(revision)-\(mode == .models ? selectedFrame?.id ?? "" : imageryFrame?.id ?? "")"
  }
  var rasterFrame: MapFramePresentation? {
    guard !isLoading, !windLoading, !windFailed, let time = frameTime,
      showWind || !rasterLayers.isEmpty
    else {
      return nil
    }
    if mode == .models && !showWind && resolved.count != 1 { return nil }
    let caption: String
    if mode == .models, let frame = selectedFrame {
      caption = frame.forecastHour.map { "Forecast +\($0) h" } ?? "Analysis · \(frame.timeKind)"
    } else {
      caption = "Observed · \(selectedFrameIndex + 1) / \(frameCount)"
    }
    return MapFramePresentation(
      id: requestedFrameID, time: time, caption: caption, title: title,
      legends: mode == .models && !showWind ? resolved : [], layers: rasterLayers,
      wind: showWind && mode == .models ? windPoints : [])
  }
  var playbackTicket: MapPlaybackTicket? {
    guard playing, isFrameDisplayed, !isLoading, !windLoading, !windFailed,
      frameCount > 1, displayedFrame?.id == requestedFrameID
    else { return nil }
    return MapPlaybackTicket(
      frameID: requestedFrameID, displayRevision: displayRevision,
      speed: playbackSpeed)
  }
  func frameStateChanged(id: String, state: MapFrameState) {
    guard id == requestedFrameID else { return }
    switch state {
    case .loading:
      isFrameDisplayed = false
      displayRevision += 1
    case .displayed:
      guard let frame = rasterFrame else { return }
      displayedFrame = frame
      isFrameDisplayed = true
      displayRevision += 1
    case .failed(let message):
      isFrameDisplayed = false
      playing = false
      errorMessage = message
    }
  }
  @discardableResult func advancePlayback(ticket: MapPlaybackTicket) -> Bool {
    guard ticket == playbackTicket else { return false }
    moveFrame(by: 1)
    return true
  }
  var rasterLayers: [MapRasterLayer] {
    if isImagery, let frame = imageryFrame,
      let template = try? api.tileTemplate(frame.tileUrl)
    {
      return [.init(id: frame.id, template: template, opacity: opacity)]
    }
    guard mode == .models, !showWind else { return [] }
    return resolved.prefix(1).compactMap { layer in
      guard let template = try? api.tileTemplate(layer.tileUrl) else { return nil }
      return .init(
        id: layer.token, template: template, opacity: opacity)
    }
  }
  var title: String {
    selectedOption?.title
      ?? (mode == .models ? selectedField?.mapLabel.0 ?? "Choose map data" : mode.rawValue)
  }
  var bounds: [Double]? { mode == .models ? selectedDomain?.bounds : imageryFrame?.bounds }

  func load() async {
    guard !didLoad else { return }
    didLoad = true
    do {
      products = try await api.products().filter(\.isStandardMapProduct).sorted {
        $0.priority < $1.priority
      }
      // A user can switch top-level tabs before the initial catalogue arrives.
      if mode == .models && selectedProductCode.isEmpty {
        selectedProductCode =
          products.first(where: { $0.latestRunTime != nil })?.code ?? products.first?.code ?? ""
        reload(productChanged: true)
      }
    } catch { if !showsNoOverlay { errorMessage = error.localizedDescription } }
    await loadImagery()
  }

  func loadImagery() async {
    let oldMode = mode
    let oldCode = imageryCode
    let oldTime = frameTime
    let wasLatest = selectedFrameIndex == frameCount - 1
    do {
      imagery = try await api.imagery().items
      imageryUnavailable = nil
      if isImagery, selectedImagery == nil, let product = preferredImagery(for: mode) {
        selectOption("imagery:\(product.code)")
      } else if mode == oldMode && imageryCode == oldCode && isImagery {
        if !wasLatest || playing,
          let index = selectedImagery?.frames.firstIndex(where: { $0.validTime == oldTime })
        {
          selectedFrameIndex = index
        } else {
          selectedFrameIndex = max(0, frameCount - 1)
        }
      }
    } catch {
      imageryUnavailable =
        "Radar and satellite frames are unavailable from this server. \(error.localizedDescription)"
    }
  }

  func loadSelectionCatalogues() async {
    if let catalogueTask {
      await catalogueTask.value
      return
    }
    // Finish this small, bounded catalogue even if the sheet is dismissed.
    // Reopening the sheet joins it instead of losing unfinished source choices.
    let loading = Task { await fetchSelectionCatalogues() }
    catalogueTask = loading
    await loading.value
    catalogueTask = nil
  }

  private func fetchSelectionCatalogues() async {
    guard !catalogueLoading else { return }
    catalogueLoading = true
    catalogueError = nil
    defer { catalogueLoading = false }
    let missing = products.filter { fieldCatalogues[$0.code] == nil }
    let api = api
    var failed: [String] = []
    // Fetch at most four standard-model field catalogues at once.
    for start in stride(from: 0, to: missing.count, by: 4) {
      await withTaskGroup(of: (String, [WeatherField]?).self) { group in
        for product in missing[start..<min(start + 4, missing.count)] {
          group.addTask { (product.code, try? await api.fields(product: product.code)) }
        }
        for await (code, result) in group {
          guard !Task.isCancelled else { continue }
          if let result { fieldCatalogues[code] = result } else { failed.append(code.uppercased()) }
        }
      }
      if Task.isCancelled { return }
    }
    if !failed.isEmpty {
      catalogueError = "Some sources are unavailable: \(failed.joined(separator: ", "))."
    }
  }

  private func preferredImagery(for mode: MapMode) -> ImageryProduct? {
    let choices = imagery.filter { $0.kind == mode.rawValue.lowercased() }
    return choices.first { $0.code == lastImageryCodes[mode] } ?? choices.first
  }

  func selectMode(_ next: MapMode) {
    if next == .none {
      selectOption(MapDataOption.noOverlay.id)
      return
    }
    guard next != navigationMode, next != .hotspots, next != .stations else { return }
    if next == .models,
      dataOptions.contains(where: { $0.id == lastModelOptionID })
    {
      selectOption(lastModelOptionID)
    } else if next != .models, let product = preferredImagery(for: next) {
      selectOption("imagery:\(product.code)")
    } else {
      // The tabs work even before collection/catalogue data is available.
      clearSelectionPresentation()
      mode = next
      selectedOptionID = next == .models ? lastModelOptionID : ""
      imageryCode = ""
      if next == .models {
        if selectedProductCode.isEmpty {
          selectedProductCode =
            products.first(where: { $0.latestRunTime != nil })?.code ?? products.first?.code ?? ""
        }
        reload(productChanged: domains.isEmpty || fields.isEmpty)
      }
    }
  }

  private func clearSelectionPresentation() {
    cancelRequests()
    playing = false
    displayedFrame = nil
    resolved = []
    frames = []
    errorMessage = nil
    featureError = nil
    sampleResult = nil
    sampleCoordinate = nil
  }

  func selectOption(_ id: String) {
    guard id != selectedOptionID, let option = dataOptions.first(where: { $0.id == id }) else {
      return
    }
    clearSelectionPresentation()
    selectedOptionID = id
    switch option.kind {
    case .none:
      mode = .none
      lastModelOptionID = id
      selectedFieldCode = ""
      selectedFrameIndex = 0
      timelineTruncated = false
    case .field, .wind:
      guard let source = source(for: option) else { return }
      mode = .models
      lastModelOptionID = id
      selectedFieldCode = source.field.code
      let changed = selectedProductCode != source.product.code
      selectedProductCode = source.product.code
      reload(
        productChanged: changed || domains.isEmpty
          || !fields.contains(where: { $0.code == selectedFieldCode }))
    case .imagery:
      guard let product = imagery.first(where: { $0.code == option.imageryCode }) else { return }
      mode = product.kind == "radar" ? .radar : .satellite
      imageryCode = product.code
      lastImageryCodes[mode] = product.code
      selectedFrameIndex = max(0, frameCount - 1)
    case .hotspots:
      mode = .hotspots
      lastModelOptionID = id
      refreshHotspots()
    case .stations:
      mode = .stations
      lastModelOptionID = id
      refreshStations()
    }
  }
  func selectSource(_ code: String) {
    guard code != selectedProductCode, let option = selectedOption,
      let source = option.sources.first(where: { $0.product.code == code })
    else { return }
    selectedProductCode = code
    selectedFieldCode = source.field.code
    reload(productChanged: true)
  }
  func selectDomain(_ code: String) {
    selectedDomainCode = code
    reload()
  }
  func moveFrame(by amount: Int) {
    guard frameCount > 0 else { return }
    selectFrame((selectedFrameIndex + amount + frameCount) % frameCount)
  }
  func selectFrame(_ index: Int) {
    guard index >= 0 && index < frameCount else { return }
    isFrameDisplayed = false
    errorMessage = nil
    selectedFrameIndex = index
    sampleResult = nil
    if mode == .models { resolve() }
  }
  func retry() {
    guard !showsNoOverlay else { return }
    errorMessage = nil
    if showStations {
      refreshStations()
      return
    }
    if showHotspots {
      refreshHotspots()
      return
    }
    if frameCount > 0 {
      if mode == .models {
        resolve()
      } else {
        revision += 1
        isFrameDisplayed = false
      }
      return
    }
    didLoad = false
    Task { await load() }
  }
  func cancelRequests() {
    revision += 1
    task?.cancel()
    sampleTask?.cancel()
    windTask?.cancel()
    hotspotTask?.cancel()
    stationTask?.cancel()
    stations = []
    selectedStation = nil
    hotspotPoints = []
    hotspotLoading = false
    windPoints = []
    windLoading = false
    windFailed = false
    isFrameDisplayed = false
    isLoading = false
  }
  func reload(productChanged: Bool = false) {
    guard mode == .models else { return }
    cancelRequests()
    playing = false
    displayedFrame = nil
    resolved = []
    frames = []
    sampleResult = nil
    let generation = revision
    let product = selectedProductCode
    guard !product.isEmpty else { return }
    isLoading = true
    errorMessage = nil
    task = Task {
      defer { if generation == revision { isLoading = false } }
      do {
        if productChanged {
          async let ds = api.domains(product: product)
          async let fs = api.fields(product: product)
          let (newDomains, newFields) = try await (ds, fs)
          try Task.checkCancellation()
          guard generation == revision else { return }
          domains = newDomains
          fields = newFields
          fieldCatalogues[product] = newFields
          selectedDomainCode = newDomains.first?.code ?? ""
          if selectedFieldCode.isEmpty {
            selectedFieldCode = newFields.sorted { $0.mapLabel.1 < $1.mapLabel.1 }.first?.code ?? ""
            selectedOptionID = "field:\(selectedFieldCode)"
          }
          guard newFields.contains(where: { $0.code == selectedFieldCode }) else {
            errorMessage = "This source does not provide the selected data. Choose another source."
            return
          }
        }
        guard let field = selectedFieldCodes.first, !selectedDomainCode.isEmpty else { return }
        let response = try await api.timeline(
          product: product, domain: selectedDomainCode, field: field, past: past)
        try Task.checkCancellation()
        guard generation == revision else { return }
        frames = response.items
        timelineTruncated = response.truncated
        selectedFrameIndex = past ? max(0, frames.count - 1) : 0
        try await resolveLayers(generation: generation)
      } catch {
        if generation == revision && !Task.isCancelled { errorMessage = error.localizedDescription }
      }
    }
  }

  func resolve() {
    guard mode == .models else { return }
    cancelRequests()
    resolved = []  // Displayed metadata is retained separately until replacement drawing finishes.
    isLoading = true
    let generation = revision
    task = Task {
      defer { if generation == revision { isLoading = false } }
      do { try await resolveLayers(generation: generation) } catch {
        if generation == revision && !Task.isCancelled {
          playing = false
          errorMessage = error.localizedDescription
        }
      }
    }
  }

  private func resolveLayers(generation: Int) async throws {
    guard let frame = selectedFrame else { return }
    if showWind {
      refreshWind()
      return
    }
    let product = selectedProductCode
    let domain = selectedDomainCode
    let codes = selectedFieldCodes
    var results: [ResolvedLayer] = []
    var missing: [String] = []
    for code in codes {
      do {
        let layer = try await api.resolveLayer(
          product: product, domain: domain, frame: frame, field: code)
        _ = try api.tileTemplate(layer.tileUrl)
        results.append(layer)
      } catch {
        try Task.checkCancellation()
        missing.append(code)
      }
    }
    try Task.checkCancellation()
    guard generation == revision else { return }
    resolved = results
    errorMessage =
      missing.isEmpty ? nil : "Unavailable for this frame: \(missing.joined(separator: ", "))."
    if !missing.isEmpty { playing = false }
    refreshWind()
  }

  func viewportChanged(_ bounds: [Double]) {
    viewport = bounds
    refreshWind()
    if showStations { refreshStations() }
  }

  func refreshStations() {
    guard showStations else { return }
    stationTask?.cancel()
    let box = viewport
    let field = stationField
    let generation = revision
    stationTask = Task {
      do {
        try await Task.sleep(for: .milliseconds(250))
        var items: [WeatherStation] = []
        var offset = 0
        var more = false
        for _ in 0..<5 {
          let response = try await api.weatherStations(bounds: box, field: field, offset: offset)
          try Task.checkCancellation()
          items += response.items
          guard let next = response.nextOffset else {
            more = false
            break
          }
          offset = next
          more = true
        }
        guard generation == revision, showStations, stationField == field, box == viewport else {
          return
        }
        stations = items
        featureError =
          more
          ? "Zoom in to see additional stations."
          : items.isEmpty
            ? "No collected weather stations in this map area." : nil
      } catch {
        guard !Task.isCancelled, generation == revision, showStations else { return }
        featureError =
          stations.isEmpty
          ? "Weather stations aren't available in this area yet."
          : "Could not refresh stations; previous observations remain shown."
      }
    }
  }
  func refreshWind() {
    windTask?.cancel()
    windFailed = false
    guard showWind, mode == .models, let frame = selectedFrame
    else {
      windPoints = []
      windLoading = false
      return
    }
    isFrameDisplayed = false
    windLoading = true
    let generation = revision
    let box = viewport
    let product = selectedProductCode
    let domain = selectedDomainCode
    windTask = Task {
      do {
        try await Task.sleep(for: .milliseconds(350))
        let response = try await api.wind(
          product: product, domain: domain, frame: frame, bounds: box)
        try Task.checkCancellation()
        guard generation == revision && showWind else { return }
        windPoints = response.features.enumerated().compactMap { index, feature in
          let xy = feature.geometry.coordinates
          guard xy.count == 2 else { return nil }
          return DisplayPoint(
            id: "wind-\(index)", longitude: xy[0], latitude: xy[1],
            title: "\(metric(feature.properties.speed)) \(response.unit)",
            subtitle: "10 m wind · \(frame.validTime.formatted())",
            bearing: feature.properties.bearing,
            windSpeedMetresPerSecond: response.unit == "m/s" ? feature.properties.speed : nil)
        }
        windLoading = false
        featureError = nil
      } catch {
        if generation == revision && !Task.isCancelled {
          windPoints = []
          windLoading = false
          windFailed = true
          playing = false
          featureError = "Wind vectors: \(error.localizedDescription)"
          errorMessage =
            "Wind vectors could not be loaded for this frame. Playback is paused. Please retry."
        }
      }
    }
  }
  func refreshHotspots() {
    guard showHotspots else { return }
    hotspotTask?.cancel()
    revision += 1
    hotspotPoints = []
    hotspotLoading = true
    featureError = nil
    let generation = revision
    hotspotTask = Task {
      defer { if generation == revision { hotspotLoading = false } }
      do {
        if hotspotDates.isEmpty || hotspotDate.isEmpty {
          let dates = try await api.hotspotDates().items.map(\.dataDate).sorted(by: >)
          try Task.checkCancellation()
          guard generation == revision, showHotspots else { return }
          hotspotDates = dates
        }
        if hotspotDate.isEmpty { hotspotDate = hotspotDates.first ?? "" }
        let date = hotspotDate
        let response = try await api.hotspots(date: date)
        try Task.checkCancellation()
        guard showHotspots && date == hotspotDate else { return }
        hotspotPoints = response.features.enumerated().compactMap { index, feature in
          let xy = feature.geometry.coordinates
          guard xy.count == 2 else { return nil }
          return DisplayPoint(
            id: "fire-\(index)", longitude: xy[0], latitude: xy[1],
            title: feature.properties.sensor ?? "Satellite hotspot",
            subtitle: feature.properties.observedAt ?? "CWFIS observation", bearing: nil)
        }
        featureError = nil
      } catch {
        if generation == revision && !Task.isCancelled {
          featureError = "Hotspots: \(error.localizedDescription)"
        }
      }
    }
  }

  func selectHotspotDate(_ date: String) {
    guard showHotspots else { return }
    cancelRequests()
    hotspotDate = date
    refreshHotspots()
  }

  func sample(at coordinate: CLLocationCoordinate2D) {
    guard mode == .models, isFrameDisplayed, !resolved.isEmpty, let frame = selectedFrame else {
      return
    }
    sampleTask?.cancel()
    let generation = revision
    let product = selectedProductCode
    let domain = selectedDomainCode
    let codes = resolved.map(\.field)
    sampleCoordinate = coordinate
    sampleTask = Task {
      do {
        let result = try await api.sample(
          product: product, domain: domain, frame: frame, fields: codes,
          longitude: coordinate.longitude, latitude: coordinate.latitude)
        try Task.checkCancellation()
        if generation == revision { sampleResult = result }
      } catch {
        if generation == revision && !Task.isCancelled { errorMessage = error.localizedDescription }
      }
    }
  }
}
