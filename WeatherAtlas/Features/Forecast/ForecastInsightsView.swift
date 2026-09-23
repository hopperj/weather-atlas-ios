import Charts
import SwiftUI

@MainActor
final class ForecastInsightsModel: ObservableObject {
  @Published private(set) var changes: ForecastChanges?
  @Published private(set) var stations: [WeatherStation] = []
  @Published private(set) var changesMessage: String?
  @Published private(set) var stationsMessage: String?
  private var generation = 0
  private var regionID: String?

  func load(region: ForecastRegion, api: WeatherAPI) async {
    generation += 1
    let ticket = generation
    if regionID != region.id {
      changes = nil
      stations = []
      changesMessage = nil
      stationsMessage = nil
      regionID = region.id
    }
    async let changeTask: () = loadChanges(region: region, api: api, ticket: ticket)
    async let stationTask: () = loadStations(region: region, api: api, ticket: ticket)
    _ = await (changeTask, stationTask)
  }
  private func loadChanges(region: ForecastRegion, api: WeatherAPI, ticket: Int) async {
    do {
      let result = try await api.forecastChanges(areaID: region.id)
      guard !Task.isCancelled, ticket == generation, result.regionId == region.id else { return }
      changes = result
      changesMessage = result.stale ? "Comparison update overdue; saved comparison shown." : nil
    } catch {
      guard !Task.isCancelled, ticket == generation else { return }
      changesMessage =
        changes == nil
        ? "Forecast comparisons aren't available yet." : "Could not refresh the comparison."
    }
  }
  private func loadStations(region: ForecastRegion, api: WeatherAPI, ticket: Int) async {
    do {
      let result = try await api.nearbyStations(
        longitude: region.longitude, latitude: region.latitude)
      guard !Task.isCancelled, ticket == generation else { return }
      stations = result.items
      stationsMessage =
        result.items.isEmpty
        ? "No collected stations within 100 km of this forecast location." : nil
    } catch {
      guard !Task.isCancelled, ticket == generation else { return }
      stationsMessage =
        stations.isEmpty
        ? "Nearby observations aren't available yet." : "Could not refresh the observations."
    }
  }
}

