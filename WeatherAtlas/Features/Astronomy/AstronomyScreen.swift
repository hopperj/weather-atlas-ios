import CoreLocation
import SwiftUI

struct AstronomyScreen: View {
  let api: WeatherAPI
  @StateObject private var settings: AstronomySettings
  @StateObject private var location = ForecastLocation()
  @Environment(\.scenePhase) private var scenePhase
  @State private var visible = false
  @State private var forecast: AstronomyForecast?
  @State private var error: String?
  @State private var loading = false
  @State private var picking = false
  @State private var product = "gdps"
  @State private var mode = "deep_sky"
  @State private var cloud = 30
  @State private var wind = 25
  @State private var nightID = ""
  @State private var nightOnly = true
  @State private var red = false
  @State private var refresh = 0
  @State private var detail: AstronomyForecast.Frame?
  @State private var lastGPSUpdate = Date.distantPast
  @State private var displayedScope = ""
  init(api: WeatherAPI, seed: ObservingSite, restoreLast: Bool = true) {
    self.api = api
    let key = "astronomy:v1:\(api.baseURL.absoluteString):options"
    let preferences = UserDefaults.standard.dictionary(forKey: key) ?? [:]
    let product = preferences["product"] as? String ?? "gdps"
    let mode = preferences["mode"] as? String ?? "deep_sky"
    _product = State(initialValue: ["gdps", "rdps", "hrdps"].contains(product) ? product : "gdps")
    _mode = State(initialValue: ["deep_sky", "lunar_planetary"].contains(mode) ? mode : "deep_sky")
    _cloud = State(initialValue: min(100, max(0, preferences["cloud"] as? Int ?? 30)))
    _wind = State(initialValue: min(100, max(0, preferences["wind"] as? Int ?? 25)))
    _settings = StateObject(
      wrappedValue: AstronomySettings(
        seed: seed, server: api.baseURL.absoluteString, restoreLast: restoreLast))
  }
  private var request: String {
    "\(settings.site.id)|\(product)|\(mode)|\(cloud)|\(wind)|\(refresh)|\(scenePhase)|\(visible)"
  }
  private var night: AstronomyForecast.Night? {
    forecast?.nights.first(where: { $0.id == nightID }) ?? forecast?.nights.first
  }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        siteCard
        Text("Total-cloud preview · Layered cloud, seeing and transparency are not available yet.")
          .font(.footnote).foregroundStyle(.secondary)
        preferences
        if loading && forecast == nil { ProgressView("Preparing observing forecast…") }
        if let error { Text(error).font(.callout).foregroundStyle(.red) }
        if let forecast {
          ScrollView(.horizontal) {
            HStack {
              ForEach(forecast.nights) { next in
                Button {
                  nightID = next.id
                  detail = nil
                } label: {
                  VStack(alignment: .leading, spacing: 5) {
                    Text(date(next.start, "EEE, MMM d")).bold()
                    Text(
                      next.bestWindow.map { "\($0.minutes) min window" }
                        ?? (next.state == "insufficient_data" ? "Insufficient data" : "No window")
                    )
                    .font(.caption)
                  }.padding(10)
                    .background(
                      night?.id == next.id
                        ? Color.accentColor.opacity(0.18)
                        : Color(.secondarySystemGroupedBackground),
                      in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
              }
            }
          }
          if let night {
            summary(night)
            events(night)
            timeline(forecast, night: night)
          }
          if let detail {
            GroupBox("\(date(detail.time, "EEE, MMM d HH:mm"))") {
              VStack(alignment: .leading, spacing: 8) {
                Text(
                  "Sun \(detail.sunAltitudeDegrees, specifier: "%.1f")° · Moon \(detail.moonAltitudeDegrees, specifier: "%.1f")°"
                )
                if let start = detail.rainStart {
                  Text(
                    "Precipitation interval: \(date(start, "EEE HH:mm")) to \(date(detail.time, "EEE HH:mm"))."
                  )
                } else {
                  Text("Precipitation amount unavailable.")
                }
                Text(
                  "Dew risk is a surface-weather heuristic (spread ≤2°C), not your optics' temperature."
                )
                Button("Close details") { self.detail = nil }
              }.font(.footnote).frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          DisclosureGroup("Sources & limitations") {
            VStack(alignment: .leading, spacing: 10) {
              Text(
                "\(forecast.source) · Run \(forecast.runTime.map { date($0, "MMM d HH:mm") } ?? "unavailable")"
              )
              Text(forecast.stale ? "Model run stale or missing" : "Recent model run")
              Text("Updated \(date(forecast.generatedAt, "MMM d HH:mm")) · \(forecast.timeZone)")
              Text(forecast.method)
              if let sample = forecast.sample {
                Text(
                  "Sample cell: \(sample.latitude, specifier: "%.5f"), \(sample.longitude, specifier: "%.5f"). Grid: \(sample.pixelSize.map { String($0) }.joined(separator: " × ")) (\(sample.crs)). Your pin stays at the requested point."
                )
              }
              ForEach(forecast.limitations, id: \.self) { Text($0) }
              Text(
                "Rules \(forecast.ruleVersion). Minimum 60 minutes; no model precipitation. Not a probability or guarantee."
              )
            }.font(.caption).padding(.top, 8)
          }
        }
        Toggle("Dim red field view", isOn: $red)
        Text(
          "Weather and Sun/Moon calculations run on the Weather Atlas server. Observing sites stay on this device, independently of Forecast."
        )
        .font(.caption).foregroundStyle(.secondary)
      }.padding()
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Astronomy / Clear sky").navigationBarTitleDisplayMode(.inline)
    .tint(red ? .red : .accentColor)
    .colorMultiply(red ? Color(red: 0.65, green: 0.18, blue: 0.13) : .white)
    .preferredColorScheme(red ? .dark : nil)
    .toolbar {
      Button("Refresh", systemImage: "arrow.clockwise") { refresh += 1 }.disabled(loading)
    }
    .sheet(isPresented: $picking) {
      AstronomySitePicker(site: settings.site) {
        settings.choose($0)
        nightID = ""
      }
    }
    .task(id: request) {
      guard visible && scenePhase == .active else {
        loading = false
        return
      }
      UserDefaults.standard.set(
        ["product": product, "mode": mode, "cloud": cloud, "wind": wind],
        forKey: "astronomy:v1:\(api.baseURL.absoluteString):options")
      let site = settings.site
      let chosenProduct = product
      let chosenMode = mode
      let scope = "\(site.id)|\(product)|\(mode)|\(cloud)|\(wind)"
      if displayedScope != scope { forecast = nil }
      displayedScope = scope
      loading = true
      error = nil
      detail = nil
      // Debounce changes to observing limits and reject responses after a new selection.
      do {
        try await Task.sleep(for: .milliseconds(300))
        let value = try await api.astronomy(
          site: site, product: chosenProduct, mode: chosenMode, cloud: cloud, wind: wind)
        try Task.checkCancellation()
        forecast = value
      } catch {
        if !Task.isCancelled {
          self.error = "Could not update observing conditions. \(error.localizedDescription)"
        }
      }
      if !Task.isCancelled { loading = false }
    }
    .task(id: "\(scenePhase)|\(visible)") {
      guard visible && scenePhase == .active else { return }
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(300))
          refresh += 1
        } catch { return }
      }
    }
    .task(id: "\(settings.followsGPS)|\(scenePhase)|\(visible)") {
      if visible && settings.followsGPS && scenePhase == .active {
        location.start()
      } else {
        location.stop()
      }
    }
    .onAppear { visible = true }
    .onDisappear {
      visible = false
      location.stop()
    }
    .onChange(of: location.fix) { _, fix in
      guard visible, settings.followsGPS, scenePhase == .active, let fix,
        Date().timeIntervalSince(fix.measuredAt) < 300
      else { return }
      let distance = CLLocation(latitude: fix.latitude, longitude: fix.longitude).distance(
        from:
          CLLocation(latitude: settings.site.latitude, longitude: settings.site.longitude))
      guard Date().timeIntervalSince(lastGPSUpdate) >= 60,
        lastGPSUpdate == .distantPast || distance >= 1000
      else { return }
      lastGPSUpdate = Date()
      settings.choose(
        .init(name: "Current location", latitude: fix.latitude, longitude: fix.longitude),
        manual: false)
      nightID = ""
    }
    .accessibilityIdentifier("astronomyScreen")
  }
  private var siteCard: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        Label(
          settings.site.name.isEmpty ? "Observing site" : settings.site.name,
          systemImage: "moon.stars"
        ).font(.title3.bold())
        Text(
          "\(settings.site.latitude, specifier: "%.5f"), \(settings.site.longitude, specifier: "%.5f") · \(settings.followsGPS ? "Approximate foreground GPS" : "Fixed site")"
        ).font(.caption)
        if let message = location.message {
          Text(message).font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Button("Choose on map") { picking = true }.accessibilityIdentifier("astronomyChooseSite")
          Spacer()
          Button(settings.followsGPS ? "Stop GPS" : "Use GPS") {
            settings.followsGPS.toggle()
            lastGPSUpdate = .distantPast
          }
        }.buttonStyle(.bordered)
        Button("Save observing site", systemImage: "bookmark") { settings.save() }
        ForEach(settings.saved) { saved in
          HStack {
            Button(saved.name.isEmpty ? saved.id : saved.name) {
              settings.choose(saved)
              nightID = ""
            }
            Spacer()
            Button("Remove", systemImage: "xmark") { settings.remove(saved) }.labelStyle(.iconOnly)
              .accessibilityLabel("Remove \(saved.name)")
          }.font(.subheadline)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private var preferences: some View {
    VStack(spacing: 12) {
      Picker("Model", selection: $product) {
        Text("GDPS").tag("gdps")
        Text("RDPS").tag("rdps")
        Text("HRDPS").tag("hrdps")
      }.pickerStyle(.segmented)
      Picker("Observing mode", selection: $mode) {
        Text("Deep sky · moonless").tag("deep_sky")
        Text("Lunar / planetary").tag("lunar_planetary")
      }
      Stepper("Cloud limit: \(cloud)%", value: $cloud, in: 0...100, step: 5)
      Stepper("Wind limit: \(wind) km/h", value: $wind, in: 0...100, step: 5)
    }
  }
  private func summary(_ night: AstronomyForecast.Night) -> some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 10) {
        Text(mode == "deep_sky" ? "MOONLESS DARKNESS" : "MOONLIGHT ALLOWED").font(.caption.bold())
          .foregroundStyle(.secondary)
        if let window = night.bestWindow {
          Text("\(date(window.start, "HH:mm")) – \(date(window.end, "HH:mm"))").font(
            .largeTitle.bold())
          Text("\(window.minutes) minutes")
        } else {
          Text(night.state == "insufficient_data" ? "Insufficient data" : "No qualifying window")
            .font(.title2.bold())
        }
        Text(night.summary)
        Text(
          "\(date(night.start, "EEE, MMM d")) → \(date(night.end, "EEE, MMM d")) · \(forecast?.timeZone ?? "")"
        ).font(.caption)
        Text("This preview does not assess seeing or transparency.").font(.caption).foregroundStyle(
          .secondary)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private func events(_ night: AstronomyForecast.Night) -> some View {
    GroupBox("Sun & Moon") {
      VStack(alignment: .leading, spacing: 10) {
        eventRow("Sunset / sunrise", night.events["sunset"] ?? nil, night.events["sunrise"] ?? nil)
        eventRow(
          "Civil dusk / dawn", night.events["civilDusk"] ?? nil, night.events["civilDawn"] ?? nil)
        eventRow(
          "Nautical dusk / dawn", night.events["nauticalDusk"] ?? nil,
          night.events["nauticalDawn"] ?? nil)
        eventRow(
          "Astronomical dusk / dawn", night.events["astronomicalDusk"] ?? nil,
          night.events["astronomicalDawn"] ?? nil)
        eventRow(
          "Moonrise / moonset", night.events["moonrise"] ?? nil, night.events["moonset"] ?? nil)
        Text(
          "\(night.moonPhaseName.map { $0 + " · " } ?? "")Moon illuminated: \(night.moonIlluminatedPercent, specifier: "%.0f")% at night midpoint"
        ).font(.subheadline)
        Text(
          night.darkness.isEmpty
            ? "No astronomical darkness this night."
            : "Astronomical darkness: "
              + night.darkness.map { "\(date($0.start, "HH:mm"))–\(date($0.end, "HH:mm"))" }.joined(
                separator: ", ")
        ).font(.caption)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private func eventRow(_ title: String, _ a: Date?, _ b: Date?) -> some View {
    VStack(alignment: .leading) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(
        "\(a.map { date($0, "HH:mm") } ?? "No event") / \(b.map { date($0, "HH:mm") } ?? "No event")"
      )
    }
  }
  private func timeline(_ forecast: AstronomyForecast, night: AstronomyForecast.Night) -> some View
  {
    let frames = forecast.frames.filter {
      $0.time >= night.start && $0.time < night.end && (!nightOnly || $0.sunAltitudeDegrees < 0)
    }
    return VStack(alignment: .leading, spacing: 10) {
      Text("The night, hour by hour").font(.title2.bold())
      Toggle("Night only", isOn: $nightOnly)
      Text("Native model times; gaps are not filled. Tap a column for details.").font(.caption)
        .foregroundStyle(.secondary)
      if frames.isEmpty {
        Text(
          "No collected weather frames cover this night. Sun and Moon events remain available above."
        ).font(.callout)
      } else {
        HStack(spacing: 0) {
          VStack(alignment: .leading, spacing: 0) {
            Text("Local time").frame(height: 50)
            ForEach(
              [
                "Cloud %", "Sun °", "Moon °", "Moon lit %", "Temp °C", "Humidity %", "Dew point °C",
                "Wind km/h", "Gust km/h", "Precip mm¹", "Dew risk",
              ], id: \.self
            ) { Text($0).frame(height: 34) }
          }.font(.caption).frame(width: 105, alignment: .leading)
          ScrollView(.horizontal) {
            HStack(spacing: 4) {
              ForEach(frames) { frame in
                Button {
                  detail = frame
                } label: {
                  VStack(spacing: 0) {
                    Text(date(frame.time, "EEE d\nHH:mm")).frame(height: 50)
                    cell(frame.cloudPercent).background(
                      (frame.cloudPercent ?? 101) <= Double(cloud)
                        ? Color.green.opacity(0.18) : Color.orange.opacity(0.15))
                    cell(frame.sunAltitudeDegrees)
                    cell(frame.moonAltitudeDegrees)
                    cell(frame.moonIlluminatedPercent)
                    cell(frame.temperatureC)
                    cell(frame.humidityPercent)
                    cell(frame.dewPointC)
                    cell(frame.windKmh)
                    cell(frame.gustKmh)
                    cell(frame.rainMm, digits: 1)
                    Text(frame.dewRisk.map { $0 ? "Watch" : "Low" } ?? "—").frame(height: 34)
                  }.font(.caption).frame(width: 72).background(
                    Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).accessibilityLabel(
                  "Conditions at \(date(frame.time, "EEE MMM d HH:mm"))")
              }
            }
          }
        }
      }
      Text(
        "¹ Native precipitation total ending at this time (1 h or 3 h), not an hourly rate. Tap for its start. — means unavailable, not zero."
      ).font(.caption2).foregroundStyle(.secondary)
    }
  }
  private func cell(_ value: Double?, digits: Int = 0) -> some View {
    Text(value.map { String(format: "%.*f", digits, $0) } ?? "—").frame(maxWidth: .infinity).frame(
      height: 34)
  }
  private func date(_ value: Date, _ pattern: String) -> String {
    golfDate(value, zone: forecast?.zone ?? .gmt, pattern: pattern)
  }
}

struct AstronomySitePicker: View {
  @Environment(\.dismiss) private var dismiss
  @State private var latitude: String
  @State private var longitude: String
  @State private var name: String
  @State private var focus: CLLocationCoordinate2D
  @State private var revision = 0
  let onChoose: (ObservingSite) -> Void
  init(site: ObservingSite, onChoose: @escaping (ObservingSite) -> Void) {
    _latitude = State(initialValue: String(site.latitude))
    _longitude = State(initialValue: String(site.longitude))
    _name = State(initialValue: site.name)
    _focus = State(initialValue: site.coordinate)
    self.onChoose = onChoose
  }
  private var candidate: ObservingSite? {
    guard let lat = Double(latitude), let lon = Double(longitude) else { return nil }
    let site = ObservingSite(name: String(name.prefix(120)), latitude: lat, longitude: lon)
    return site.isValid ? site : nil
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ForecastLocationMapSurface(
          regions: [], selectedID: nil, pin: candidate?.coordinate, focus: focus,
          focusRevision: revision,
          onDropPin: { point in
            latitude = String(point.latitude)
            longitude = String(point.longitude)
            name = "Observing site"
          }, onSelectCity: { _ in }
        )
        .frame(maxHeight: .infinity)
        Form {
          HStack {
            Text("Name")
            TextField("Site name", text: $name).multilineTextAlignment(.trailing)
          }
          HStack {
            Text("Latitude")
            TextField("Latitude (−90 to 90)", text: $latitude).keyboardType(.numbersAndPunctuation)
              .multilineTextAlignment(.trailing)
          }
          HStack {
            Text("Longitude")
            TextField("Longitude (−180 to 180)", text: $longitude).keyboardType(
              .numbersAndPunctuation
            ).multilineTextAlignment(.trailing)
          }
          Button("Center on coordinates") {
            if let candidate {
              focus = candidate.coordinate
              revision += 1
            }
          }.disabled(candidate == nil)
          Text(
            "Tap or hold the map. Exact coordinates are used; no snapping to a forecast town. Panning alone does not change your site."
          ).font(.caption)
        }.frame(height: 280)
      }
      .navigationTitle("Observing site").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Use location") {
            if let candidate {
              onChoose(candidate)
              dismiss()
            }
          }.disabled(candidate == nil)
        }
      }
    }
  }
}
