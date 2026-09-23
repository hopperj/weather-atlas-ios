import XCTest

@testable import WeatherAtlas

final class ForecastSummaryTests: XCTestCase {
  func testOnlyCompleteProseIsDisplayed() {
    let complete =
      "Skies clear on Monday night with a low of 12°C. Showers are possible Tuesday, with a high of 18°C."
    XCTAssertEqual(ForecastSummaryOutput.completeParagraph(complete), complete)
    for invalid in [
      "**Near-term outlook:**\n* Monday -> Tuesday: Clearing.\n* Thu Sep 10 06",
      "The forecast starts cloudy and then changes to", complete + "…",
      String(repeating: "Cloudy weather continues. ", count: 50), "Cloudy.",
      "* " + complete,
    ] {
      XCTAssertNil(ForecastSummaryOutput.completeParagraph(invalid))
    }
  }
  private let now = Date(timeIntervalSince1970: 1_788_868_800)  // Fixed clock; no device weather.
  private func region(
    id: String = "halifax", temperature: Double? = 20,
    amount: String? = nil, condition: String = "Cloudy"
  ) -> ForecastRegion {
    ForecastRegion(
      id: id, name: "Halifax", latitude: 44.65, longitude: -63.57,
      province: "NS", provinceName: "Nova Scotia", issuedAt: now.addingTimeInterval(-3600),
      stale: false,
      periods: [
        ForecastPeriod(
          name: "Today", start: now, end: now.addingTimeInterval(43200),
          temperatureC: temperature, temperatureClass: "high", relativeHumidityPercent: nil,
          popPercent: 40, precipitationAmount: amount, condition: condition)
      ])
  }
  private func input(
    _ region: ForecastRegion? = nil, server: String = "http://wolf359.iolan:18080",
    hourly: HourlyForecast? = nil, precipitation: PrecipitationForecast? = nil
  ) -> ForecastSummaryInput {
    ForecastSummaryInput(
      region: region ?? self.region(), hourly: hourly, precipitation: precipitation,
      server: server, now: now, timeZone: TimeZone(secondsFromGMT: 0)!)
  }

  func testInputKeepsMissingAndOriginalUnitsAndDoesNotIncludeCoordinatesOrServer() {
    let result = input(region(temperature: nil, amount: "2–4 cm"))
    XCTAssertTrue(result.prompt.contains("daytime high ?°C"))
    XCTAssertTrue(result.prompt.contains("chance 40%; amount 2–4 cm"))
    XCTAssertFalse(result.prompt.contains("44.65"))
    XCTAssertFalse(result.prompt.contains("wolf359"))
    XCTAssertTrue(result.hasForecast)
  }

  func testWrongRegionAndBulletinAmountsAreExcluded() {
    let wrong = PrecipitationForecast(
      regionId: "elsewhere", issuedAt: now.addingTimeInterval(-3600),
      source: "GDPS", generatedAt: now,
      periods: [
        PrecipitationForecastPeriod(
          start: now,
          end: now.addingTimeInterval(43200), status: "complete", precipitationMm: 999, runTime: now
        )
      ])
    XCTAssertFalse(input(precipitation: wrong).prompt.contains("999"))
    let right = PrecipitationForecast(
      regionId: "halifax", issuedAt: now.addingTimeInterval(-3600),
      source: "GDPS", generatedAt: now, periods: wrong.periods)
    XCTAssertTrue(input(precipitation: right).prompt.contains("999 mm"))
    let outdated = PrecipitationForecast(
      regionId: "halifax", issuedAt: now.addingTimeInterval(-7200),
      source: "GDPS", generatedAt: now, periods: wrong.periods)
    XCTAssertFalse(input(precipitation: outdated).prompt.contains("999"))
  }

