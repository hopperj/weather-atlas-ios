import SwiftUI

struct SavedScreen: View {
  @EnvironmentObject private var store: AppStore
  @State private var astronomySite: ObservingSite?
  var body: some View {
    List {
      if store.saved.isEmpty {
        ContentUnavailableView(
          "Your places", systemImage: "bookmark",
          description: Text("Save a region from its forecast to keep it here."))
      }
      ForEach(store.saved) { place in
        HStack {
          Button {
            store.selectForecastRegion(place.id)
            store.selectedTab = 1
          } label: {
            VStack(alignment: .leading) {
              Text(place.displayName).font(.headline)
              Text(place.province).font(.caption).foregroundStyle(.secondary)
            }
          }.buttonStyle(.plain)
          Spacer()
          Button {
            astronomySite = ObservingSite(
              name: place.displayName, latitude: place.latitude, longitude: place.longitude)
          } label: {
            Image(systemName: "moon.stars")
          }
          .buttonStyle(.borderless).accessibilityLabel("Astronomy near \(place.displayName)")
          Button {
            store.mapPlace = place
            store.selectedTab = 0
          } label: {
            Image(systemName: "map")
          }
          .buttonStyle(.borderless).accessibilityLabel("Show \(place.displayName) on map")
        }.padding(.vertical, 6)
      }.onDelete(perform: store.remove)
    }
    .navigationTitle("Saved places")
    .toolbar { EditButton() }
    .sheet(item: $astronomySite) { site in
      NavigationStack {
        AstronomyScreen(api: store.api, seed: site, restoreLast: false)
          .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { astronomySite = nil } }
          }
      }
    }
    .task(id: store.serverURL) {
      await store.forecast.loadRegions()
      if !Task.isCancelled { store.updateLocationNames(from: store.forecast.regions) }
    }
  }
}
