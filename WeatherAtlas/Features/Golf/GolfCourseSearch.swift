import CoreLocation
import MapKit
import SwiftUI

@MainActor protocol GolfCourseSearching {
  func courses(matching query: String) async throws -> [GolfCourse]
  func pin(at coordinate: CLLocationCoordinate2D) async throws -> GolfCourse
  func cancel()
}

enum GolfCourseLookupError: LocalizedError {
  case outsideCanada, unavailable
  var errorDescription: String? {
    switch self {
    case .outsideCanada: "Please choose a golf course or pin in Canada."
    case .unavailable: "Couldn't verify this location and its time zone. Try again when connected."
    }
  }
}

/// MapKit supplies suggestions, but a geographic search region is only a hint.
/// Validate the actual country and time zone before showing or accepting a place.
@MainActor final class AppleGolfCourseDirectory: GolfCourseSearching {
  private var search: MKLocalSearch?
  private let geocoder = CLGeocoder()

  func courses(matching query: String) async throws -> [GolfCourse] {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query + " golf course Canada"
    request.resultTypes = .pointOfInterest
    request.region = MKCoordinateRegion(
      center: .init(latitude: 56, longitude: -96),
      span: .init(latitudeDelta: 44, longitudeDelta: 90))
    if #available(iOS 18.0, *) {
      request.pointOfInterestFilter = .init(including: [.golf])
      request.regionPriority = .required
    }
    let operation = MKLocalSearch(request: request)
    search = operation
    let response = try await operation.start()
    try Task.checkCancellation()
    var seen = Set<String>()
    return response.mapItems.compactMap { item -> GolfCourse? in
      guard item.placemark.isoCountryCode == "CA", let zone = item.timeZone,
        let name = item.name
      else { return nil }
      if #available(iOS 18.0, *) {
        guard item.pointOfInterestCategory == .golf else { return nil }
      } else {
        // Golf's dedicated POI category arrived in iOS 18. Be conservative on 17.
        guard
          ["golf", "links", "country club"].contains(where: name.localizedCaseInsensitiveContains)
        else { return nil }
      }
      let course = GolfCourse(
        name: name, locality: Self.locality(item.placemark),
        latitude: item.placemark.coordinate.latitude,
        longitude: item.placemark.coordinate.longitude,
        timeZone: zone.identifier, countryCode: "CA", kind: .course)
      return course.isValid && seen.insert(course.id).inserted ? course : nil
    }
  }

  func pin(at coordinate: CLLocationCoordinate2D) async throws -> GolfCourse {
    let places = try await geocoder.reverseGeocodeLocation(
      CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
      preferredLocale: Locale(identifier: "en_CA"))
    try Task.checkCancellation()
    guard let place = places.first else { throw GolfCourseLookupError.unavailable }
    guard place.isoCountryCode == "CA" else { throw GolfCourseLookupError.outsideCanada }
    guard let zone = place.timeZone else { throw GolfCourseLookupError.unavailable }
    return GolfCourse(
      name: "Golf pin", locality: Self.locality(place), latitude: coordinate.latitude,
      longitude: coordinate.longitude, timeZone: zone.identifier, countryCode: "CA", kind: .pin)
  }

  private static func locality(_ place: CLPlacemark) -> String {
    [place.locality, place.administrativeArea].compactMap { $0 }.joined(separator: ", ")
  }
  func cancel() {
    search?.cancel()
    search = nil
    geocoder.cancelGeocode()
  }
}

@MainActor final class GolfCourseSearchModel: ObservableObject {
  @Published private(set) var results: [GolfCourse] = []
  @Published private(set) var selected: GolfCourse?
  @Published private(set) var pin: CLLocationCoordinate2D?
  @Published private(set) var searching = false
  @Published private(set) var checkingPin = false
  @Published private(set) var error: String?
  private let directory: any GolfCourseSearching
  private var revision = 0

  init(directory: any GolfCourseSearching, initial: GolfCourse? = nil) {
    self.directory = directory
    selected = initial.flatMap { $0.isValid ? $0 : nil }
    pin = selected?.coordinate
  }
  func search(_ query: String, debounce: Duration = .milliseconds(400)) async {
    cancel()
    let request = revision
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    results = []
    error = nil
    guard query.count >= 2 else { return }
    selected = nil
    searching = true
    do {
      try await Task.sleep(for: debounce)
      let found = try await directory.courses(matching: query)
      guard !Task.isCancelled, request == revision else { return }
      results = found.filter { $0.isValid && $0.kind == .course }
      searching = false
    } catch {
      guard !Task.isCancelled, request == revision else { return }
      searching = false
      self.error = "Course search is unavailable. Try again, or drop a pin on the map."
    }
  }
  func choose(_ course: GolfCourse) {
    guard course.isValid else { return }
    cancel()
    selected = course
    pin = course.coordinate
    error = nil
    results = []
  }
  func dropPin(_ coordinate: CLLocationCoordinate2D) async {
    cancel()
    let request = revision
    selected = nil
    results = []
    pin = coordinate
    error = nil
    checkingPin = true
    do {
      let course = try await directory.pin(at: coordinate)
      guard !Task.isCancelled, request == revision else { return }
      guard course.isValid else { throw GolfCourseLookupError.outsideCanada }
      selected = course
      checkingPin = false
    } catch {
      guard !Task.isCancelled, request == revision else { return }
      checkingPin = false
      self.error =
        (error as? GolfCourseLookupError)?.errorDescription
        ?? GolfCourseLookupError.unavailable.errorDescription
    }
  }
  func cancel() {
    revision += 1
    directory.cancel()
    searching = false
    checkingPin = false
  }
}

