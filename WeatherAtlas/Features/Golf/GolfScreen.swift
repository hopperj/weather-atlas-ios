import CoreLocation
import SwiftUI

struct GolfScreen: View {
  @ObservedObject var settings: GolfSettingsStore
  @EnvironmentObject private var store: AppStore
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var model = GolfModel()
  @State private var firstDate = Date()
  @State private var refresh = 0
  @State private var pickingLocation = false
  @State private var pickingTime = false
  private var zone: TimeZone { TimeZone(identifier: settings.value.timeZone) ?? .current }
  private var localDate: String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "yyyy-MM-dd"
    // A retained page rolls forward when a new day begins.
    return formatter.string(from: max(firstDate, Date()))
  }
  private var enabled: Bool { scenePhase == .active && store.selectedTab == 4 }
  private var requestID: String {
    "\(enabled)|\(store.serverURL)|\(settings.value)|\(localDate)|\(refresh)|\(store.forecastRefresh)"
  }
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          controls
          if let error = model.error {
            Text(error).font(.callout).foregroundStyle(.secondary)
            Button("Try again") { refresh += 1 }
          }
          if let outlook = model.outlook,
            outlook.latitude == settings.value.latitude,
            outlook.longitude == settings.value.longitude,
            outlook.limits == settings.value.limits, outlook.timeZone == settings.value.timeZone
          {
            if let run = outlook.runTime {
              Text("Model issued \(golfDate(run, zone: zone, pattern: "EEE MMM d, HH:mm"))")
                .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(outlook.days) { day in
              if let narrative = model.narratives[day.id] {
                GolfDayCard(
                  day: day, narrative: narrative, outlook: outlook, zone: zone,
                  server: store.serverURL.absoluteString)
              }
            }
            DisclosureGroup("About the score & data") {
              VStack(alignment: .leading, spacing: 8) {
                Text(outlook.scoreMeaning)
                Text(outlook.method)
                if let context = outlook.regionalContext {
                  Text(
                    "Regional rain probability: \(context.name), \(context.distanceKm.formatted(.number.precision(.fractionLength(1)))) km from the pin; issued \(golfDate(context.issuedAt, zone: zone, pattern: "EEE MMM d, HH:mm")).\(context.stale ? " Update overdue." : "")"
                  )
                } else {
                  Text(
                    "No nearby regional rain-probability forecast is available. It is not inferred from precipitation amounts."
                  )
                }
                Text(
                  "The model describes a grid cell, not the exact conditions on a fairway. Check warnings and course guidance; this does not assess lightning, drainage or whether the course is open."
                )
                Text(
                  "On supported iPhones with Apple Intelligence enabled, explanations are written on this device. Otherwise, a rules-based description is shown. No cloud AI is used."
                )
              }.font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
            }
          } else if model.loading {
            ProgressView("Loading the point forecast…")
              .frame(maxWidth: .infinity).padding(.vertical, 32)
              .accessibilityIdentifier("golfInitialLoading")
          }
        }.padding()
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle("Golf")
      .navigationBarTitleDisplayMode(.inline)
      .refreshable { refresh += 1 }
      .sheet(isPresented: $pickingLocation) { GolfLocationPicker(settings: settings) }
      .sheet(isPresented: $pickingTime) {
        GolfSchedulePicker(settings: settings, firstDate: $firstDate)
      }
      .task(id: requestID) {
        guard enabled else {
          model.cancel()
          return
        }
        await model.load(preferences: settings.value, firstDate: localDate, api: store.api)
        guard !Task.isCancelled else { return }
        await model.explain(
          server: store.serverURL.absoluteString, weeklySummary: store.forecastSummary)
      }
      .onDisappear { model.cancel() }
    }
  }
  private var controls: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 3) {
          Text(settings.value.siteName.isEmpty ? "Golf pin" : settings.value.siteName).font(
            .headline)
          Text(String(format: "%.4f, %.4f", settings.value.latitude, settings.value.longitude))
            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("golfCoordinates")
        }
        Spacer()
        Button {
          pickingLocation = true
        } label: {
          Label("Map", systemImage: "mappin.and.ellipse")
        }
        .accessibilityIdentifier("golfChooseLocation")
      }
      Button {
        pickingTime = true
      } label: {
        Label("Tee time \(settings.value.teeTime) · \(zone.identifier)", systemImage: "clock")
          .font(.subheadline).multilineTextAlignment(.leading)
      }.accessibilityIdentifier("golfChooseTime")
      HStack {
        Text("2h before · 4h round · 1h after").font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 8)
        NavigationLink {
          GolfSettingsScreen(settings: settings)
        } label: {
          Label("Limits", systemImage: "slider.horizontal.3").font(.subheadline)
        }.accessibilityIdentifier("golfLimitsLink")
      }
    }.padding().background(.background, in: RoundedRectangle(cornerRadius: 16))
  }
}