struct ForecastInsightsView: View {
  private enum InsightDisclosure { case changes, summary }
  let region: ForecastRegion
  @ObservedObject var summary: ForecastSummaryModel
  @EnvironmentObject private var store: AppStore
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var model = ForecastInsightsModel()
  @StateObject private var changesSummary = ForecastSummaryModel()
  @State private var expandedInsight: InsightDisclosure?
  @State private var observationsExpanded = false
  @State private var selectedStation: WeatherStation?
  private var changesExpanded: Bool { expandedInsight == .changes }
  private var summaryExpanded: Bool { expandedInsight == .summary }
  private var changesInput: ForecastSummaryInput {
    ForecastSummaryInput(
      changes: model.changes, region: region, server: store.serverURL.absoluteString)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 24) {
        compactButton("What changed?", expanded: changesExpanded, id: "forecastChanges") {
          expandedInsight = changesExpanded ? nil : .changes
        }
        compactButton("Summary", expanded: summaryExpanded, id: "forecastSummary") {
          expandedInsight = summaryExpanded ? nil : .summary
        }
        .accessibilityValue("\(summaryExpanded ? "Expanded" : "Collapsed"), \(summaryStatus)")
      }
      if changesExpanded { changesDetails }
      if summaryExpanded { summaryDetails }
      VStack(alignment: .leading, spacing: 14) {
        Button {
          observationsExpanded.toggle()
        } label: {
          HStack {
            Text("Nearby observations").font(.headline)
            Spacer()
            Image(systemName: observationsExpanded ? "chevron.up" : "chevron.down")
              .font(.caption.weight(.semibold)).foregroundStyle(.tint)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Nearby observations")
        .accessibilityValue(observationsExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(
          observationsExpanded ? "Hide nearby station readings" : "Show nearby station readings"
        )
        .accessibilityIdentifier("nearbyObservations")
        if observationsExpanded {
          Text("Distances from this forecast region's representative point.")
            .font(.caption2).foregroundStyle(.secondary)
          ForEach(model.stations.prefix(3)) { station in
            Button {
              selectedStation = station
            } label: {
              StationSummary(station: station)
            }
            .buttonStyle(.plain)
          }
          if let message = model.stationsMessage {
            Text(message).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .padding().background(
        Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
    .task(id: "\(region.id)-\(region.issuedAt)-\(store.forecastRefresh)-\(scenePhase)") {
      guard scenePhase == .active else { return }
      await model.load(region: region, api: store.api)
    }
    .task(
      id:
        "\(changesInput.id)|\(scenePhase)|\(summary.isGenerating)|\(summary.summaryID ?? "")|\(summary.message ?? "")"
    ) {
      guard scenePhase == .active else {
        changesSummary.cancel()
        return
      }
      let input = changesInput
      // Prepare without requiring the disclosure to open. Let the weekly summary
      // finish first, avoiding competing cold on-device inference requests.
      guard !summary.isGenerating, summary.currentInput != nil else {
        changesSummary.synchronize(input)
        return
      }
      changesSummary.prepare(input)
    }
    .onDisappear { changesSummary.cancel() }
    .sheet(item: $selectedStation) { StationDetailView(station: $0, api: store.api) }
  }

  private var summaryStatus: String {
    if summary.isGenerating { return "Preparing summary" }
    if summary.message != nil { return "Summary unavailable" }
    if summary.text != nil { return "Summary ready" }
    return "Waiting for forecast"
  }

  private func compactButton(
    _ title: String, expanded: Bool, id: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title)
        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
      }
      .font(.subheadline.weight(.semibold))
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain).foregroundStyle(.tint)
    .accessibilityLabel(title).accessibilityValue(expanded ? "Expanded" : "Collapsed")
    .accessibilityHint(expanded ? "Hide details" : "Show details")
    .accessibilityIdentifier(id)
  }

  private var changesDetails: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let text = changesSummary.text {
        Text(text).font(.subheadline).textSelection(.enabled)
          .id("changes-text-\(changesSummary.summaryID ?? text)")
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(text)
          .accessibilityIdentifier("forecastChangesText")
        if let issued = changesSummary.issuedAt {
          Text(
            "\(changesSummary.isStale ? "Saved forecast" : "Forecast") · issued \(issued.formatted(date: .abbreviated, time: .shortened))"
          )
          .font(.caption2).foregroundStyle(.secondary)
        }
        Text(
          changesSummary.isGeneratedOnDevice
            ? "Generated on this device with Apple Intelligence. It may make mistakes; check the forecast details below."
            : "Compared the previous and current bulletins. Minor adjustments are omitted."
        )
        .font(.caption2).foregroundStyle(.secondary)
      } else if changesSummary.isGenerating || (summary.isGenerating && changesInput.hasForecast) {
        Text("Summarizing important changes on your iPhone…").font(.caption).foregroundStyle(
          .secondary)
      }
      if !changesSummary.isGenerating, let message = changesSummary.message {
        Text(message).font(.subheadline)
          .id("changes-message-\(message)")
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(message)
          .accessibilityIdentifier("forecastChangesMessage")
      } else if changesSummary.text == nil && !changesSummary.isGenerating && !summary.isGenerating
      {
        Text(changesInput.unavailableReason ?? "Preparing the forecast comparison…")
          .font(.caption).foregroundStyle(.secondary)
      }
      if !changesSummary.isGenerating, !summary.isGenerating,
        changesInput.hasForecast, changesSummary.message != nil
      {
        Button("Try comparison again") { changesSummary.retry() }
          .font(.caption).accessibilityIdentifier("forecastChangesRetry")
      }
      if let message = model.changesMessage {
        Text(message).font(.caption).foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding().background(
      Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("forecastChangesDetails")
  }

  private var summaryDetails: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let text = summary.text {
        Text(text).font(.subheadline).textSelection(.enabled).accessibilityIdentifier(
          "forecastSummaryText")
        if let issued = summary.issuedAt {
          Text(
            "\(summary.isStale ? "Saved forecast" : "Forecast") · issued \(issued.formatted(date: .abbreviated, time: .shortened))"
          )
          .font(.caption2).foregroundStyle(.secondary)
        }
      }
      if summary.isGenerating && summary.text == nil {
        Text("Summarizing on your iPhone…").font(.caption).foregroundStyle(.secondary)
      } else if !summary.isGenerating {
        if let message = summary.message {
          Text(message).font(.subheadline).accessibilityIdentifier("forecastSummaryMessage")
        }
        if let input = summary.currentInput, summary.summaryID != input.id {
          Button(
            summary.text == nil ? "Try summary again" : "Update summary for the latest forecast"
          ) {
            summary.retry()
          }.font(.caption).accessibilityIdentifier("forecastSummaryRetry")
        }
      }
      Text(
        summary.text == nil
          ? "Uses Apple Intelligence on this device only. No forecast data is sent to a cloud AI service."
          : summary.isGeneratedOnDevice
            ? "Generated on this device with Apple Intelligence. It may make mistakes; check the forecast details below."
            : "Server-prepared outlook shown to preserve the forecast's exact details."
      )
      .font(.caption2).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding().background(
      Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16)
    )
  }
}

struct StationSummary: View {
  let station: WeatherStation
  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text("Observed at \(station.name)").font(.subheadline)
        Text(
          station.observation.observedAt, format: .dateTime.weekday(.abbreviated).hour().minute()
        )
        .font(.caption).foregroundStyle(.secondary)
        if let distance = station.distanceKm {
          Text("\(distance.formatted(.number.precision(.fractionLength(1)))) km away").font(
            .caption2)
        }
      }
      Spacer()
      VStack(alignment: .trailing) {
        Text(station.formatted(.temperatureC)).font(.headline)
        if station.isStale {
          Label("Stale", systemImage: "clock.badge.exclamationmark").font(.caption)
        }
      }
      Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
    }.padding(.vertical, 4).accessibilityElement(children: .combine)
  }
}