struct GolfCoursePicker: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var model: GolfCourseSearchModel
  @State private var query = ""
  @State private var searchRevision = 0
  @State private var focus: CLLocationCoordinate2D
  @State private var focusRevision = 0
  @State private var pendingPin: GolfPinRequest?
  @FocusState private var searchFocused: Bool
  let focusSearch: Bool
  let onChoose: (GolfCourse) -> Void

  init(
    initial: GolfCourse?, focus: CLLocationCoordinate2D, focusSearch: Bool = false,
    onChoose: @escaping (GolfCourse) -> Void
  ) {
    var directory: any GolfCourseSearching = AppleGolfCourseDirectory()
    #if DEBUG && targetEnvironment(simulator)
      if ProcessInfo.processInfo.arguments.contains("-golfFixtureDirectory") {
        directory = GolfFixtureCourseDirectory()
      }
    #endif
    _model = StateObject(
      wrappedValue: GolfCourseSearchModel(directory: directory, initial: initial))
    _focus = State(initialValue: focus)
    self.onChoose = onChoose
    self.focusSearch = focusSearch
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ForecastLocationMapSurface(
          regions: [], selectedID: nil, pin: model.pin, focus: focus, focusRevision: focusRevision,
          onDropPin: {
            searchFocused = false
            pendingPin = GolfPinRequest(coordinate: $0)
          }, onSelectCity: { _ in }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        searchPanel
      }
      .navigationTitle("Canadian golf courses").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
      .task(id: "\(query)|\(searchRevision)") { await model.search(query) }
      .task { if focusSearch { searchFocused = true } }
      .task(id: pendingPin?.id) {
        if let pendingPin { await model.dropPin(pendingPin.coordinate) }
      }
      .onDisappear { model.cancel() }
    }
  }
  private var searchPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search Canadian golf courses", text: $query)
          .focused($searchFocused)
          .textInputAutocapitalization(.words).autocorrectionDisabled()
          .submitLabel(.search).accessibilityIdentifier("golfCourseSearch")
          .onSubmit { searchRevision += 1 }
        if !query.isEmpty {
          Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
            .labelStyle(.iconOnly).foregroundStyle(.secondary)
        }
      }.padding(12).background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
      if model.searching { ProgressView("Finding Canadian courses…").font(.caption) }
      if !model.results.isEmpty {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(model.results) { course in
              Button {
                searchFocused = false
                model.choose(course)
                focus = course.coordinate
                focusRevision += 1
              } label: {
                HStack {
                  Image(systemName: "flag.fill").foregroundStyle(.tint)
                  VStack(alignment: .leading, spacing: 3) {
                    Text(course.name).font(.subheadline.bold())
                    Text(course.locality).font(.caption).foregroundStyle(.secondary)
                  }
                  Spacer()
                  Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10)
              }.buttonStyle(.plain).accessibilityIdentifier("golfCourseResult-\(course.name)")
              Divider()
            }
          }
        }.frame(maxHeight: 180).scrollDismissesKeyboard(.interactively)
      } else if query.count >= 2 && !model.searching && model.error == nil && model.selected == nil
      {
        Text("No Canadian courses found. Try the course name and town, or drop a pin.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if model.checkingPin { ProgressView("Checking location in Canada…").font(.caption) }
      if let error = model.error {
        Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("golfCourseError")
        if !query.isEmpty {
          Button("Retry course search") { searchRevision += 1 }.font(.caption)
        }
        if let pin = model.pin {
          Button("Retry pin lookup") { pendingPin = GolfPinRequest(coordinate: pin) }
            .font(.caption)
        }
      }
      if let selected = model.selected {
        VStack(alignment: .leading, spacing: 3) {
          Text(selected.name).font(.headline).accessibilityIdentifier("golfCourseSelection")
          Text("\(selected.locality) · \(selected.timeZone)")
            .font(.caption).foregroundStyle(.secondary)
        }
        Button(selected.kind == .pin ? "Use this pin" : "Use this course") {
          onChoose(selected)
          dismiss()
        }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
          .accessibilityIdentifier("golfUseCourse")
      }
      Text("Tap or hold the map to drop a pin. Only Canadian locations can be saved.")
        .font(.caption2).foregroundStyle(.secondary)
    }.padding().background(.regularMaterial)
  }
}

private struct GolfPinRequest: Identifiable {
  let id = UUID()
  let coordinate: CLLocationCoordinate2D
}

#if DEBUG && targetEnvironment(simulator)
  /// Deterministic UI tests; never compiled into an App Store build.
  @MainActor private final class GolfFixtureCourseDirectory: GolfCourseSearching {
    func courses(matching query: String) async throws -> [GolfCourse] {
      [
        GolfCourse(
          name: "Avon Valley Golf & Country Club", locality: "Falmouth, NS",
          latitude: 44.98, longitude: -64.16, timeZone: "America/Halifax", countryCode: "CA",
          kind: .course),
        GolfCourse(
          name: "The Links at Brunello", locality: "Timberlea, NS",
          latitude: 44.65, longitude: -63.76, timeZone: "America/Halifax", countryCode: "CA",
          kind: .course),
      ]
      .filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    func pin(at coordinate: CLLocationCoordinate2D) async throws -> GolfCourse {
      GolfCourse(
        name: "Golf pin", locality: "Nova Scotia", latitude: coordinate.latitude,
        longitude: coordinate.longitude, timeZone: "America/Halifax", countryCode: "CA", kind: .pin)
    }
    func cancel() {}
  }
#endif