  func testCacheIdentityIgnoresPollingButSeparatesForecastAndServer() {
    let first = input()
    let later = ForecastSummaryInput(
      region: region(), hourly: nil, precipitation: nil,
      server: "http://wolf359.iolan:18080", now: now.addingTimeInterval(60),
      timeZone: TimeZone(secondsFromGMT: 0)!)
    XCTAssertEqual(first.id, later.id)
    XCTAssertNotEqual(first.id, input(region(temperature: 25)).id)
    XCTAssertNotEqual(first.id, input(server: "http://other:18080").id)
    XCTAssertNotEqual(first.scope, input(region(id: "sydney")).scope)
  }

  func testWeeklyInputDoesNotIncludeHourlyDetailOrRegenerateForHourlyChanges() {
    let start = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 3600) * 3600)
    func forecast(regionID: String = "halifax", run: Date) -> HourlyForecast {
      HourlyForecast(
        regionId: regionID, source: "GDPS", generatedAt: now, start: start,
        end: start.addingTimeInterval(72 * 3600), availableHours: 1, completeHours: 1,
        hours: [
          HourlyForecastHour(
            time: start, runTime: run,
            precipitationStart: start.addingTimeInterval(-3600), status: "complete",
            temperatureC: 17, relativeHumidityPercent: nil, precipitationMm: 3.7, windKmh: 11,
            gustKmh: 22)
        ])
    }
    XCTAssertFalse(input(hourly: forecast(run: now)).prompt.contains("3.7 mm"))
    XCTAssertEqual(input(hourly: forecast(run: now)).id, input().id)
    for invalid in [
      forecast(regionID: "sydney", run: now), forecast(run: now.addingTimeInterval(-90000)),
      forecast(run: now.addingTimeInterval(3600)),
    ] {
      XCTAssertFalse(input(hourly: invalid).prompt.contains("3.7 mm"))
    }
    let first = input(hourly: forecast(run: now))
    let polled = ForecastSummaryInput(
      region: region(), hourly: forecast(run: now), precipitation: nil,
      server: "http://wolf359.iolan:18080", now: now.addingTimeInterval(1),
      timeZone: TimeZone(secondsFromGMT: 0)!)
    XCTAssertEqual(first.id, polled.id)
  }

  func testPromptIsBoundedForLongUnicodeBulletinsAndExpiredDataIsMarked() {
    let long = region(
      amount: String(repeating: "🌧", count: 1000), condition: String(repeating: "🌦", count: 1000))
    let many = ForecastRegion(
      id: long.id, name: long.name, latitude: long.latitude, longitude: long.longitude,
      province: long.province, provinceName: long.provinceName, issuedAt: long.issuedAt,
      stale: false,
      periods: Array(repeating: long.periods[0], count: 100))
    XCTAssertLessThan(input(many).prompt.utf8.count, 6000)
    let expired = ForecastSummaryInput(
      region: region(), hourly: nil, precipitation: nil,
      server: "http://wolf359.iolan:18080", now: now.addingTimeInterval(86400))
    XCTAssertFalse(expired.hasForecast)
    XCTAssertTrue(expired.isStale)
  }

  @MainActor func testPreparesAutomaticallyAndReusesUnchangedSummary() async {
    let engine = SummaryProbe()
    let model = ForecastSummaryModel(generator: engine)
    let data = input()
    model.prepare(data)
    model.prepare(data)
    await settle()
    XCTAssertEqual(engine.calls, 1)
    XCTAssertEqual(model.text, "A cloudy forecast.")
    model.prepare(data)
    await settle()
    XCTAssertEqual(engine.calls, 1)
    let changed = input(region(temperature: 25))
    model.prepare(changed)
    XCTAssertEqual(model.text, "A cloudy forecast.")
    XCTAssertNotEqual(model.summaryID, changed.id)
    XCTAssertTrue(model.isGenerating)
    await settle()
    XCTAssertEqual(model.summaryID, changed.id)
    XCTAssertEqual(engine.calls, 2, "Only changed bulletin content starts a new summary")
  }

  @MainActor func testLateGenerationCannotReplaceAnotherLocation() async {
    let engine = SummaryProbe(hold: true)
    let model = ForecastSummaryModel(generator: engine)
    model.generate(input())
    await settle()
    XCTAssertTrue(model.isGenerating)
    model.synchronize(input(region(id: "sydney")))
    engine.resume("Wrong location")
    await settle()
    XCTAssertNil(model.text)
    XCTAssertFalse(model.isGenerating)
  }

  @MainActor func testNewForecastReplacesInFlightOldForecast() async {
    let engine = SummaryProbe(hold: true)
    let model = ForecastSummaryModel(generator: engine)
    let original = input()
    model.prepare(original)
    await settle()
    let changed = input(region(temperature: 25))
    model.prepare(changed)
    XCTAssertTrue(model.isGenerating)
    engine.resume("Original dated forecast summary")
    engine.hold = false
    await settle()
    XCTAssertEqual(model.summaryID, changed.id)
    XCTAssertEqual(model.text, "A cloudy forecast.")
    XCTAssertEqual(engine.calls, 2)
  }

  @MainActor func testUnavailableAutomaticSummaryDoesNotRetryOnEveryRefresh() async {
    let engine = SummaryProbe()
    engine.failure = .unavailable("Enable Apple Intelligence")
    let model = ForecastSummaryModel(generator: engine)
    model.prepare(input())
    await settle()
    model.prepare(input())
    await settle()
    XCTAssertEqual(engine.calls, 1)
    engine.failure = nil
    model.retry()
    await settle()
    XCTAssertEqual(engine.calls, 2)
    XCTAssertNotNil(model.text)
  }

  func testBriefingIsExactlyThreeShortSentences() {
    let sentences = [
      "Expect a mix of cloud and sunshine over the coming days.",
      "Showers are possible Tuesday, before drier weather returns later in the week.",
      "Daytime highs reach 18°C, with cooler nights ahead.",
    ]
    XCTAssertEqual(ForecastSummaryOutput.briefing(sentences), sentences.joined(separator: " "))
    XCTAssertNil(ForecastSummaryOutput.briefing(Array(sentences.prefix(2))))
    XCTAssertNil(
      ForecastSummaryOutput.briefing([sentences[0] + " Rain follows.", sentences[1], sentences[2]]))
    XCTAssertNil(
      ForecastSummaryOutput.briefing(["Expect clouds to continue over", sentences[1], sentences[2]])
    )
  }

  func testLocationLabelsPreserveServerIdentityAndHyphenatedTowns() {
    var city = region()
    city.locality = "Halifax"
    XCTAssertEqual(city.displayName, "Halifax")
    XCTAssertEqual(city.id, "halifax")
    XCTAssertEqual(ForecastLocationName.display("Halifax Metro"), "Halifax")
    XCTAssertEqual(
      ForecastLocationName.display("Queens County", locality: "Liverpool"), "Liverpool")
    XCTAssertEqual(
      ForecastLocationName.display("Town of Sainte-Anne-des-Monts"), "Sainte-Anne-des-Monts")
    XCTAssertEqual(ForecastLocationName.display("Unknown County"), "Unknown County")
  }

  func testServerPreparedBriefingReplacesRawTimetableAndExpires() {
    var town = region()
    let prepared = ForecastBriefing(
      overview: "Expect a mix of sunshine and cloud over the coming days.",
      precipitation: "Showers are possible Tuesday, and expected Thursday.",
      temperatures: "Daytime highs range from 18°C to 21°C, with overnight lows of 9°C to 14°C.",
      validUntil: now.addingTimeInterval(3600))
    town.briefing = prepared
    XCTAssertEqual(input(town).briefing, prepared)
    XCTAssertTrue(input(town).prompt.contains(prepared.temperatures))
    XCTAssertFalse(input(town).prompt.contains("amount"))
    let expired = ForecastSummaryInput(
      region: town, hourly: nil, precipitation: nil,
      server: "http://wolf359.iolan:18080", now: now.addingTimeInterval(7200))
    XCTAssertNil(expired.briefing)
    let valid = ForecastSummaryOutput.resolve(
      overall: prepared.overview,
      change: prepared.precipitation, temperatures: prepared.temperatures, briefing: prepared)
    XCTAssertEqual(valid?.text, prepared.paragraph)
    XCTAssertEqual(valid?.isGeneratedOnDevice, true)
    for (overview, timing, temperatures) in [
      (prepared.overview, "Showers will occur Tuesday and Thursday.", prepared.temperatures),
      (prepared.overview, prepared.precipitation, "Highs are in the 18s and lows in the 9s."),
      ("Snow falls throughout the coming week.", prepared.precipitation, prepared.temperatures),
    ] {
      let result = ForecastSummaryOutput.resolve(
        overall: overview, change: timing,
        temperatures: temperatures, briefing: prepared)
      XCTAssertEqual(result?.text, prepared.paragraph)
      XCTAssertEqual(result?.isGeneratedOnDevice, false)
    }
  }

  @MainActor func testExpiredForecastClearsPreviouslyPreparedSummaryWithoutInference() async {
    let engine = SummaryProbe()
    let model = ForecastSummaryModel(generator: engine)
    model.prepare(input())
    await settle()
    let expired = ForecastSummaryInput(
      region: region(), hourly: nil, precipitation: nil,
      server: "http://wolf359.iolan:18080", now: now.addingTimeInterval(86400))
    model.prepare(expired)
    XCTAssertNil(model.text)
    XCTAssertEqual(engine.calls, 1)
    XCTAssertTrue(model.message?.contains("No unexpired forecast") == true)
  }

  @MainActor func testSavedLocationLabelsCanUpdateWithoutChangingSelectionOrCoordinates() {
    let key = "SummaryNames-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: key)!
    defer { defaults.removePersistentDomain(forName: key) }
    let store = AppStore(configuration: .current, defaults: defaults)
    var town = region(id: "test-town")
    store.toggle(town)
    store.selectForecastRegion(town.id)
    town.locality = "Short town name"
    store.updateLocationNames(from: [town])
    XCTAssertEqual(store.saved.first?.name, "Short town name")
    XCTAssertEqual(store.saved.first?.latitude, town.latitude)
    XCTAssertEqual(store.saved.first?.longitude, town.longitude)
    XCTAssertEqual(store.saved.first?.id, town.id)
    XCTAssertEqual(store.selectedRegionID, town.id)
  }

  @MainActor func testTimedOutGenerationCannotPublishLateText() async throws {
    let engine = SummaryProbe(hold: true)
    let model = ForecastSummaryModel(generator: engine, timeout: .milliseconds(10))
    model.generate(input())
    await settle()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(model.isGenerating)
    XCTAssertTrue(model.message?.contains("took too long") == true)
    engine.resume("Late text")
    await settle()
    XCTAssertNil(model.text)
  }

  @MainActor func testCancelAndUnavailableAreRecoverable() async {
    let engine = SummaryProbe(hold: true)
    let model = ForecastSummaryModel(generator: engine)
    let data = input()
    model.generate(data)
    await settle()
    model.cancel()
    engine.resume("Cancelled result")
    await settle()
    XCTAssertNil(model.text)
    engine.hold = false
    engine.failure = .unavailable("Enable Apple Intelligence")
    model.generate(data)
    await settle()
    XCTAssertEqual(model.message, "Enable Apple Intelligence")
    XCTAssertFalse(model.isGenerating)
    engine.failure = nil
    model.generate(data)
    await settle()
    XCTAssertEqual(model.text, "A cloudy forecast.")
    XCTAssertNil(model.message)
  }

  @MainActor func testNativeGeneratorRejectsExpiredForecastWithoutInference() async {
    let data = ForecastSummaryInput(
      region: region(), hourly: nil, precipitation: nil,
      server: "http://wolf359.iolan:18080", now: now.addingTimeInterval(86400))
    do {
      _ = try await NativeForecastSummaryGenerator().summarize(data)
      XCTFail("Expired forecast must not be summarized")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("No unexpired forecast"))
    }
  }

  @MainActor private func settle() async {
    for _ in 0..<12 { await Task.yield() }
  }
}

