import XCTest

@testable import WeatherAtlas

final class CurrentForecastPrecipitationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_792_410_000)  // 2026-10-19 11:40 UTC
  private var start: Date {
    Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 3600) * 3600)
  }
  private func region(pop: Double? = nil, stale: Bool = false) -> ForecastRegion {
    ForecastRegion(
      id: "test", name: "Kentville", latitude: 45.08, longitude: -64.5,
      province: "NS", provinceName: "Nova Scotia", issuedAt: start, stale: stale,
      periods: [
        ForecastPeriod(
          name: "Today", start: start.addingTimeInterval(-3600),
          end: start.addingTimeInterval(6 * 3600), temperatureC: 14, temperatureClass: "high",
          relativeHumidityPercent: 70, popPercent: pop, precipitationAmount: "5 to 10 mm",
          condition: "Rain")
      ])
  }
  private func official(
    pop: Double? = 60, offset: Int = 1, regionID: String = "test", stale: Bool = false
  ) -> OfficialHourlyForecast {
    OfficialHourlyForecast(
      regionId: regionID, source: "ECCC official hourly forecast", generatedAt: now,
      issuedAt: start, providerLocation: "Kentville", timeZone: "AST4ADT", stale: stale,
      hours: (offset..<(offset + 24)).map { i in
        OfficialForecastHour(
          time: start.addingTimeInterval(Double(i) * 3600), condition: "Sunny",
          popPercent: pop, temperatureC: 14, iconCode: "00")
      })
  }
  private func model(
    amount: Double? = 1.2, regionID: String = "test", offset: Int = 0, missing: Set<Int> = []
  ) -> HourlyForecast {
    HourlyForecast(
      regionId: regionID, source: "GDPS", generatedAt: now, start: start,
      end: start.addingTimeInterval(72 * 3600), availableHours: 72, completeHours: 72,
      hours: (offset..<72).map { i in
        let time = start.addingTimeInterval(Double(i) * 3600)
        return HourlyForecastHour(
          time: time, runTime: start.addingTimeInterval(-6 * 3600),
          precipitationStart: time.addingTimeInterval(-3600),
          status: missing.contains(i) ? "missing" : "complete",
          temperatureC: missing.contains(i) ? nil : 14, relativeHumidityPercent: nil,
          precipitationMm: missing.contains(i) ? nil : amount, windKmh: nil, gustKmh: nil)
      })
  }
  private func observation(amount: Double? = 2.3, trace: Bool = false, stale: Bool = false)
    -> WeatherStation
  {
    WeatherStation(
      id: "station", name: "Nearby station", longitude: -64.5, latitude: 45.08,
      elevationM: nil, source: "MSC", attribution: "ECCC", distanceKm: 2, stale: stale,
      observation: WeatherStation.Observation(
        observedAt: start, expiresAt: start.addingTimeInterval(7200),
        expectedIntervalMinutes: 60, values: ["precipitationMm": amount],
        quality: [
          "precipitationMm": .init(
            state: trace ? "trace" : "reported", sourceField: "pcpn_amt_pst1hr", unit: "mm")
        ],
        intervals: ["precipitationMm": .init(start: start.addingTimeInterval(-3600), end: start)]))
  }

  func testStartsAtFirstOfficialHourKeepsAll24AndDoesNotReuseModelNow() {
    let official = official()
    let rows = ForecastHourPresentation.upcoming(
      regionID: "test", model: model(), official: official, at: now)
    XCTAssertEqual(rows.count, 24)
    XCTAssertEqual(rows.first?.time, official.hours.first?.time)
    XCTAssertEqual(rows.last?.time, official.hours.last?.time)
    XCTAssertGreaterThan(rows[0].time, now)
    XCTAssertTrue(rows.allSatisfy { $0.condition == "Sunny" && $0.weatherIcon == .clearDay })
    XCTAssertEqual(rows.first?.modelPrecipitation, "1.2 mm")
  }

  func testModelOnlySkipsLeadingMissingHoursButRetainsAnInteriorGap() {
    let rows = ForecastHourPresentation.upcoming(
      regionID: "test", model: model(missing: [0, 1, 3]), official: nil, at: now)
    XCTAssertEqual(rows.first?.time, start.addingTimeInterval(7200))
    XCTAssertEqual(rows[1].model?.status, "missing")
    XCTAssertNil(rows[1].model?.precipitationMm)
    XCTAssertEqual(rows[2].time, start.addingTimeInterval(4 * 3600))
    XCTAssertTrue(
      ForecastHourPresentation.upcoming(
        regionID: "test", model: model(missing: Set(0..<72)), official: nil, at: now
      ).isEmpty)
  }

  func testStartsAtFirstOfficialHourEvenWithoutModelAndRejectsExpiredOrWrongRegion() {
    let forecast = official()
    let rows = ForecastHourPresentation.upcoming(
      regionID: "test", model: nil, official: forecast, at: now)
    XCTAssertEqual(rows.count, 24)
    XCTAssertEqual(rows.first?.time, forecast.hours.first?.time)
    XCTAssertTrue(
      ForecastHourPresentation.upcoming(
        regionID: "test", model: nil, official: official(stale: true), at: now
      ).isEmpty)
    XCTAssertTrue(
      ForecastHourPresentation.upcoming(
        regionID: "test", model: nil, official: official(regionID: "other"), at: now
      ).isEmpty)
  }

  func testHeaderUsesOfficialPOPAndZeroDoesNotReviveBroaderRegionalRisk() {
    let wet = CurrentForecastPrecipitation(
      region: region(pop: 80), model: nil, official: official(), observation: nil, at: now)
    XCTAssertEqual(wet.probability?.percent, 60)
    XCTAssertEqual(wet.probability?.hour, start.addingTimeInterval(3600))
    XCTAssertNil(wet.amount, "A regional-period total is not an hourly precipitation amount")
    XCTAssertTrue(wet.amountIsUncertain)
    let dry = CurrentForecastPrecipitation(
      region: region(pop: 80), model: nil, official: official(pop: 0), observation: nil, at: now)
    XCTAssertTrue(dry.isEmpty)
    XCTAssertFalse(dry.amountIsUncertain)
    let regional = CurrentForecastPrecipitation(
      region: region(pop: 30), model: nil, official: nil, observation: nil, at: now)
    XCTAssertEqual(regional.probability?.percent, 30)
    XCTAssertNil(regional.probability?.hour)
  }

  func testHeaderPrefersPositiveObservationAndRetainsItsInterval() {
    let result = CurrentForecastPrecipitation(
      region: region(), model: model(), official: nil, observation: observation(), at: now)
    XCTAssertEqual(result.amount?.source, .observation)
    XCTAssertEqual(result.amount?.displayValue, "2.3 mm")
    XCTAssertFalse(result.amountIsUncertain)
    XCTAssertEqual(result.amount?.start, start.addingTimeInterval(-3600))
    XCTAssertEqual(result.amount?.end, start)
    let trace = CurrentForecastPrecipitation(
      region: region(), model: model(), official: nil,
      observation: observation(amount: nil, trace: true), at: now)
    XCTAssertEqual(trace.amount?.displayValue, "Trace")
    XCTAssertEqual(trace.amount?.source, .observation)
  }

  func testPositivePOPWithZeroOrMissingAmountDoesNotInventMillimetres() {
    for amount in [Optional<Double>.none, 0, -1, .nan, .infinity] {
      let result = CurrentForecastPrecipitation(
        region: region(), model: model(amount: amount), official: official(pop: 30),
        observation: nil, at: now)
      XCTAssertEqual(result.probability?.percent, 30)
      XCTAssertNil(result.amount)
      XCTAssertTrue(result.amountIsUncertain)
    }
    let rows = ForecastHourPresentation.upcoming(
      regionID: "test", model: model(amount: 0), official: official(pop: 30), at: now)
    XCTAssertTrue(rows.allSatisfy { $0.modelPrecipitation == "Amount uncertain" })
    XCTAssertTrue(rows.allSatisfy { $0.model?.precipitationMm == 0 })
  }

  func testHeaderFallsBackToTheContainingModelHourAndLabelsTraceAmountsHonestly() {
    for (value, display) in [(1.2, "1.2 mm"), (0.04, "<0.1 mm")] {
      let result = CurrentForecastPrecipitation(
        region: region(), model: model(amount: value), official: nil,
        observation: observation(amount: 0), at: now)
      XCTAssertEqual(result.amount?.source, .model)
      XCTAssertEqual(result.amount?.displayValue, display)
      XCTAssertEqual(result.amount?.start, start)
      XCTAssertEqual(result.amount?.end, start.addingTimeInterval(3600))
    }
    let staleObservation = CurrentForecastPrecipitation(
      region: region(), model: model(), official: nil, observation: observation(stale: true),
      at: now)
    XCTAssertEqual(staleObservation.amount?.source, .model)
  }

  func testMissingZeroAndUnrelatedFutureValuesDoNotCreateHeaderBadges() {
    for amount in [Optional<Double>.none, 0, -1, .nan] {
      let result = CurrentForecastPrecipitation(
        region: region(), model: model(amount: amount), official: official(pop: 0),
        observation: nil, at: now)
      XCTAssertTrue(result.isEmpty)
    }
    let future = CurrentForecastPrecipitation(
      region: region(), model: model(offset: 3), official: official(offset: 3), observation: nil,
      at: now)
    XCTAssertTrue(
      future.isEmpty, "Do not silently present a later future hour as current precipitation")
    let wrong = CurrentForecastPrecipitation(
      region: region(), model: model(regionID: "other"), official: official(regionID: "other"),
      observation: nil, at: now)
    XCTAssertTrue(wrong.isEmpty)
    let stale = CurrentForecastPrecipitation(
      region: region(pop: 50, stale: true), model: nil, official: official(stale: true),
      observation: observation(stale: true), at: now)
    XCTAssertTrue(stale.isEmpty)
  }
}
