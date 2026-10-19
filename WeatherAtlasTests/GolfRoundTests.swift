import CoreLocation
import UIKit
import XCTest

@testable import WeatherAtlas

final class GolfRoundTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_792_241_200)
  private var course: GolfCourse {
    GolfCourse(
      name: "Avon Valley", locality: "Falmouth, NS", latitude: 44.98, longitude: -64.16,
      timeZone: "America/Halifax", countryCode: "CA", kind: .course)
  }
  private func round(days: Int = 1, hour: Int = 10, id: UUID = UUID()) -> GolfRound {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = course.zone
    return GolfRound(
      id: id, course: course,
      localDate: GolfRound.dateString(
        calendar.date(byAdding: .day, value: days, to: now)!, zone: course.zone),
      teeHour: hour, teeMinute: 30)
  }

  @MainActor func testMultipleDatedRoundsSurviveRecreationAndEditDeleteAreIndependent() throws {
    let name = "GolfRounds-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = GolfSettingsStore(defaults: defaults)
    var prefs = settings.value
    prefs.teeHour = 15
    settings.save(prefs)
    XCTAssertTrue(
      settings.rounds.isEmpty, "A legacy time with no saved date must not invent a round")
    let first = round()
    let second = round(hour: 14)
    XCTAssertTrue(settings.saveRound(first))
    XCTAssertTrue(settings.saveRound(second))
    let reopened = GolfSettingsStore(defaults: defaults)
    XCTAssertEqual(reopened.rounds, [first, second])
    var edit = first
    edit.teeMinute = 45
    edit.course.name = "My course"
    XCTAssertTrue(reopened.saveRound(edit))
    XCTAssertEqual(reopened.rounds.count, 2)
    XCTAssertEqual(reopened.rounds.first { $0.id == second.id }, second)
    reopened.deleteRound(edit.id)
    XCTAssertEqual(GolfSettingsStore(defaults: defaults).rounds, [second])
    XCTAssertEqual(reopened.value, prefs)
  }

  @MainActor func testInvalidAndDuplicateStoredRoundsAreRejectedWithoutLosingValidRounds() throws {
    let name = "GolfRounds-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let valid = round()
    var invalid = valid
    invalid.id = UUID()
    invalid.localDate = "2026-02-30"
    var records = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode([invalid, valid, valid]))
        as? [[String: Any]])
    records.insert(["id": "damaged record"], at: 0)
    defaults.set(try JSONSerialization.data(withJSONObject: records), forKey: "golfRounds:v1")
    let store = GolfSettingsStore(defaults: defaults)
    XCTAssertEqual(store.rounds, [valid])
    XCTAssertFalse(store.saveRound(invalid))
    XCTAssertEqual(store.rounds, [valid])
  }

  @MainActor func testOutOfOrderTeeTimesAreImmediatelySortedAndPersisted() throws {
    let name = "GolfRounds-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = GolfSettingsStore(defaults: defaults)
    let early = round(days: 1, hour: 8)
    let midday = round(days: 1, hour: 14)
    let later = round(days: 2, hour: 7)
    for value in [later, midday, early] { XCTAssertTrue(store.saveRound(value)) }
    XCTAssertEqual(store.rounds, [early, midday, later])
    let data = try XCTUnwrap(defaults.data(forKey: "golfRounds:v1"))
    XCTAssertEqual(try JSONDecoder().decode([GolfRound].self, from: data), [early, midday, later])
    XCTAssertEqual(GolfSettingsStore(defaults: defaults).rounds, [early, midday, later])
    store.deleteRound(midday.id)
    XCTAssertEqual(store.rounds, [early, later])
  }

  @MainActor func testPreviouslyUnsortedSavedTeeTimesRestoreChronologically() throws {
    let name = "GolfRounds-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let early = round(days: 1, hour: 8)
    let late = round(days: 3, hour: 10)
    defaults.set(try JSONEncoder().encode([late, early]), forKey: "golfRounds:v1")
    XCTAssertEqual(GolfSettingsStore(defaults: defaults).rounds, [early, late])
  }

  @MainActor func testFrequentCoursesAreUniqueRankedAndLimitedToFive() throws {
    let name = "GolfCourses-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = GolfSettingsStore(defaults: defaults)
    XCTAssertTrue(store.frequentCourses.isEmpty)
    for index in 1...7 {
      for booking in 0..<index {
        var value = round(days: booking + 1)
        value.course.name = "Course \(index)"
        XCTAssertTrue(store.saveRound(value))
      }
    }
    XCTAssertEqual(
      store.frequentCourses.map(\.name),
      ["Course 7", "Course 6", "Course 5", "Course 4", "Course 3"])
    XCTAssertEqual(GolfSettingsStore(defaults: defaults).frequentCourses, store.frequentCourses)
  }

  @MainActor func testFrequentCoursesCountRoundsNotEditsAndUseLatestTeeTimeForTies() throws {
    let name = "GolfCourses-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = GolfSettingsStore(defaults: defaults)
    var first = round(days: -2)
    first.course.name = "First course"
    var second = round(days: 2)
    second.course.name = "Second course"
    XCTAssertTrue(store.saveRound(first))
    XCTAssertTrue(store.saveRound(second))
    XCTAssertEqual(store.frequentCourses.map(\.name), ["Second course", "First course"])
    first.teeMinute = 45
    XCTAssertTrue(store.saveRound(first))
    XCTAssertEqual(store.frequentCourses.map(\.name), ["Second course", "First course"])
    var another = round(days: -1)
    another.course = first.course
    XCTAssertTrue(store.saveRound(another))
    XCTAssertEqual(store.frequentCourses.map(\.name), ["First course", "Second course"])
    store.deleteRound(another.id)
    XCTAssertEqual(store.frequentCourses.map(\.name), ["Second course", "First course"])
  }

  @MainActor func testFrequentCoursesNormalizeRepeatedSearchesButKeepDifferentLocations() throws {
    let name = "GolfCourses-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = GolfSettingsStore(defaults: defaults)
    let first = round()
    var repeatVisit = round(days: 2)
    repeatVisit.course.name = "  AVON   VALLEY  "
    var pin = round(days: 3)
    pin.course = GolfCourse(
      name: "My golf pin", locality: "NS", latitude: 45.1, longitude: -64.6,
      timeZone: "America/Halifax", countryCode: "CA", kind: .pin)
    var elsewhere = round(days: 4)
    elsewhere.course = GolfCourse(
      name: first.course.name, locality: "Another town", latitude: 45.5, longitude: -64.8,
      timeZone: "America/Halifax", countryCode: "CA", kind: .course)
    for value in [first, repeatVisit, pin, elsewhere] { XCTAssertTrue(store.saveRound(value)) }
    XCTAssertEqual(store.frequentCourses.count, 3)
    XCTAssertEqual(store.frequentCourses.first?.bookingKey, first.course.bookingKey)
    XCTAssertTrue(store.frequentCourses.contains { $0.kind == .pin })
  }

  @MainActor func testCoursePickerFocusFollowsForecastRegionAndExactForecastPin() throws {
    let name = "GolfFocus-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = AppStore(
      configuration: AppConfiguration(apiBaseURL: URL(string: "https://golf-focus.test")!),
      defaults: defaults)
    let sydney = ForecastRegion(
      id: "sydney", name: "Sydney", latitude: 46.14, longitude: -60.19,
      province: "NS", provinceName: "Nova Scotia", issuedAt: now, stale: false, periods: [])
    store.forecast.regions = [sydney]
    store.selectForecastRegion(sydney.id)
    XCTAssertEqual(store.forecastMapFocus.latitude, 46.14)
    XCTAssertEqual(store.forecastMapFocus.longitude, -60.19)
    store.selectForecastRegion(
      sydney.id, pin: .init(regionID: sydney.id, latitude: 46.2, longitude: -60.3))
    XCTAssertEqual(store.forecastMapFocus.latitude, 46.2)
    XCTAssertEqual(store.forecastMapFocus.longitude, -60.3)
    store.toggle(sydney)
    store.selectForecastRegion(sydney.id)
    store.forecast.regions = []
    XCTAssertEqual(
      store.forecastMapFocus.latitude, 46.14,
      "A saved forecast selection also works before its bulletin loads")
    store.useCurrentLocationForForecast()
    store.setDefaultForecastLocation(sydney)
    XCTAssertEqual(store.forecastMapFocus.latitude, 46.14)
    store.setDefaultForecastLocation(nil)
    XCTAssertEqual(store.forecastMapFocus.latitude, 44.65)
    XCTAssertEqual(store.forecastMapFocus.longitude, -63.57)
  }

  @MainActor func testCalendarSelectionAcceptsTheDayInCourseTimeZoneIncludingTheSameDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Halifax")!
    let current = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 12)))
    var chosen: Date?
    let picker = GolfRoundCalendar(
      date: current, minimumDate: calendar.startOfDay(for: current), calendar: calendar
    ) { chosen = $0 }
    let delegate = picker.makeCoordinator()
    let selection = UICalendarSelectionSingleDate(delegate: delegate)
    let later = DateComponents(year: 2026, month: 11, day: 2)
    XCTAssertTrue(delegate.dateSelection(selection, canSelectDate: later))
    delegate.dateSelection(selection, didSelectDate: later)
    XCTAssertEqual(chosen.map { GolfRound.dateString($0, zone: calendar.timeZone) }, "2026-11-02")
    delegate.dateSelection(selection, didSelectDate: nil)
    XCTAssertEqual(chosen, current, "Re-tapping the selected day accepts it and invokes dismissal")
    XCTAssertFalse(
      delegate.dateSelection(
        selection, canSelectDate: DateComponents(year: 2026, month: 10, day: 31)))
    XCTAssertFalse(
      delegate.dateSelection(
        selection, canSelectDate: DateComponents(year: 2026, month: 2, day: 30)))
  }

  @MainActor func testEditingTheDateOrTimeAutomaticallyMovesTheRound() throws {
    let name = "GolfRounds-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = GolfSettingsStore(defaults: defaults)
    var first = round(hour: 8)
    var second = round(hour: 14)
    XCTAssertTrue(store.saveRound(first))
    XCTAssertTrue(store.saveRound(second))
    first.teeHour = 16
    XCTAssertTrue(store.saveRound(first))
    XCTAssertEqual(store.rounds, [second, first])
    second.localDate = round(days: 3).localDate
    XCTAssertTrue(store.saveRound(second))
    XCTAssertEqual(store.rounds, [first, second])
    XCTAssertEqual(GolfSettingsStore(defaults: defaults).rounds, [first, second])
  }

  @MainActor func testChronologyUsesCourseTimeZonesAndKeepsEqualTimesStable() throws {
    let name = "GolfRounds-\(UUID())"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = GolfSettingsStore(defaults: defaults)
    let first = round(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    var sameTime = round(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    var pacific = round(hour: 9)
    pacific.course = GolfCourse(
      name: "BC course", locality: "Vancouver, BC", latitude: 49.25, longitude: -123.1,
      timeZone: "America/Vancouver", countryCode: "CA", kind: .course)
    XCTAssertLessThan(pacific.teeHour, first.teeHour)
    XCTAssertGreaterThan(try XCTUnwrap(pacific.teeDate), try XCTUnwrap(first.teeDate))
    for value in [pacific, sameTime, first] { XCTAssertTrue(store.saveRound(value)) }
    XCTAssertEqual(store.rounds, [first, sameTime, pacific])
    sameTime.course.name = "Renamed course"
    XCTAssertTrue(store.saveRound(sameTime))
    XCTAssertEqual(store.rounds, [first, sameTime, pacific])
    XCTAssertEqual(GolfSettingsStore(defaults: defaults).rounds, [first, sameTime, pacific])
  }

  func testCanadianLocationAndCourseLocalWallClockValidation() {
    XCTAssertTrue(course.isValid)
    let foreign = GolfCourse(
      name: "Foreign course", locality: "Maine", latitude: 44,
      longitude: -69, timeZone: "America/New_York", countryCode: "US", kind: .course)
    XCTAssertFalse(foreign.isValid)
    var value = round()
    value.localDate = "2026-03-08"
    value.teeHour = 2
    XCTAssertNil(value.teeDate, "DST-skipped local times must not silently move an hour")
    value.localDate = "2026-11-01"
    value.teeHour = 1
    XCTAssertNotNil(value.teeDate)
    XCTAssertEqual(value.teeDate?.ISO8601Format(), "2026-11-01T04:30:00Z")
    value.teeHour = 24
    XCTAssertFalse(value.isValid)
    value = round()
    value.localDate = "2026-2-03"
    XCTAssertFalse(value.isValid)
    value = round()
    XCTAssertEqual(value.calendar.component(.hour, from: value.teeDate!), 10)
    XCTAssertEqual(value.preferences(limits: GolfLimits()).timeZone, "America/Halifax")
  }

  func testPendingAndPassedUseCourseCalendarNotDeviceDate() {
    XCTAssertEqual(round(days: -1).availability(at: now), .passed)
    XCTAssertEqual(round(days: 1).availability(at: now), .ready)
    XCTAssertEqual(round(days: 6).availability(at: now), .ready)
    XCTAssertEqual(round(days: 7).availability(at: now), .pending)
    XCTAssertEqual(round(days: 80).availability(at: now), .pending)
    let pacific = GolfCourse(
      name: "Test course", locality: "BC", latitude: 49, longitude: -123,
      timeZone: "America/Vancouver", countryCode: "CA", kind: .course)
    // Oct 18 01:00 UTC; Oct 17 at the course.
    let utcOctober18 = Date(timeIntervalSince1970: 1_792_285_200)
    var trip = GolfRound(course: pacific, localDate: "2026-10-24", teeHour: 10, teeMinute: 30)
    XCTAssertEqual(trip.availability(at: utcOctober18), .pending)
    trip.localDate = "2026-10-23"
    XCTAssertEqual(trip.availability(at: utcOctober18), .ready)
    trip.localDate = "2026-10-18"
    XCTAssertEqual(trip.teeDate?.ISO8601Format(), "2026-10-18T17:30:00Z")
  }

  @MainActor func testLiveCanadianCourseSearch() async throws {
    guard ProcessInfo.processInfo.environment["WEATHERATLAS_LIVE_COURSES"] == "1" else {
      throw XCTSkip("Opt-in Apple Maps network check")
    }
    let directory = AppleGolfCourseDirectory()
    let courses = try await directory.courses(matching: "Avon Valley")
    XCTAssertFalse(courses.isEmpty)
    XCTAssertTrue(courses.allSatisfy { $0.countryCode == "CA" && $0.isValid })
    XCTAssertTrue(courses.contains { $0.name.localizedCaseInsensitiveContains("Avon Valley") })
    let pin = try await directory.pin(at: course.coordinate)
    XCTAssertEqual(pin.countryCode, "CA")
    XCTAssertEqual(pin.timeZone, "America/Halifax")
    do {
      _ = try await directory.pin(at: .init(latitude: 44.31, longitude: -69.78))
      XCTFail("A United States pin must not be accepted")
    } catch GolfCourseLookupError.outsideCanada {
      // Expected: reverse geocoding, not a rectangular Canada bounding box.
    }
  }

  @MainActor func testOnlyActualRoundIsRequestedAndPendingOrPastNeverCallsAPI() async throws {
    let api = GolfRoundTestAPI()
    let model = GolfModel()
    let value = round()
    await model.load(round: value, limits: GolfLimits(), api: api, now: now)
    let calls = await api.calls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls.first?.days, 1)
    XCTAssertEqual(calls.first?.date, value.localDate)
    XCTAssertEqual(calls.first?.preferences.teeTime, value.teeTime)
    XCTAssertEqual(model.outlook?.days.count, 1)
    XCTAssertNil(model.error)
    await model.load(round: round(days: 40), limits: GolfLimits(), api: api, now: now)
    XCTAssertEqual(model.availability, .pending)
    XCTAssertNil(model.outlook)
    await model.load(round: round(days: -1), limits: GolfLimits(), api: api, now: now)
    XCTAssertEqual(model.availability, .passed)
    let count = await api.calls.count
    XCTAssertEqual(count, 1)
  }

  func testOneRoundEndpointParametersAndRefreshPolicy() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [GolfRoundRequestProbe.self]
    let api = WeatherAPI(
      baseURL: URL(string: "https://golf.test")!,
      session: URLSession(configuration: configuration))
    let value = round()
    let result = try await api.golfOutlook(
      value.preferences(limits: GolfLimits()),
      firstDate: "2026-10-18", days: 1)
    XCTAssertEqual(result.source, "Validated single round")
  }

  @MainActor func testWrongDateAndExtraDaysNeverAppearAsThisRound() async {
    for mode in [GolfRoundTestAPI.Mode.extraDays, .wrongDate] {
      let model = GolfModel()
      await model.load(
        round: round(), limits: GolfLimits(), api: GolfRoundTestAPI(mode: mode), now: now)
      XCTAssertNil(model.outlook)
      XCTAssertNotNil(model.error)
    }
  }

  @MainActor func testLateOldRoundCannotOverwriteEditedRound() async throws {
    let api = GolfRoundTestAPI(mode: .holdFirst)
    let model = GolfModel()
    let first = round()
    let old = Task { await model.load(round: first, limits: GolfLimits(), api: api, now: now) }
    for _ in 0..<100 {
      if await api.calls.count == 1 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let changed = round(hour: 14, id: first.id)
    await model.load(round: changed, limits: GolfLimits(), api: api, now: now)
    XCTAssertEqual(model.outlook?.days.first?.teeTime, changed.teeDate)
    await api.release()
    await old.value
    XCTAssertEqual(model.outlook?.days.first?.teeTime, changed.teeDate)
  }

  @MainActor func testCourseSuggestionsFilterForeignLocationsAndPinRequiresVerification()
    async throws
  {
    let directory = GolfDirectoryTestDouble(course: course)
    let model = GolfCourseSearchModel(directory: directory)
    await model.search("Avon", debounce: .zero)
    XCTAssertEqual(model.results, [course])
    model.choose(course)
    XCTAssertEqual(model.selected, course)
    directory.rejectPin = true
    await model.dropPin(.init(latitude: 44, longitude: -69))
    XCTAssertNil(model.selected)
    XCTAssertNotNil(model.error)
    XCTAssertFalse(model.checkingPin)
    directory.rejectPin = false
    await model.dropPin(course.coordinate)
    XCTAssertEqual(model.selected?.countryCode, "CA")
    XCTAssertEqual(model.selected?.timeZone, "America/Halifax")
    XCTAssertNil(model.error)
  }

  @MainActor func testLateSearchAndPinDoNotReplaceNewSelection() async throws {
    let directory = GolfDirectoryTestDouble(course: course)
    let model = GolfCourseSearchModel(directory: directory)
    directory.hold = true
    let search = Task { await model.search("Avon", debounce: .zero) }
    for _ in 0..<100 where directory.waiting == nil { try await Task.sleep(for: .milliseconds(10)) }
    var chosen = course
    chosen.name = "Another Canadian course"
    model.choose(chosen)
    directory.waiting?.resume()
    directory.waiting = nil
    await search.value
    XCTAssertEqual(model.selected, chosen)
    XCTAssertTrue(model.results.isEmpty)
    let pin = Task { await model.dropPin(course.coordinate) }
    for _ in 0..<100 where directory.waiting == nil { try await Task.sleep(for: .milliseconds(10)) }
    model.choose(chosen)
    directory.waiting?.resume()
    directory.waiting = nil
    await pin.value
    XCTAssertEqual(model.selected, chosen)
  }
}

