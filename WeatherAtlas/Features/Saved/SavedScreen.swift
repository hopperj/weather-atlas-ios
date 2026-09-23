import SwiftUI

struct SavedScreen: View {
  @EnvironmentObject private var store: AppStore
  var body: some View {
    NavigationStack {
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
      .task(id: store.serverURL) {
        await store.forecast.loadRegions()
        if !Task.isCancelled { store.updateLocationNames(from: store.forecast.regions) }
      }
    }
  }
}
