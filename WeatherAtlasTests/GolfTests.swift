import XCTest

@testable import WeatherAtlas

final class GolfTests: XCTestCase {
  @MainActor func testNoDescriptionUntilResponseFinishesIncludingQueuedCancelledAndChangedData()
    async throws
  {
    let outlook = try fixture()
    let day = outlook.days[0]
    let input = ForecastSummaryInput(golf: day, outlook: outlook, server: "test")
    let gate = GolfDescriptionGate()
    let model = ForecastSummaryModel(generator: gate)
    func displayed() -> GolfDescription? {
      GolfDescription.completed(day: day, input: input, narrative: model)
    }
    XCTAssertNil(displayed())  // Queued, not started.
    model.synchronize(input)
    XCTAssertNil(displayed())
    model.prepare(input)
    XCTAssertTrue(model.isGenerating)
    XCTAssertNil(displayed())
    model.cancel()
    XCTAssertNil(displayed())  // Cancellation is not a terminal fallback.
    model.prepare(input)
    XCTAssertNil(displayed())
    gate.release()
    for _ in 0..<100 where model.isGenerating { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertFalse(model.isGenerating)
    XCTAssertEqual(displayed()?.text, "Completed analysis, not the default description.")
    XCTAssertTrue(try XCTUnwrap(displayed()).isGeneratedOnDevice)
    let changed = try fixture(state: "outside", score: 30)
    let changedInput = ForecastSummaryInput(golf: changed.days[0], outlook: changed, server: "test")
    XCTAssertNil(
      GolfDescription.completed(day: changed.days[0], input: changedInput, narrative: model))
    model.synchronize(changedInput)
    XCTAssertNil(
      GolfDescription.completed(day: changed.days[0], input: changedInput, narrative: model))
  }

  @MainActor func testFallbackOnlyAfterTerminalFailureAndNotWhileRetrying() async throws {
    let outlook = try fixture(state: "partial", score: 70)
    let day = outlook.days[0]
    let input = ForecastSummaryInput(golf: day, outlook: outlook, server: "test")
    let gate = GolfDescriptionGate(failing: true)
    let model = ForecastSummaryModel(generator: gate)
    model.prepare(input)
    XCTAssertNil(GolfDescription.completed(day: day, input: input, narrative: model))
    gate.release()
    for _ in 0..<100 where model.isGenerating { try await Task.sleep(for: .milliseconds(10)) }
    let fallback = try XCTUnwrap(
      GolfDescription.completed(day: day, input: input, narrative: model))
    XCTAssertEqual(fallback.text, day.fallbackSummary)
    XCTAssertFalse(fallback.isGeneratedOnDevice)
    XCTAssertNotNil(fallback.note)
    let changed = try fixture(state: "outside", score: 30)
    let changedInput = ForecastSummaryInput(golf: changed.days[0], outlook: changed, server: "test")
    model.synchronize(changedInput)
    XCTAssertNil(
      GolfDescription.completed(day: changed.days[0], input: changedInput, narrative: model))
    model.synchronize(input)
    model.retry()
    XCTAssertNil(GolfDescription.completed(day: day, input: input, narrative: model))
    model.cancel()
  }

  func testUnpublishedProbabilityKeepsRainAssessmentWithoutDisclaimer() throws {
    let outlook = try fixture(score: 70, unpublishedPop: true)
    let day = outlook.days[0]
    let input = GolfNarrativeInput(day: day, outlook: outlook)
    XCTAssertEqual(day.status, "Within your limits")
    XCTAssertNotNil(day.score)
    XCTAssertTrue(day.segments.allSatisfy { $0.popPercent == nil })
    XCTAssertEqual(day.round?.rain?.maximumMm, 0.5)
    XCTAssertFalse(input.opening.contains("prevents a full assessment"))
    XCTAssertFalse(input.prompt.contains("could not be fully checked"))
    XCTAssertFalse(input.prompt.contains("pop = unknown"))
    XCTAssertFalse(input.fallback.contains("unavailable"))
    XCTAssertNotNil(
      input.validated(
        score: 70,
        paragraph: input.opening
          + " Temperature and wind stay within your preferences before and after the round."))
    XCTAssertNil(
      input.validated(
        score: 70,
        paragraph:
          "The forecast meets all your limits. Rain chance is within your threshold before and after the round."
      ))
    for disclaimer in [
      "The forecast fits your preferences, though regional rain likelihood cannot be fully assessed due to missing data.",
      "Regional rain liklihood cannot be fully assessed due to missing data.",
      "Rain probability is unavailable, limiting the assessment.",
      "The forecast fits your preferences, but rain chance is not provided.",
      "Missing weather data prevents a full assessment.",
    ] {
      XCTAssertNil(input.validated(score: 70, paragraph: disclaimer), disclaimer)
    }
  }

  func testLegacyPartialResponseDoesNotReintroduceWarning() throws {
    let outlook = try fixture(state: "partial", score: 70)
    let input = GolfNarrativeInput(day: outlook.days[0], outlook: outlook)
    XCTAssertNotNil(outlook.days[0].probabilityNote)  // Old server payload remains decodable.
    XCTAssertEqual(input.state, "within")
    XCTAssertEqual(outlook.days[0].status, "Within your limits")
    XCTAssertFalse(input.prompt.contains("could not be fully checked"))
    XCTAssertFalse(input.fallback.contains("unavailable"))
  }

  @MainActor func testPreferencesPersistAndRejectInvalidWithoutChangingForecastSettings() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "GolfTests-\(UUID())"))
    defaults.set("other-region", forKey: "forecastRegion:example")
    let store = GolfSettingsStore(defaults: defaults)
    XCTAssertEqual(store.value.siteName, "Halifax")
    var next = store.value
    next.latitude = 44.612345
    next.longitude = -63.512345
    next.siteName = "My course"
    next.teeHour = 23
    next.teeMinute = 45
    next.timeZone = "America/Halifax"
    next.limits.maxPopPercent = 20
    store.save(next)
    XCTAssertEqual(GolfSettingsStore(defaults: defaults).value, next)
    XCTAssertEqual(store.value.teeTime, "23:45")
    XCTAssertEqual(defaults.string(forKey: "forecastRegion:example"), "other-region")
    var invalid = next
    invalid.limits.minTemperatureC = 40
    store.save(invalid)
    XCTAssertEqual(store.value, next)
    invalid = next
    invalid.latitude = .nan
    XCTAssertFalse(invalid.isValid)
    invalid = next
    invalid.timeZone = "invalid"
    XCTAssertFalse(invalid.isValid)
    defaults.set(Data("{}".utf8), forKey: "golfPreferences:v1")
    XCTAssertEqual(GolfSettingsStore(defaults: defaults).value.siteName, "Halifax")
  }

  func testPromptContainsRawForecastAndAllWindowsAndHonestScoreMeaning() throws {
    let outlook = try fixture()
    let input = ForecastSummaryInput(
      golf: outlook.days[0], outlook: outlook, server: "https://test.example")
    XCTAssertTrue(input.hasForecast)
    for token in [
      "Before", "Round", "After", "modelRows", "precipitationIntervals", "regionalPeriods",
      "maxPopPercent", "maxRainMm", "NOT a probability", "unknown, not zero",
    ] {
      XCTAssertTrue(input.prompt.contains(token), token)
    }
    XCTAssertLessThan(input.prompt.utf8.count, 10500)
    let other = ForecastSummaryInput(
      golf: outlook.days[0], outlook: outlook, server: "https://other.example")
    XCTAssertNotEqual(input.id, other.id)
    XCTAssertEqual(
      input.id,
      ForecastSummaryInput(golf: outlook.days[0], outlook: outlook, server: "https://test.example")
        .id)
  }

  func testLLMDoesNotInventScoreNumbersOrNewHazards() throws {
    let outlook = try fixture()
    let input = GolfNarrativeInput(day: outlook.days[0], outlook: outlook)
    let valid =
      "The forecast fits your temperature and wind limits during the round. Conditions before and afterward also stay within your preferences."
    XCTAssertEqual(input.validated(score: 80, paragraph: valid), valid)
    XCTAssertNil(input.validated(score: 90, paragraph: valid))
    XCTAssertNil(input.validated(score: nil, paragraph: valid))
    XCTAssertNil(
      input.validated(
        score: 80,
        paragraph:
          "It will be safe to play your round. The course will be open and conditions will be comfortable."
      ))
    XCTAssertNil(
      input.validated(
        score: 80,
        paragraph:
          "Expect snow before the round begins. Conditions during and after the round meet your weather preferences."
      ))
    XCTAssertNil(
      input.validated(
        score: 80,
        paragraph:
          "There is an 80% chance of finishing the round. The weather will be good for golf all afternoon."
      ))
    let missing = try fixture(state: "incomplete", score: nil)
    let missingInput = GolfNarrativeInput(day: missing.days[0], outlook: missing)
    XCTAssertNil(missingInput.validated(score: nil, paragraph: valid))
    XCTAssertNil(
      missingInput.validated(
        score: nil,
        paragraph:
          "The round fits the limits, but rain data is missing. The before and after windows do not change the assessment."
      ))
    XCTAssertNotNil(missingInput.validated(score: nil, paragraph: missing.days[0].fallbackSummary))
    XCTAssertNil(missing.days[0].score)
  }

  func testPastAndStaleDaysNeverAskLLMForOutlook() throws {
    for state in ["started", "stale", "invalid_time"] {
      let outlook = try fixture(state: state, score: nil)
      XCTAssertFalse(
        ForecastSummaryInput(golf: outlook.days[0], outlook: outlook, server: "test").hasForecast)
    }
  }

  @MainActor func testNativeGolfDescriptions() async throws {
    guard ProcessInfo.processInfo.environment["WEATHERATLAS_NATIVE_GOLF"] == "1" else {
      throw XCTSkip("Opt-in simulator native-model acceptance.")
    }
    #if targetEnvironment(simulator)
      for (state, score, unpublishedPop) in [
        ("within", Optional(80), false), ("outside", Optional(30), false),
        ("incomplete", nil, false),
        ("within", Optional(70), true), ("partial", Optional(70), true),
      ] {
        let outlook = try fixture(state: state, score: score, unpublishedPop: unpublishedPop)
        let input = ForecastSummaryInput(golf: outlook.days[0], outlook: outlook, server: "test")
        let result = try await NativeForecastSummaryGenerator().summarize(input)
        let attachment = XCTAttachment(string: result.text)
        attachment.name = "Golf \(state) unpublished PoP \(unpublishedPop)"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(result.isGeneratedOnDevice, result.text)
        XCTAssertNotNil(input.golf?.validated(score: score, paragraph: result.text))
      }
    #else
      throw XCTSkip("No physical phone automation.")
    #endif
  }

  @MainActor func testLiveGolfForecastAndNativeExplanation() async throws {
    guard ProcessInfo.processInfo.environment["WEATHERATLAS_LIVE_GOLF"] == "1" else {
      throw XCTSkip("Opt-in public endpoint and on-device model check on simulator only.")
    }
    #if targetEnvironment(simulator)
      var preferences = GolfPreferences()
      preferences.timeZone = "America/Halifax"
      let formatter = DateFormatter()
      formatter.timeZone = TimeZone(identifier: preferences.timeZone)
      formatter.dateFormat = "yyyy-MM-dd"
      let api = WeatherAPI(baseURL: WeatherAtlasEndpoint.productionURL)
      let outlook = try await api.golfOutlook(
        preferences, firstDate: formatter.string(from: Date().addingTimeInterval(86400)))
      XCTAssertEqual(outlook.days.count, 7)
      XCTAssertEqual(outlook.latitude, preferences.latitude)
      XCTAssertNotNil(outlook.runTime)
      for day in outlook.days.prefix(2) {
        let input = ForecastSummaryInput(
          golf: day, outlook: outlook, server: api.baseURL.absoluteString)
        XCTAssertTrue(input.hasForecast, "\(day.state), \(input.prompt.utf8.count) bytes")
        let result = try await NativeForecastSummaryGenerator().summarize(input)
        let attachment = XCTAttachment(
          string: "\(day.date) · \(day.state) · \(String(describing: day.score))\n\(result.text)")
        attachment.name = "Live golf explanation"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(result.isGeneratedOnDevice, result.text)
        XCTAssertNotNil(input.golf?.validated(score: day.score, paragraph: result.text))
      }
    #else
      throw XCTSkip("No physical phone automation.")
    #endif
  }

  private func fixture(state: String = "within", score: Int? = 80, unpublishedPop: Bool = false)
    throws -> GolfOutlook
  {
    let now = Date()
    let tee = now.addingTimeInterval(24 * 3600)
    let formatter = ISO8601DateFormatter()
    func date(_ hours: Double) -> String {
      formatter.string(from: tee.addingTimeInterval(hours * 3600))
    }
    let wind = state == "outside" ? 40 : 10
    let noPop = unpublishedPop || ["incomplete", "partial"].contains(state)
    let pop: Any = noPop ? NSNull() : 10
    let segments: [[String: Any]] = [
      ("Before", -2.0, 0.0), ("Round", 0.0, 4.0), ("After", 4.0, 5.0),
    ].map { name, start, end in
      [
        "name": name, "start": date(start), "end": date(end), "temperatureRangeC": [18, 20],
        "maxWindKmh": state == "incomplete" ? NSNull() : wind as Any,
        "maxGustKmh": wind + 10, "popPercent": pop,
        "rain": [
          "minimumMm": 0.125 * (end - start), "maximumMm": 0.125 * (end - start),
          "coverStart": date(start), "coverEnd": date(end),
        ],
        "rainTimingUncertain": false,
        "checks": ["temperature", "wind", "rain", "pop"].map { field in
          [
            "field": field, "label": field,
            "state": field == "wind" && state == "outside"
              ? "outside"
              : field == "pop" && noPop
                ? "not_provided"
                : field == "wind" && state == "incomplete" ? "unknown" : "within",
            "fit": (field == "pop" && noPop) || (field == "wind" && state == "incomplete")
              ? NSNull() : 80 as Any,
          ] as [String: Any]
        },
      ]
    }
    let day: [String: Any] = [
      "date": "2099-09-16", "teeTime": date(0), "endTime": date(4), "state": state,
      "score": score as Any? ?? NSNull(), "segments": segments, "reasons": [], "contentID": state,
      "scoreCoverage": state == "partial" ? "partial" : score == nil ? "none" : "complete",
      "probabilityNote": state == "partial"
        ? "Your rain-chance limit could not be fully checked because a percentage is unavailable."
        : NSNull(),
      "briefingDetail": state == "outside"
        ? "Sustained wind falls outside your limits before, during and after the round."
        : state == "incomplete"
          ? "Sustained wind cannot be fully assessed before, during and after the round."
          : "Forecast precipitation stays within your chosen amount, with temperature and wind also within your preferences before, during and after the round.",
      "modelRows": (-2...5).map {
        [
          "time": date(Double($0)), "temperatureC": 20,
          "windKmh": state == "incomplete" ? NSNull() : wind as Any, "gustKmh": wind + 10,
        ]
          as [String: Any]
      },
      "precipitationIntervals": (-1...5).map {
        [
          "start": date(Double($0 - 1)), "end": date(Double($0)), "field": "total_precipitation_1h",
          "mm": 0.125,
        ] as [String: Any]
      },
      "regionalPeriods": [
        [
          "name": "Day", "start": date(-6), "end": date(6), "temperatureC": 20,
          "temperatureClass": "high", "popPercent": pop, "condition": "Rain",
        ]
      ],
    ]
    let object: [String: Any] = [
      "generatedAt": formatter.string(from: now), "ruleVersion": "golf-fit-v3",
      "latitude": 44.65, "longitude": -63.57, "timeZone": "America/Halifax", "source": "ECCC GDPS",
      "runTime": formatter.string(from: now),
      "limits": [
        "minTemperatureC": 8, "maxTemperatureC": 30, "maxWindKmh": 25, "maxRainMm": 1,
        "maxPopPercent": 40,
      ],
      "regionalContext": [
        "name": "Halifax", "distanceKm": 2, "issuedAt": formatter.string(from: now), "stale": false,
      ],
      "method": "Model-grid point sample", "scoreMeaning": "Weather fit, not a probability",
      "days": [day],
    ]
    return try WeatherAPI.decoder().decode(
      GolfOutlook.self, from: JSONSerialization.data(withJSONObject: object))
  }
}

@MainActor private final class GolfDescriptionGate: ForecastSummaryGenerating {
  private var released = false
  private let failing: Bool
  init(failing: Bool = false) { self.failing = failing }
  func release() { released = true }
  func summarize(_ input: ForecastSummaryInput) async throws -> ForecastSummaryGeneration {
    while !released { try await Task.sleep(for: .milliseconds(5)) }
    try Task.checkCancellation()
    if failing { throw ForecastSummaryError.unavailable("On-device model unavailable.") }
    return ForecastSummaryGeneration(text: "Completed analysis, not the default description.")
  }
}
