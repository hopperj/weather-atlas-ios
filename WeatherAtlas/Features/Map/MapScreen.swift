import SwiftUI

struct MapScreen: View {
  @StateObject private var model: MapScreenModel
  @EnvironmentObject private var store: AppStore
  @Environment(\.scenePhase) private var scenePhase
  @State private var showingLayers = false
  @State private var dataSearch = ""
  @State private var locationRequest = 0
  @State private var fitRequest = 0

  init(api: WeatherAPI) { _model = StateObject(wrappedValue: MapScreenModel(api: api)) }

  var body: some View {
    NavigationStack {
      mapContent
        .navigationTitle("Weather Atlas").navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { mapSelectionControls }
        .toolbar { mapToolbar }
        .task {
          await model.load()
          await model.loadSelectionCatalogues()
        }
        .task {
          while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            if scenePhase == .active && model.isImagery { await model.loadImagery() }
            if scenePhase == .active && model.showStations { model.refreshStations() }
          }
        }
        .task(id: model.playbackTicket) { await playFrame(model.playbackTicket) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { model.playing = false } }
        .onDisappear { model.playing = false }
        .sheet(isPresented: $showingLayers) { layerPicker }
        .sheet(item: $model.selectedStation) { StationDetailView(station: $0, api: model.api) }
        .sheet(item: $model.sampleResult) { sample in
          SampleSheet(sample: sample, fields: model.fields, api: model.api).presentationDetents([
            .medium
          ])
        }
    }
  }

  private var mapContent: some View {
    VStack(spacing: 0) {
      MapSurface(
        frame: model.rasterFrame, requestID: model.requestedFrameID,
        contextID: model.presentationContextID, api: model.api, place: store.mapPlace,
        placeRequest: store.mapRevision,
        locationRequest: locationRequest, bounds: model.bounds, fitRequest: fitRequest,
        sampleCoordinate: model.sampleCoordinate,
        points: model.showStations
          ? model.stationPoints : model.showHotspots ? model.hotspotPoints : [],
        onStationTap: { id in model.selectedStation = model.stations.first { $0.id == id } },
        onViewportChange: { model.viewportChanged($0) },
        onLocationError: { model.featureError = $0 },
        onFrameState: { model.frameStateChanged(id: $0, state: $1) },
        onTap: { model.sample(at: $0) }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      if !model.showsNoOverlay || model.errorMessage != nil || model.featureError != nil {
        VStack(spacing: 10) {
          if let error = model.errorMessage {
            HStack {
              Text(error).font(.caption).lineLimit(3)
              Spacer()
              Button("Retry") { model.retry() }.font(.caption.bold())
            }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
          }
          if let error = model.featureError { StatusMessage(text: error) }
          if model.isImagery && model.frameCount == 0 {
            StatusMessage(
              text: model.imageryUnavailable
                ?? "No collected \(model.mode.rawValue.lowercased()) frames are available yet.")
          }
          if let product = model.selectedImagery, model.isImagery, product.stale {
            StatusMessage(
              text: "Imagery update overdue. The observation time is shown below.",
              symbol: "clock.badge.exclamationmark")
          }
          if !model.showsNoOverlay {
            layerCard
            if model.showStations {
              Picker("Observed measurement", selection: $model.stationField) {
                ForEach(StationField.allCases) { Text($0.title).tag($0) }
              }.accessibilityIdentifier("stationFieldPicker")
              Text("\(model.stations.count) stations · Tap a marker for readings and history")
                .font(.caption).foregroundStyle(.secondary)
            } else if model.showHotspots {
              hotspotControls
            } else {
              timeline
            }
          }
        }.padding(.horizontal).padding(.vertical, 8).background(Color(.systemGroupedBackground))
      }
    }
  }

  private var mapSelectionControls: some View {
    VStack(spacing: 0) {
      Picker(
        "Map view",
        selection: Binding(get: { model.navigationMode }, set: { model.selectMode($0) })
      ) {
        Text("Model").tag(MapMode.models)
        Text("Radar").tag(MapMode.radar)
        Text("Satellite").tag(MapMode.satellite)
      }
      .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
      .accessibilityIdentifier("mapModePicker")
      if !model.isImagery {
        HStack(spacing: 12) {
          dataPickerButton
          if model.mode == .models, let option = model.selectedOption, !option.sources.isEmpty {
            Menu {
              Picker(
                "Model",
                selection: Binding(
                  get: { model.selectedProductCode }, set: { model.selectSource($0) })
              ) {
                ForEach(option.sources) { Text($0.description).tag($0.product.code) }
              }
            } label: {
              HStack(spacing: 4) {
                Text(model.selectedProductCode.uppercased())
                Image(systemName: "chevron.down").font(.caption.bold())
              }.font(.subheadline).padding(.vertical, 10)
            }
            .accessibilityLabel("Model: \(model.selectedProductCode.uppercased())")
            .accessibilityIdentifier("mapModelPicker")
          }
        }.padding(.horizontal)
      }
    }.background(.regularMaterial)
  }

  private var dataPickerButton: some View {
    Button {
      showingLayers = true
    } label: {
      HStack {
        Text(model.title).font(.subheadline.bold())
        Spacer(minLength: 4)
        Image(systemName: "chevron.down").font(.caption.bold())
      }.padding(.vertical, 10).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Choose map data: \(model.title)")
    .accessibilityIdentifier("mapDataPicker")
  }

  @ToolbarContentBuilder private var mapToolbar: some ToolbarContent {
    ToolbarItemGroup(placement: .topBarTrailing) {
      Button("My location", systemImage: "location") { locationRequest += 1 }
      if !model.showsNoOverlay {
        Button("Fit layer", systemImage: "arrow.up.left.and.arrow.down.right") { fitRequest += 1 }
      }
      Button("Map data", systemImage: "line.3.horizontal.decrease") { showingLayers = true }
    }
  }
  private func playFrame(_ ticket: MapPlaybackTicket?) async {
    guard let ticket else { return }
    do { try await Task.sleep(for: .seconds(ticket.speed.secondsPerFrame)) } catch { return }
    guard !Task.isCancelled else { return }
    model.advancePlayback(ticket: ticket)
  }

  private var layerCard: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(model.displayedFrame?.title ?? model.title).font(.subheadline.bold()).lineLimit(2)
        Spacer()
        if model.frameCount > 0 && model.displayedFrame == nil && !model.isFrameDisplayed
          && model.errorMessage == nil
        {
          ProgressView().controlSize(.small)
        }
      }
      if model.mode == .models {
        ForEach(model.displayedFrame?.legends ?? [], id: \.field) { layer in
          VStack(spacing: 3) {
            LinearGradient(
              stops: layer.legend.palette.map {
                Gradient.Stop(
                  color: Color(hex: $0.color),
                  location: layer.legend.position(for: $0.value))
              },
              startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 6).clipShape(Capsule())
            HStack {
              Text("\(metric(layer.legend.minimum)) \(layer.unit)")
              Spacer()
              Text("\(metric(layer.legend.maximum)) \(layer.unit)")
            }.font(.caption2)
            if layer.variable == "air_temperature" {
              Text("Automatic colour range · 5°C steps")
                .font(.caption2).foregroundStyle(.secondary)
            }
          }
          .accessibilityElement(children: .combine)
        }
        if model.frames.isEmpty && !model.isLoading {
          Text("No frames available").font(.caption).foregroundStyle(.secondary)
        }
        Text(model.sourceLabel).font(.caption2).foregroundStyle(
          .secondary)
        if model.showWind {
          Text("Larger arrows indicate stronger wind at 10 m. Tap an arrow for its speed.")
            .font(.caption2).foregroundStyle(.secondary)
        }
      } else if model.isImagery {
        Text(model.selectedImagery?.attribution ?? "ECCC weather imagery").font(.caption2)
          .foregroundStyle(.secondary)
      }
      if model.showHotspots {
        Text(
          "NRCan CWFIS · Satellite heat detections, not fire boundaries."
        )
        .font(.caption2).foregroundStyle(.secondary)
        .accessibilityIdentifier("hotspotAttribution")
      }
    }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
  }

  private var hotspotControls: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker(
        "Observation date",
        selection: Binding(
          get: { model.hotspotDate }, set: { model.selectHotspotDate($0) })
      ) {
        if model.hotspotDate.isEmpty { Text("Latest available").tag("") }
        ForEach(model.hotspotDates, id: \.self) { Text($0).tag($0) }
      }
      .accessibilityIdentifier("hotspotDatePicker")
      if model.hotspotLoading {
        ProgressView("Loading fire hotspots…")
      } else if model.featureError == nil {
        Text("\(model.hotspotPoints.count) detections · \(model.hotspotDate)")
          .font(.caption).foregroundStyle(.secondary)
      }
      Button("Latest available") { model.selectHotspotDate("") }
        .font(.caption)
    }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
  }

  private var timeline: some View {
    VStack(spacing: 4) {
      HStack {
        Button(
          model.playing ? "Pause" : "Play", systemImage: model.playing ? "pause.fill" : "play.fill"
        ) {
          model.playing.toggle()
        }.labelStyle(.iconOnly).disabled(model.frameCount < 2)
          .accessibilityIdentifier("mapPlaybackToggle")
        Button("Previous frame", systemImage: "backward.end.fill") { model.moveFrame(by: -1) }
          .labelStyle(.iconOnly).disabled(model.frameCount < 2)
        VStack(spacing: 2) {
          Text(
            model.displayedFrame?.time.formatted(date: .abbreviated, time: .shortened)
              ?? "Loading map frame…"
          )
          .font(.caption.bold()).monospacedDigit().accessibilityIdentifier("mapDisplayedTime")
          Text(model.displayedFrame?.caption ?? "Preparing complete frame")
            .font(.caption2).foregroundStyle(.secondary)
            .accessibilityIdentifier("mapDisplayedCaption")
        }.frame(maxWidth: .infinity)
        Button("Next frame", systemImage: "forward.end.fill") { model.moveFrame(by: 1) }
          .labelStyle(.iconOnly).disabled(model.frameCount < 2)
      }
      if model.frameCount > 1 {
        Slider(
          value: Binding(
            get: { Double(model.selectedFrameIndex) }, set: { model.selectFrame(Int($0)) }),
          in: 0...Double(model.frameCount - 1), step: 1
        )
        .accessibilityLabel("Weather frame").accessibilityValue(model.frameTime?.formatted() ?? "")
      }
      Text(
        model.isFrameDisplayed
          ? "\(model.playbackSpeed.secondsPerFrame.formatted()) seconds per complete frame"
          : model.errorMessage != nil
            ? "Playback paused · frame unavailable"
            : model.displayedFrame == nil
              ? "Loading complete frame…"
              : "Buffering · previous frame held"
      )
      .font(.caption2).foregroundStyle(.secondary)
      .accessibilityIdentifier("mapPlaybackStatus")
      Picker("Playback speed", selection: $model.playbackSpeed) {
        ForEach(MapPlaybackSpeed.allCases) { Text($0.label).tag($0) }
      }.pickerStyle(.segmented).accessibilityIdentifier("mapPlaybackSpeed")
    }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
  }

  private var layerPicker: some View {
    NavigationStack {
      List {
        Section { dataOptionRow(.noOverlay) }
        if dataSearch.isEmpty && !model.showsNoOverlay {
          Section {
            DisclosureGroup("Source & display options") { sourceAndDisplayOptions }
          }
        }
        if model.catalogueLoading && model.dataOptions.isEmpty {
          ProgressView("Loading available data…")
        }
        if let error = model.catalogueError {
          Text(error).font(.caption).foregroundStyle(.secondary)
          Button("Retry sources") { Task { await model.loadSelectionCatalogues() } }
        }
        Section("Weather & observations · choose one") {
          ForEach(filteredOptions.filter { $0.rank < 100 }) { dataOptionRow($0) }
        }
        Section("More data") {
          ForEach(filteredOptions.filter { $0.rank >= 100 }) { dataOptionRow($0) }
        }
        if filteredOptions.isEmpty && !model.catalogueLoading {
          Text("No matching map data.").foregroundStyle(.secondary)
        }
      }
      .navigationTitle("Map data")
      .searchable(text: $dataSearch, prompt: "Temperature, rain, wind…")
      .task(id: model.products.map(\.code)) { await model.loadSelectionCatalogues() }
      .toolbar { Button("Done") { showingLayers = false } }
      .onDisappear { dataSearch = "" }
    }
  }

  private var filteredOptions: [MapDataOption] {
    model.dataOptions.filter {
      $0.kind != .none
        && (dataSearch.isEmpty
          || "\($0.title) \(model.sourceLabel(for: $0))".localizedCaseInsensitiveContains(
            dataSearch))
    }
  }

  private func dataOptionRow(_ option: MapDataOption) -> some View {
    Button {
      model.selectOption(option.id)
      showingLayers = false
    } label: {
      HStack {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(option.title).fixedSize()
            Text(model.sourceLabel(for: option)).font(.caption).foregroundStyle(Color.secondary)
              .fixedSize()
          }
          VStack(alignment: .leading, spacing: 3) {
            Text(option.title)
            Text(model.sourceLabel(for: option)).font(.caption).foregroundStyle(Color.secondary)
          }
        }
        Spacer(minLength: 6)
        if model.selectedOptionID == option.id {
          Image(systemName: "checkmark").foregroundStyle(.tint)
        }
      }.foregroundStyle(Color.primary).padding(.vertical, 3).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("map-option-\(option.id)")
    .accessibilityLabel(
      option.kind == .none ? option.title : "\(option.title), \(model.sourceLabel(for: option))"
    )
    .accessibilityAddTraits(model.selectedOptionID == option.id ? .isSelected : [])
  }

  @ViewBuilder private var sourceAndDisplayOptions: some View {
    if model.mode == .models {
      if let option = model.selectedOption {
        Picker(
          "Data source",
          selection: Binding(
            get: { model.selectedProductCode }, set: { model.selectSource($0) })
        ) {
          ForEach(option.sources) { Text($0.description).tag($0.product.code) }
        }.pickerStyle(.menu).accessibilityIdentifier("mapDataSource")
      }
      if model.domains.count > 1 {
        Picker(
          "Coverage",
          selection: Binding(
            get: { model.selectedDomainCode }, set: { model.selectDomain($0) })
        ) {
          ForEach(model.domains) { Text($0.name).tag($0.code) }
        }
      }
      if let field = model.selectedField {
        Text("\(field.levelName) · \(model.showWind ? "Wind arrows" : field.unit)")
          .font(.caption).foregroundStyle(.secondary)
        if field.variableCode == "precipitation" {
          Text("Amounts include rain plus melted snow, not snow depth.").font(.caption)
        }
      }
      Toggle("Past seven days", isOn: $model.past).onChange(of: model.past) { model.reload() }
      if model.timelineTruncated {
        Text("This window is limited to the first 1,000 available frames.").font(.caption)
      }
    }
    if !model.showHotspots && !model.showWind {
      Slider(value: $model.opacity, in: 0...1) { Text("Opacity") }
      Text("Opacity \(Int(model.opacity * 100))%").font(.caption)
    }
    if model.isImagery {
      if let url = model.imageryFrame?.legendUrl { ServerLegend(api: model.api, path: url) }
    }
    if model.showHotspots { Text("Choose an observation date below the map.").font(.caption) }
  }
}

