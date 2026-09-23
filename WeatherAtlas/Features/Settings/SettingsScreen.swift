import SwiftUI

struct SettingsScreen: View {
  @EnvironmentObject private var store: AppStore
  var body: some View {
    NavigationStack {
      Form {
        Section {
          NavigationLink {
            AboutWeatherAtlasScreen(buildVersion: buildVersion)
          } label: {
            Label("About Weather Atlas", systemImage: "info.circle")
          }
          .accessibilityIdentifier("aboutWeatherAtlas")
        }
        Section {
          NavigationLink {
            DefaultForecastLocationPicker(model: store.forecast)
          } label: {
            LabeledContent("Default location", value: store.defaultForecastName)
          }
          .accessibilityLabel("Default location")
          .accessibilityValue(store.defaultForecastName)
          .accessibilityIdentifier("defaultForecastLocation")
        } header: {
          Text("Forecast")
        } footer: {
          Text(
            "Used when no forecast region is chosen and your phone’s location is unavailable. Your current location takes priority when available."
          )
        }
        Section("Golf") {
          NavigationLink("Golf weather limits") {
            GolfSettingsScreen(settings: store.golfSettings)
          }.accessibilityIdentifier("golfSettings")
        }
        Section("Data & privacy") {
          Label("Secure connection to Weather Atlas", systemImage: "lock.shield")
          Text(
            "Weather Atlas provides Environment Canada forecasts, model data, radar and satellite imagery over HTTPS. Your saved places are stored on this device."
          )
          Text(
            "Apple Maps supplies the basemap. Forecast uses your location while that screen is open unless you choose a region. Coordinates go only to the Weather Atlas service for a nearby forecast lookup and are not saved by the app. The map requests location when you tap its location button."
          )
          Text(
            "Your manually chosen golf pin, tee time and weather limits are saved on this device. Golf sends the pin, schedule and limits to Weather Atlas for its assessment; explanations use Apple Intelligence on the device, without a cloud AI service."
          )
        }.font(.footnote)
      }
      .navigationTitle("Settings")
    }
  }
  private var buildVersion: String {
    let info = Bundle.main.infoDictionary ?? [:]
    return
      "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))"
  }
}

private struct AboutWeatherAtlasScreen: View {
  let buildVersion: String

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 12) {
          Image(systemName: "cloud.sun.fill")
            .font(.largeTitle).symbolRenderingMode(.multicolor)
            .accessibilityHidden(true)
          Text("Weather Atlas").font(.largeTitle.bold())
            .accessibilityAddTraits(.isHeader)
          Text("Made in Canada, for Canadians.")
            .font(.headline).foregroundStyle(.tint)
        }
        Text(
          "Weather Atlas is a Canadian-made weather app built on Environment and Climate Change Canada’s forecasts and weather model data."
        )
        .accessibilityIdentifier("aboutWeatherAtlasIntroduction")
        Text(
          "View and interact with forecast and model data for locations anywhere in Canada. Explore the map, look ahead with daily and hourly forecasts, and follow changing conditions with radar and satellite imagery."
        )
        .accessibilityIdentifier("aboutWeatherAtlasFeatures")
        Text(
          "Built by a Canadian, using Canadian weather data, for Canadians—free of charge."
        )
        .accessibilityIdentifier("aboutWeatherAtlasMission")
        Divider()
        VStack(alignment: .leading, spacing: 12) {
          Text("Weather Atlas is an independent app, not an official Government of Canada app.")
          Text(
            "Imagery attribution appears with its layer. Experimental smoke results retain their research status."
          )
          Text("Version \(buildVersion)")
            .accessibilityIdentifier("aboutWeatherAtlasVersion")
        }
        .font(.footnote).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(24)
      .background(.background, in: RoundedRectangle(cornerRadius: 20))
      .padding()
    }
    .background(Color(uiColor: .systemGroupedBackground))
    .navigationTitle("About")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct DefaultForecastLocationPicker: View {
  @ObservedObject var model: ForecastModel
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    List {
      if query.isEmpty || "Halifax Nova Scotia".localizedCaseInsensitiveContains(query) {
        Button {
          store.setDefaultForecastLocation(nil)
          dismiss()
        } label: {
          row("Halifax", province: "Nova Scotia", selected: store.defaultForecastLocation == nil)
        }
        .accessibilityIdentifier("default-location-halifax")
      }
      if model.regionListLoading && model.regions.isEmpty { ProgressView("Loading locations…") }
      if let error = model.regionListError {
        Text(error).font(.footnote).foregroundStyle(.secondary)
        Button("Retry") { Task { await model.loadRegions() } }
      }
      ForEach(locations) { region in
        Button {
          store.setDefaultForecastLocation(region)
          dismiss()
        } label: {
          row(
            region.displayName, province: region.provinceName,
            selected: store.defaultForecastLocation?.id == region.id)
        }
        .accessibilityIdentifier("default-location-\(region.id)")
      }
      if !model.regionListLoading && model.regionListError == nil && locations.isEmpty
        && !query.isEmpty && !"Halifax Nova Scotia".localizedCaseInsensitiveContains(query)
      {
        Text("No matching locations.").foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Default location")
    .searchable(
      text: $query, placement: .navigationBarDrawer(displayMode: .always),
      prompt: "Region or province"
    )
    .task { await model.loadRegions() }
  }

  private var locations: [ForecastRegion] {
    model.regions.filter {
      !$0.isHalifaxMetro
        && (query.isEmpty
          || "\($0.displayName) \($0.name) \($0.provinceName)".localizedCaseInsensitiveContains(
            query))
    }.sorted {
      "\($0.displayName) \($0.provinceName)".localizedStandardCompare(
        "\($1.displayName) \($1.provinceName)")
        == .orderedAscending
    }
  }

  private func row(_ name: String, province: String, selected: Bool) -> some View {
    HStack {
      VStack(alignment: .leading) {
        Text(name).foregroundStyle(.primary)
        Text(province).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