@MainActor
private final class SummaryProbe: ForecastSummaryGenerating {
  var calls = 0
  var hold: Bool
  var failure: ForecastSummaryError?
  private var continuation: CheckedContinuation<String, Never>?
  init(hold: Bool = false) { self.hold = hold }
  func summarize(_ input: ForecastSummaryInput) async throws -> ForecastSummaryGeneration {
    calls += 1
    if let failure { throw failure }
    if hold {
      return ForecastSummaryGeneration(text: await withCheckedContinuation { continuation = $0 })
    }
    return ForecastSummaryGeneration(text: "A cloudy forecast.")
  }
  func resume(_ text: String) {
    continuation?.resume(returning: text)
    continuation = nil
  }
}

final class ForecastChangesSummaryTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_789_200_000)
  private func region(condition: String = "Rain", temperature: Double = 20) -> ForecastRegion {
    ForecastRegion(
      id: "halifax", name: "Halifax", latitude: 44.65, longitude: -63.57,
      province: "NS", provinceName: "Nova Scotia", issuedAt: now.addingTimeInterval(-3600),
      stale: false,
      periods: [
        ForecastPeriod(
          name: "Today", start: now, end: now.addingTimeInterval(43200),
          temperatureC: temperature, temperatureClass: "high", relativeHumidityPercent: nil,
          popPercent: nil, precipitationAmount: nil, condition: condition)
      ])
  }
  private func bulletin(_ region: ForecastRegion, issued: Date? = nil) -> ForecastChanges.Bulletin {
    .init(
      id: region.id, latitude: region.latitude, longitude: region.longitude,
      issuedAt: issued ?? region.issuedAt, periods: region.periods)
  }
  private func changes(current: ForecastRegion? = nil, previous: ForecastRegion? = nil)
    -> ForecastChanges
  {
    let current = current ?? region()
    let previous = previous ?? region(condition: "Sunny")
    let changed = current.periods[0].condition != previous.periods[0].condition
    return ForecastChanges(
      regionId: "halifax", generatedAt: now, stale: false, groups: [],
      bulletins: .init(
        state: "ready", current: bulletin(current),
        previous: bulletin(
          previous, issued: now.addingTimeInterval(-21600)),
        assessment: changed ? "candidate_changes" : "no_important_changes",
        importantFacts: changed
          ? [
            "Conditions for the shared daytime period: PREVIOUS \(previous.periods[0].condition); CURRENT \(current.periods[0].condition)."
          ] : []))
  }
  private func input(
    _ data: ForecastChanges? = nil, current: ForecastRegion? = nil, at: Date? = nil
  ) -> ForecastSummaryInput {
    .init(
      changes: data ?? changes(), region: current ?? region(), server: "https://weather.test",
      now: at ?? now, timeZone: TimeZone(secondsFromGMT: 0)!)
  }

  func testPassesBothForecastsWithDatesAndPreservesUnknownPoP() {
    let value = input()
    XCTAssertEqual(value.purpose, .changes)
    XCTAssertTrue(value.hasForecast)
    XCTAssertTrue(value.prompt.contains("PREVIOUS FORECAST"))
    XCTAssertTrue(value.prompt.contains("CURRENT FORECAST"))
    XCTAssertTrue(value.prompt.contains("Sunny"))
    XCTAssertTrue(value.prompt.contains("Rain"))
    XCTAssertTrue(value.prompt.contains("PoP unknown%"))
    XCTAssertFalse(value.prompt.contains("Today:"))
    XCTAssertFalse(value.prompt.contains("Wind gusts:"))
    XCTAssertTrue(
      ForecastChangesOutput.instructions.localizedCaseInsensitiveContains(
        "small isolated temperature differences"))
    XCTAssertTrue(ForecastChangesOutput.instructions.contains("minor wind-speed changes"))
  }

  func testCacheIgnoresPollingAndNumericGroupsButIncludesBothForecasts() {
    let original = input()
    XCTAssertEqual(original.id, input(at: now.addingTimeInterval(60)).id)
    XCTAssertNotEqual(original.id, input(changes(previous: region(condition: "Cloudy"))).id)
    XCTAssertNotEqual(
      original.id,
      input(changes(current: region(condition: "Snow")), current: region(condition: "Snow")).id)
    XCTAssertNotEqual(
      original.scope,
      ForecastSummaryInput(
        region: region(), hourly: nil,
        precipitation: nil, server: "https://weather.test", now: now
      ).scope)
  }

  func testMissingHistoryAndWrongOrNewerDisplayedBulletinNeverBecomeNoChange() {
    var missing = changes()
    missing.bulletins = nil
    XCTAssertFalse(input(missing).hasForecast)
    XCTAssertTrue(input(missing).unavailableReason!.contains("server"))
    missing.bulletins = .init(state: "building_history", current: bulletin(region()), previous: nil)
    XCTAssertTrue(input(missing).unavailableReason!.contains("previous forecast"))
    XCTAssertFalse(input(current: region(condition: "Snow")).hasForecast)
    missing.bulletins = .init(state: "location_changed", current: bulletin(region()), previous: nil)
    XCTAssertFalse(input(missing).hasForecast)
    missing.bulletins = .init(
      state: "ready", current: bulletin(region()),
      previous: .init(
        id: "sydney", latitude: 44.65, longitude: -63.57, issuedAt: now, periods: region().periods))
    XCTAssertFalse(input(missing).hasForecast)
  }

  func testExpiredNoOverlapAndOversizedBulletinsAreNotSentToTheModel() {
    XCTAssertFalse(input(at: now.addingTimeInterval(90000)).hasForecast)
    var noOverlap = changes()
    let oldPeriod = ForecastPeriod(
      name: "Yesterday", start: now.addingTimeInterval(-86400),
      end: now.addingTimeInterval(-43200), temperatureC: 20, temperatureClass: "high",
      relativeHumidityPercent: nil, popPercent: nil, precipitationAmount: nil, condition: "Sunny")
    noOverlap.bulletins = .init(
      state: "ready", current: bulletin(region()),
      previous:
        .init(
          id: "halifax", latitude: 44.65, longitude: -63.57,
          issuedAt: now.addingTimeInterval(-86400), periods: [oldPeriod]))
    XCTAssertFalse(input(noOverlap).hasForecast)
    let enormous = region(condition: String(repeating: "🌧", count: 5000))
    let tooLong = input(changes(current: enormous), current: enormous)
    XCTAssertFalse(tooLong.hasForecast)
    XCTAssertTrue(tooLong.unavailableReason!.contains("too long"))
  }

  func testParagraphAcceptsConciseOrNoChangeAndRejectsListsOrInventedNumbers() {
    let data = input()
    XCTAssertEqual(
      ForecastChangesOutput.paragraph(
        [
          "Rain is now expected during the previously sunny period."
        ], input: data),
      "Rain is now expected during the previously sunny period.")
    XCTAssertNotNil(
      ForecastChangesOutput.paragraph(
        [
          "There are no important changes in the overlapping forecast periods."
        ], input: data))
    XCTAssertEqual(
      ForecastChangesOutput.paragraph(
        [
          "Rain is now expected during the previously sunny period.",
          "The previous forecast predicted a high of 20 degrees Celsius, while the current forecast predicts a high of 20 degrees Celsius.",
          "The previous forecast predicted a low of 14 degrees Celsius, while the current forecast predicts a low of 14 degrees Celsius.",
        ], input: data), "Rain is now expected during the previously sunny period.")
    for sentences in [
      ["- Rain is now expected during the previously sunny period."],
      ["Rain is now expected, with 999 mm forecast."],
      ["Rain is now expected, with cooler temperatures."],
      ["Rain is now expected, with strong winds."],
      ["The rain forecast is now changing because"],
      ["The weather is changing. Rain is arriving."],
      ["## Weather changes are expected later today."],
      Array(repeating: "Rain is now expected during the previously sunny period.", count: 4),
    ] {
      XCTAssertNil(ForecastChangesOutput.paragraph(sentences, input: data))
    }
  }

  @MainActor func testChangesAutoPrepareCacheAndResetUseExistingSummaryLifecycle() async {
    let probe = SummaryProbe()
    let model = ForecastSummaryModel(generator: probe)
    model.prepare(input())
    for _ in 0..<30 { await Task.yield() }
    model.prepare(input())
    XCTAssertEqual(probe.calls, 1)
    var noHistory = changes()
    noHistory.bulletins = nil
    model.prepare(input(noHistory))
    XCTAssertNil(model.text)
    XCTAssertTrue(model.message!.contains("server"))
    XCTAssertEqual(probe.calls, 1)
  }

  @MainActor func testNativeImportantAndSmallChanges() async throws {
    guard ProcessInfo.processInfo.environment["WEATHERATLAS_NATIVE_CHANGES"] == "1" else {
      throw XCTSkip("Opt-in native model acceptance on simulator only.")
    }
    #if !targetEnvironment(simulator)
      throw XCTSkip("Never automates a physical phone.")
    #else
      for (label, current, old, expected) in [
        ("wet weather introduced", region(), region(condition: "Sunny"), "rain"),
        (
          "minor temperature adjustment", region(condition: "Sunny", temperature: 21),
          region(condition: "Sunny", temperature: 20), "no important changes"
        ),
        ("rain removed", region(condition: "Sunny"), region(condition: "Rain"), "rain"),
        (
          "identical forecast", region(condition: "Cloudy"), region(condition: "Cloudy"),
          "no important changes"
        ),
      ] {
        let data = input(changes(current: current, previous: old), current: current)
        let result = try await NativeForecastSummaryGenerator().summarize(data)
        let attachment = XCTAttachment(string: result.text)
        attachment.name = label
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains(expected), result.text)
        XCTAssertFalse(result.text.localizedCaseInsensitiveContains("unchanged"), result.text)
        XCTAssertFalse(result.text.contains("20"), result.text)
        XCTAssertFalse(result.text.contains("21"), result.text)
        XCTAssertEqual(result.isGeneratedOnDevice, expected == "rain")
      }
      let possible = region(condition: "Chance of showers")
      let possibleInput = input(changes(current: possible), current: possible)
      let possibleResult = try await NativeForecastSummaryGenerator().summarize(possibleInput)
      XCTAssertTrue(
        ["chance", "possible", "may"].contains {
          possibleResult.text.localizedCaseInsensitiveContains($0)
        }, possibleResult.text)
    #endif
  }

  @MainActor func testNativePairedLiveHalifaxForecast() async throws {
    guard ProcessInfo.processInfo.environment["WEATHERATLAS_NATIVE_CHANGES"] == "1" else {
      throw XCTSkip("Opt-in public-server/native-model acceptance on simulator only.")
    }
    #if !targetEnvironment(simulator)
      throw XCTSkip("Never automates a physical phone.")
    #else
      let api = WeatherAPI(baseURL: WeatherAtlasEndpoint.productionURL)
      let loaded = try await api.halifaxForecast()
      let current = try XCTUnwrap(loaded)
      let revisions = try await api.forecastChanges(areaID: current.id)
      let data = ForecastSummaryInput(
        changes: revisions, region: current,
        server: api.baseURL.absoluteString)
      XCTAssertTrue(data.hasForecast, data.unavailableReason ?? "ready")
      let result = try await NativeForecastSummaryGenerator().summarize(data)
      XCTAssertLessThanOrEqual(result.text.split(whereSeparator: \.isWhitespace).count, 85)
      let attachment = XCTAttachment(string: result.text)
      attachment.name = "Live Halifax important changes"
      attachment.lifetime = .keepAlways
      add(attachment)
    #endif
  }

  @MainActor func testNativeFullWeekWithOneMeaningfulChange() async throws {
    guard ProcessInfo.processInfo.environment["WEATHERATLAS_NATIVE_CHANGES"] == "1" else {
      throw XCTSkip("Opt-in native model acceptance on simulator only.")
    }
    #if !targetEnvironment(simulator)
      throw XCTSkip("Never automates a physical phone.")
    #else
      let initial = region()
      let periods = [
        "Periods of rain.", "Partly cloudy.", "Cloudy.", "Clear.",
        "Snow.", "Rain mixed with snow.", "Chance of thunderstorms.",
      ].enumerated().map { i, condition in
        ForecastPeriod(
          name: "Period \(i)", start: now.addingTimeInterval(Double(i) * 43200),
          end: now.addingTimeInterval(Double(i + 1) * 43200), temperatureC: i % 2 == 0 ? 22 : 14,
          temperatureClass: i % 2 == 0 ? "high" : "low", relativeHumidityPercent: nil,
          popPercent: i == 3 ? 0 : 30, precipitationAmount: i == 0 ? "5 to 10 mm" : nil,
          condition: condition)
      }
      let current = ForecastRegion(
        id: initial.id, name: initial.name,
        latitude: initial.latitude, longitude: initial.longitude, province: initial.province,
        provinceName: initial.provinceName, issuedAt: initial.issuedAt, stale: false,
        periods: periods)
      let first = periods[0]
      let previousPeriods =
        [
          ForecastPeriod(
            name: first.name, start: first.start, end: first.end,
            temperatureC: first.temperatureC, temperatureClass: first.temperatureClass,
            relativeHumidityPercent: nil, popPercent: first.popPercent, precipitationAmount: nil,
            condition: "Sunny.")
        ] + periods.dropFirst()
      var pair = changes(current: current)
      pair.bulletins?.importantFacts = [
        "Conditions for the first daytime period: PREVIOUS Sunny; CURRENT Periods of rain."
      ]
      pair.bulletins = .init(
        state: "ready", current: bulletin(current),
        previous: .init(
          id: current.id, latitude: current.latitude, longitude: current.longitude,
          issuedAt: now.addingTimeInterval(-21600), periods: previousPeriods),
        assessment: "candidate_changes", importantFacts: pair.bulletins?.importantFacts)
      let result = try await NativeForecastSummaryGenerator().summarize(
        input(pair, current: current))
      XCTAssertTrue(result.text.localizedCaseInsensitiveContains("rain"), result.text)
      XCTAssertFalse(result.text.localizedCaseInsensitiveContains("snow"), result.text)
      XCTAssertFalse(result.text.localizedCaseInsensitiveContains("temperature"), result.text)
    #endif
  }

  @MainActor func testNativeUITestFixturePair() async throws {
    guard ProcessInfo.processInfo.environment["WEATHERATLAS_NATIVE_FIXTURES"] == "1" else {
      throw XCTSkip("Requires opt-in and the loopback UI fixture server.")
    }
    #if !targetEnvironment(simulator)
      throw XCTSkip("Never automates a physical phone.")
    #else
      let api = WeatherAPI(baseURL: URL(string: "http://localhost:8097")!)
      let regions = try await api.forecastRegions()
      let region = try XCTUnwrap(regions.regions.first { $0.id == "0123456789abcdef" })
      let pair = try await api.forecastChanges(areaID: region.id)
      let data = ForecastSummaryInput(
        changes: pair, region: region, server: api.baseURL.absoluteString)
      XCTAssertTrue(data.hasForecast, data.unavailableReason ?? "ready")
      let result = try await NativeForecastSummaryGenerator().summarize(data)
      XCTAssertTrue(result.text.localizedCaseInsensitiveContains("rain"), result.text)
    #endif
  }
}