private final class GolfRoundRequestProbe: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let parameters = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
    let valid =
      request.url?.host == "golf.test" && request.url?.path == "/api/v1/golf/outlook"
      && parameters["days"] == "1" && parameters["local_date"] == "2026-10-18"
      && parameters["tee_time"] == "10:30" && parameters["time_zone"] == "America/Halifax"
      && parameters["latitude"] == "44.98" && parameters["longitude"] == "-64.16"
      && parameters["max_wind_kmh"] == "25.0"
      && request.value(forHTTPHeaderField: "Cache-Control") == "no-cache"
      && request.cachePolicy == .reloadIgnoringLocalCacheData
    let response = HTTPURLResponse(
      url: request.url!, statusCode: valid ? 200 : 400,
      httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(
      self,
      didLoad: Data(
        """
        {"generatedAt":"2026-10-17T12:00:00Z","ruleVersion":"golf-fit-v4",
        "latitude":44.98,"longitude":-64.16,"timeZone":"America/Halifax",
        "source":"Validated single round","limits":{"minTemperatureC":8,"maxTemperatureC":30,
        "maxWindKmh":25,"maxRainMm":1,"maxPopPercent":40},"method":"Test","scoreMeaning":"Test","days":[]}
        """.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

private actor GolfRoundTestAPI: GolfOutlookServing {
  enum Mode { case normal, extraDays, wrongDate, holdFirst }
  struct Call: Sendable {
    let preferences: GolfPreferences
    let date: String
    let days: Int
  }
  let baseURL = URL(string: "https://example.test")!
  var calls: [Call] = []
  let mode: Mode
  private var waiting: CheckedContinuation<Void, Never>?
  init(mode: Mode = .normal) { self.mode = mode }
  func release() {
    waiting?.resume()
    waiting = nil
  }
  func golfOutlook(_ preferences: GolfPreferences, firstDate: String, days: Int) async throws
    -> GolfOutlook
  {
    calls.append(Call(preferences: preferences, date: firstDate, days: days))
    if mode == .holdFirst && calls.count == 1 { await withCheckedContinuation { waiting = $0 } }
    let course = GolfCourse(
      name: preferences.siteName, locality: "NS", latitude: preferences.latitude,
      longitude: preferences.longitude, timeZone: preferences.timeZone, countryCode: "CA",
      kind: .course)
    let round = GolfRound(
      course: course, localDate: firstDate, teeHour: preferences.teeHour,
      teeMinute: preferences.teeMinute)
    let date = round.teeDate!
    let day = GolfDay(
      date: mode == .wrongDate ? "2099-01-01" : firstDate,
      teeTime: date, endTime: date.addingTimeInterval(4 * 3600), state: "within", score: 80,
      rating: "good", scoreCoverage: "complete", probabilityNote: nil, segments: [], reasons: [],
      briefingDetail: "Comfortable weather.", modelRows: [], precipitationIntervals: [],
      regionalPeriods: [], contentID: "fixture")
    return GolfOutlook(
      generatedAt: Date(), ruleVersion: "golf-fit-v4", latitude: preferences.latitude,
      longitude: preferences.longitude, timeZone: preferences.timeZone, source: "Test",
      runTime: Date(),
      limits: preferences.limits, regionalContext: nil, method: "Test", scoreMeaning: "Test",
      days: mode == .extraDays ? [day, day] : [day])
  }
}

@MainActor private final class GolfDirectoryTestDouble: GolfCourseSearching {
  let course: GolfCourse
  var rejectPin = false
  var hold = false
  var waiting: CheckedContinuation<Void, Never>?
  init(course: GolfCourse) { self.course = course }
  func courses(matching query: String) async throws -> [GolfCourse] {
    if hold { await withCheckedContinuation { waiting = $0 } }
    return [
      course,
      GolfCourse(
        name: "US course", locality: "Maine", latitude: 44, longitude: -69,
        timeZone: "America/New_York", countryCode: "US", kind: .course),
    ]
  }
  func pin(at coordinate: CLLocationCoordinate2D) async throws -> GolfCourse {
    if hold { await withCheckedContinuation { waiting = $0 } }
    if rejectPin { throw GolfCourseLookupError.outsideCanada }
    return GolfCourse(
      name: "Golf pin", locality: course.locality, latitude: coordinate.latitude,
      longitude: coordinate.longitude, timeZone: course.timeZone, countryCode: "CA", kind: .pin)
  }
  func cancel() {}
}