private struct GolfDayCard: View {
  let day: GolfDay
  @ObservedObject var narrative: ForecastSummaryModel
  let outlook: GolfOutlook
  let zone: TimeZone
  let server: String
  private var description: GolfDescription? {
    GolfDescription.completed(
      day: day,
      input: ForecastSummaryInput(golf: day, outlook: outlook, server: server), narrative: narrative
    )
  }
  private var accent: Color {
    ["within", "partial"].contains(day.state)
      ? .teal : day.state == "outside" ? .orange : .secondary
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(golfDate(day.teeTime, zone: zone, pattern: "EEEE, MMM d")).font(.headline)
          Text(
            "\(golfDate(day.teeTime, zone: zone, pattern: "HH:mm"))–\(golfDate(day.endTime, zone: zone, pattern: "HH:mm"))"
          )
          .font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Text(day.score.map { "\($0)/100" } ?? "—").font(.title2.bold()).foregroundStyle(accent)
          Text("Weather fit")
            .font(.caption2).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
      }
      Text(day.status).font(.subheadline.weight(.semibold)).foregroundStyle(accent)
      if let description {
        Text(description.text)
          .font(.callout).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("golfDescription-\(day.id)")
        Text(description.isGeneratedOnDevice ? "Written on this iPhone" : "Rules-based description")
          .font(.caption2).foregroundStyle(.secondary)
        if let note = description.note { Text(note).font(.caption).foregroundStyle(.secondary) }
      }
      DisclosureGroup("Round details") {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(day.segments) { part in
            VStack(alignment: .leading, spacing: 5) {
              Text(
                "\(part.name) · \(golfDate(part.start, zone: zone, pattern: "HH:mm"))–\(golfDate(part.end, zone: zone, pattern: "HH:mm"))"
              )
              .font(.subheadline.bold())
              metric(
                "Temperature",
                part.temperatureRangeC.map { $0.map { number($0) }.joined(separator: "–") + "°C" },
                check: part.checks.first { $0.field == "temperature" })
              metric(
                "Sustained wind", part.maxWindKmh.map { "up to \(number($0)) km/h" },
                check: part.checks.first { $0.field == "wind" })
              metric("Gusts", part.maxGustKmh.map { "up to \(number($0)) km/h" })
              metric(
                "Precipitation",
                part.rain.map {
                  $0.minimumMm == $0.maximumMm
                    ? "\(number($0.maximumMm)) mm"
                    : "\(number($0.minimumMm))–\(number($0.maximumMm)) mm"
                }, check: part.checks.first { $0.field == "rain" })
              metric(
                "Regional rain chance", part.popPercent.map { "\(number($0))%" } ?? "Not provided",
                check: part.popPercent == nil ? nil : part.checks.first { $0.field == "pop" })
              if part.rainTimingUncertain {
                Text("Precipitation timing is too coarse to check your limit.").font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
          ForEach(day.reasons, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
          ForEach(day.regionalPeriods, id: \.start) { period in
            VStack(alignment: .leading, spacing: 4) {
              Text("Regional forecast · \(period.name)").font(.caption.bold())
              Text(
                "\(golfDate(period.start, zone: zone, pattern: "EEE HH:mm"))–\(golfDate(period.end, zone: zone, pattern: "EEE HH:mm"))"
              )
              .font(.caption2).foregroundStyle(.secondary)
              Text(period.condition).font(.caption)
              if let amount = period.precipitationAmount {
                Text("\(amount) for the regional period, not just your round.").font(.caption)
              }
            }
          }
        }.padding(.top, 10)
      }.font(.subheadline)
    }.padding().background(.background, in: RoundedRectangle(cornerRadius: 16))
      .accessibilityElement(children: .contain).accessibilityIdentifier("golfDay-\(day.id)")
  }
  private func number(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...1)))
  }
  private func metric(_ label: String, _ value: String?, check: GolfSegment.Check? = nil)
    -> some View
  {
    HStack(alignment: .top) {
      Text(label)
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        Text(value ?? "Unavailable")
        if let check, check.state != "within" {
          Text(check.state == "outside" ? "Beyond limit" : "Cannot assess")
            .font(.caption2).foregroundStyle(
              check.state == "outside" ? Color.orange : Color.secondary)
        }
      }
    }.font(.caption)
  }
}