private struct ServerLegend: View {
  let api: WeatherAPI
  let path: String
  @State private var image: UIImage?
  @State private var unavailable = false
  var body: some View {
    Group {
      if let image {
        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 280).accessibilityLabel(
          "Provider weather legend")
      } else if unavailable {
        Text("The legend is unavailable.").font(.caption)
      } else {
        ProgressView("Loading legend…")
      }
    }
    .task(id: path) {
      guard let url = URL(string: path, relativeTo: api.baseURL)?.absoluteURL,
        WeatherAPI.sameOrigin(url, api.baseURL)
      else {
        unavailable = true
        return
      }
      do {
        let (data, response) = try await api.session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
          let decoded = UIImage(data: data)
        else {
          unavailable = true
          return
        }
        image = decoded
      } catch { unavailable = true }
    }
  }
}

private struct SampleSheet: View {
  let sample: SampleResponse
  let fields: [WeatherField]
  let api: WeatherAPI
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var nearby: NearbyForecast?
  @State private var nearbyError: String?
  var body: some View {
    NavigationStack {
      List {
        Section {
          Text(
            "\(sample.latitude.formatted(.number.precision(.fractionLength(3)))), \(sample.longitude.formatted(.number.precision(.fractionLength(3))))"
          )
          Text(sample.validTime.formatted(date: .abbreviated, time: .shortened)).font(.caption)
        }
        ForEach(sample.values) { value in
          LabeledContent(
            fields.first { $0.code == value.field }?.name ?? value.variable,
            value: value.nodata ? "No data" : metric(value.value, " \(value.unit)"))
        }
        Section { Text("Model run: \(sample.runTime.formatted())").font(.caption) }
        Section("Nearby forecast") {
          if let nearby {
            Button {
              store.selectForecastRegion(nearby.region.id)
              store.selectedTab = 1
              dismiss()
            } label: {
              VStack(alignment: .leading) {
                Text(nearby.region.displayName)
                Text("Region reference point \(metric(nearby.distanceKm)) km away").font(.caption)
              }
            }.accessibilityIdentifier("nearbyForecast")
          } else {
            Text(nearbyError ?? "Finding a nearby forecast…").font(.caption)
          }
        }
      }.navigationTitle("At this point").navigationBarTitleDisplayMode(.inline)
        .task {
          do {
            nearby = try await api.nearestForecast(
              longitude: sample.longitude, latitude: sample.latitude)
          } catch { nearbyError = error.localizedDescription }
        }
    }
  }
}

extension Color {
  init(hex: String) {
    let text = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    let value = UInt64(String(text.prefix(6)), radix: 16) ?? 0
    self.init(
      red: Double((value >> 16) & 255) / 255,
      green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
  }
}