struct StationDetailView: View {
  let station: WeatherStation
  let api: WeatherAPI
  @Environment(\.dismiss) private var dismiss
  @State private var field = StationField.temperatureC
  @State private var history: StationHistory?
  @State private var error: String?
  var body: some View {
    NavigationStack {
      List {
        Section {
          StationSummary(station: station)
          Text(station.attribution).font(.caption).foregroundStyle(.secondary)
          ForEach(StationField.allCases) { field in
            HStack {
              Text(field.title)
              Spacer()
              Text(station.formatted(field))
            }
          }
        }
        Section("Past 48 hours") {
          Picker("Plot", selection: $field) {
            ForEach(StationField.allCases) { Text($0.title).tag($0) }
          }
          if let history, history.field == field.rawValue {
            if history.items.contains(where: { $0.value != nil }) {
              // Individual points preserve gaps and never interpolate unobserved weather.
              Chart(history.items) { item in
                if let value = item.value {
                  PointMark(x: .value("Time", item.time), y: .value(field.unit, value))
                }
              }.frame(height: 220).chartYAxisLabel(field.unit)
            } else {
              Text("No usable observations for this measurement yet.")
            }
          }
          if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
          Text(
            "Missing or rejected measurements are not plotted. Precipitation is the measured past-hour amount."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      .navigationTitle(station.name).navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("Done") { dismiss() } }
      .task(id: field) {
        let requested = field
        error = nil
        do {
          let result = try await api.stationHistory(id: station.id, field: requested)
          guard !Task.isCancelled, field == requested, result.stationId == station.id else {
            return
          }
          history = result
        } catch { if !Task.isCancelled { self.error = "Observation history is unavailable." } }
      }
    }
  }
}