private func golfDate(_ date: Date, zone: TimeZone, pattern: String) -> String {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_CA")
  formatter.timeZone = zone
  formatter.dateFormat = pattern
  return formatter.string(from: date)
}

private struct GolfLocationPicker: View {
  let settings: GolfSettingsStore
  @Environment(\.dismiss) private var dismiss
  @State private var draft: GolfPreferences
  init(settings: GolfSettingsStore) {
    self.settings = settings
    _draft = State(initialValue: settings.value)
  }
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ForecastLocationMapSurface(
          regions: [], selectedID: nil, pin: draft.coordinate,
          focus: settings.value.coordinate, focusRevision: 0,
          onDropPin: { point in
            draft.latitude = point.latitude
            draft.longitude = point.longitude
            draft.siteName = "Golf pin"
          }, onSelectCity: { _ in })
        VStack(alignment: .leading, spacing: 8) {
          Text("Tap or hold anywhere to place your golf pin.").font(.subheadline)
          Text(String(format: "%.5f, %.5f", draft.latitude, draft.longitude)).font(.caption)
            .foregroundStyle(.secondary)
          TextField("Location name (optional)", text: $draft.siteName).textFieldStyle(
            .roundedBorder
          )
          .accessibilityIdentifier("golfSiteName")
          Text(
            "The server samples model data at this coordinate. Your regular forecast location won't change."
          )
          .font(.caption).foregroundStyle(.secondary)
        }.padding().background(.regularMaterial)
      }
      .navigationTitle("Golf location").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Use pin") {
            var next = settings.value
            next.latitude = draft.latitude
            next.longitude = draft.longitude
            next.siteName = draft.siteName.trimmingCharacters(in: .whitespacesAndNewlines)
            settings.save(next)
            dismiss()
          }.disabled(!draft.isValid).accessibilityIdentifier("saveGolfPin")
        }
      }
    }
  }
}

private struct GolfSchedulePicker: View {
  let settings: GolfSettingsStore
  @Binding var firstDate: Date
  @Environment(\.dismiss) private var dismiss
  @State private var day: Date
  @State private var time: Date
  @State private var zoneID: String
  init(settings: GolfSettingsStore, firstDate: Binding<Date>) {
    self.settings = settings
    _firstDate = firstDate
    let prefs = settings.value
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: prefs.timeZone) ?? .current
    _day = State(initialValue: max(firstDate.wrappedValue, Date()))
    _time = State(
      initialValue: calendar.date(
        bySettingHour: prefs.teeHour, minute: prefs.teeMinute, second: 0, of: Date()) ?? Date())
    _zoneID = State(initialValue: prefs.timeZone)
  }
  private var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: zoneID) ?? .current
    return value
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("Playing time") {
          DatePicker(
            "First day", selection: $day,
            in: calendar.startOfDay(
              for: Date())...(calendar.date(byAdding: .day, value: 6, to: Date()) ?? Date()),
            displayedComponents: .date)
          DatePicker("Tee time", selection: $time, displayedComponents: .hourAndMinute)
            .accessibilityIdentifier("golfTeeTime")
        }
        Section("Time zone at the course") {
          Picker("Time zone", selection: $zoneID) {
            ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
          }.pickerStyle(.navigationLink)
          Text(
            "Choose the course's time zone when planning a trip. The same local tee time is checked for seven days, where model and regional forecasts are available."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
          Text(
            "Each round lasts four elapsed hours. We also check the two hours before and the hour after. Missing forecast coverage results in an incomplete assessment, not a guess."
          )
        }.font(.footnote).foregroundStyle(.secondary)
      }
      .environment(\.timeZone, calendar.timeZone)
      .navigationTitle("Golf schedule").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            var next = settings.value
            next.teeHour = calendar.component(.hour, from: time)
            next.teeMinute = calendar.component(.minute, from: time)
            next.timeZone = zoneID
            settings.save(next)
            firstDate = day
            dismiss()
          }.accessibilityIdentifier("saveGolfSchedule")
        }
      }
    }
  }
}
