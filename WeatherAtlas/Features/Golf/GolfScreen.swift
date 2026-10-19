import CoreLocation
import SwiftUI

struct GolfScreen: View {
  @ObservedObject var settings: GolfSettingsStore
  @EnvironmentObject private var store: AppStore
  @Environment(\.scenePhase) private var scenePhase
  @State private var refresh = 0
  @State private var editor: GolfRoundEditorRoute?
  private var enabled: Bool { scenePhase == .active && store.selectedTab == 4 }
  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 10) {
            Label("Your next rounds", systemImage: "flag.fill").font(.title2.bold())
            Text(
              "Your tee times and course forecasts, all in one place."
            )
            .font(.subheadline).foregroundStyle(.secondary)
            Button {
              editor = GolfRoundEditorRoute()
            } label: {
              Label("Add tee time", systemImage: "plus")
                .frame(maxWidth: .infinity).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent).accessibilityIdentifier("golfAddRound")
          }.padding().background(
            Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
          let upcoming = settings.rounds.filter { $0.availability() != .passed }
          if upcoming.isEmpty {
            ContentUnavailableView(
              "No upcoming tee times", systemImage: "calendar.badge.plus",
              description: Text("Find a Canadian course or drop a pin to plan your first round.")
            )
            .accessibilityIdentifier("golfEmptyRounds")
          }
          ForEach(upcoming) { round in
            roundCard(round)
          }
          let past = settings.rounds.filter { $0.availability() == .passed }
          if !past.isEmpty {
            DisclosureGroup("Past tee times (\(past.count))") {
              VStack(spacing: 16) {
                ForEach(past.reversed()) { round in roundCard(round) }
              }.padding(.top, 12)
            }
          }
          Text("Saved on this device · weather planning only, not a course booking.")
            .font(.caption).foregroundStyle(.secondary)
        }.padding()
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle("Golf")
      .navigationBarTitleDisplayMode(.inline)
      .refreshable { refresh += 1 }
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          NavigationLink {
            GolfSettingsScreen(settings: settings)
          } label: {
            Label("Weather limits", systemImage: "slider.horizontal.3")
          }.accessibilityIdentifier("golfLimitsLink")
        }
      }
      .sheet(item: $editor) { route in GolfRoundEditor(settings: settings, route: route) }
    }
  }
  private func roundCard(_ round: GolfRound) -> some View {
    GolfSavedRoundCard(
      round: round, settings: settings, enabled: enabled,
      refreshID: "\(refresh)|\(store.forecastRefresh)"
    ) {
      editor = GolfRoundEditorRoute(round: round)
    }
  }
}

private struct GolfSavedRoundCard: View {
  let round: GolfRound
  @ObservedObject var settings: GolfSettingsStore
  let enabled: Bool
  let refreshID: String
  let onEdit: () -> Void
  @EnvironmentObject private var store: AppStore
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @StateObject private var model = GolfModel()
  private var day: GolfDay? {
    model.currentOutlook(for: round, limits: settings.value.limits)?.days.first
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 5) {
          Text(round.course.name).font(.headline).fixedSize(horizontal: false, vertical: true)
          Text(round.course.locality).font(.caption).foregroundStyle(.secondary)
          if let date = round.teeDate {
            Text(golfDate(date, zone: round.course.zone, pattern: "EEE, MMM d · HH:mm z"))
              .font(.subheadline.weight(.medium))
          }
        }
        Spacer(minLength: 0)
        if let rating = day?.outlookRating {
          VStack(spacing: 2) {
            GolfMoodIcon(rating: rating, issue: day?.outlookIssue).frame(width: 60, height: 60)
            Text(rating.label).font(.caption.bold()).foregroundStyle(rating.colour)
          }
        }
      }
      if let day {
        if let issue = day.outlookIssue {
          Text("Main drawback: \(issue.label)").font(.caption).foregroundStyle(.secondary)
        }
        if let part = day.round {
          let columns = dynamicTypeSize.isAccessibilitySize ? 1 : 3
          LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns),
            alignment: .leading, spacing: 12
          ) {
            compactMetric(
              "Temperature", symbol: "thermometer.medium",
              value: part.temperatureRangeC.map { $0.map(golfNumber).joined(separator: "–") + "°C" }
            )
            compactMetric(
              "Wind", symbol: "wind", value: part.maxWindKmh.map { "\(golfNumber($0)) km/h" })
            compactMetric(
              "Precipitation", symbol: "drop",
              value: part.rain.map {
                $0.minimumMm == $0.maximumMm
                  ? "\(golfNumber($0.maximumMm)) mm"
                  : "\(golfNumber($0.minimumMm))–\(golfNumber($0.maximumMm)) mm"
              })
          }
        }
        if day.outlookRating == nil { Text(day.status).font(.caption).foregroundStyle(.secondary) }
        if let run = model.outlook?.runTime {
          Text("Model issued \(golfDate(run, zone: round.course.zone, pattern: "MMM d, HH:mm z"))")
            .font(.caption2).foregroundStyle(.secondary)
        }
      } else if model.loading {
        ProgressView("Checking your round…").font(.caption)
      } else {
        GolfRoundStatus(round: round)
      }
      if let error = model.error { Text(error).font(.caption).foregroundStyle(.secondary) }
      HStack {
        NavigationLink {
          GolfRoundDetail(settings: settings, roundID: round.id, model: model)
        } label: {
          Label("View round", systemImage: "arrow.right").font(.subheadline.weight(.semibold))
        }.accessibilityIdentifier("golfViewRound-\(round.id)")
        Spacer()
        Button("Edit", systemImage: "pencil", action: onEdit).font(.subheadline)
          .accessibilityIdentifier("golfEditRound-\(round.id)")
      }
    }.padding().background(
      Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16)
    )
    .accessibilityElement(children: .contain).accessibilityIdentifier(
      "golfSavedRound-\(round.id)"
    )
    .task(id: "\(enabled)|\(store.serverURL)|\(round)|\(settings.value.limits)|\(refreshID)") {
      guard enabled else {
        model.cancel()
        return
      }
      await model.load(round: round, limits: settings.value.limits, api: store.api)
    }
  }
  private func compactMetric(_ name: String, symbol: String, value: String?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(name, systemImage: symbol).font(.caption2).foregroundStyle(.secondary)
      Text(value ?? "—").font(.caption.weight(.medium))
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct GolfRoundStatus: View {
  let round: GolfRound
  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Label(title, systemImage: round.availability() == .passed ? "checkmark.circle" : "clock")
        .font(.subheadline.weight(.semibold))
      Text(message).font(.caption).foregroundStyle(.secondary)
    }.accessibilityIdentifier("golfRoundStatus")
  }
  private var title: String {
    switch round.availability() {
    case .pending: "Forecast pending"
    case .passed: "Tee time has passed"
    case .invalid: "Check tee time"
    case .ready: "Forecast unavailable"
    }
  }
  private var message: String {
    switch round.availability() {
    case .pending: "Your round is saved. Check back within six days of the tee time for a forecast."
    case .passed: "Kept in your saved rounds. Edit to plan another time, or delete this round."
    case .invalid: "Choose a valid course-local date and time."
    case .ready: "Your round is saved. Refresh to check for weather data."
    }
  }
}

private struct GolfRoundDetail: View {
  @ObservedObject var settings: GolfSettingsStore
  let roundID: UUID
  @ObservedObject var model: GolfModel
  @EnvironmentObject private var store: AppStore
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dismiss) private var dismiss
  @State private var editor: GolfRoundEditorRoute?
  @State private var refresh = 0
  private var round: GolfRound? { settings.rounds.first { $0.id == roundID } }
  var body: some View {
    ScrollView {
      if let round {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            Text(round.course.name).font(.title2.bold())
            Text(round.course.locality).font(.subheadline).foregroundStyle(.secondary)
            Text("Course time zone: \(round.course.timeZone)").font(.caption).foregroundStyle(
              .secondary)
            Text("2h before · 4h round · 1h after").font(.caption).foregroundStyle(.secondary)
          }
          if let outlook = model.currentOutlook(for: round, limits: settings.value.limits),
            let day = outlook.days.first, let narrative = model.narratives[day.id]
          {
            GolfDayCard(
              day: day, narrative: narrative, outlook: outlook,
              zone: round.course.zone, server: store.serverURL.absoluteString)
            GolfOutlookAbout(outlook: outlook, zone: round.course.zone)
          } else if model.loading {
            ProgressView("Loading your round forecast…").frame(maxWidth: .infinity).padding()
          } else {
            GolfRoundStatus(round: round)
          }
          if let error = model.error { Text(error).font(.callout).foregroundStyle(.secondary) }
        }.padding()
      }
    }.background(Color(.systemGroupedBackground))
      .navigationTitle("Round outlook").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          if let round { Button("Edit") { editor = GolfRoundEditorRoute(round: round) } }
        }
      }
      .refreshable { refresh += 1 }
      .sheet(item: $editor) { route in GolfRoundEditor(settings: settings, route: route) }
      .task(
        id:
          "\(String(describing: round))|\(settings.value.limits)|\(scenePhase)|\(store.selectedTab)|\(refresh)|\(store.forecastRefresh)"
      ) {
        guard let round, scenePhase == .active, store.selectedTab == 4 else {
          model.cancel()
          return
        }
        await model.load(round: round, limits: settings.value.limits, api: store.api)
        guard !Task.isCancelled, round.availability() == .ready else { return }
        await model.explain(
          server: store.serverURL.absoluteString, weeklySummary: store.forecastSummary)
      }
      .onDisappear { model.cancel() }
      .onChange(of: settings.rounds) { _, _ in if round == nil { dismiss() } }
  }
}

private struct GolfOutlookAbout: View {
  let outlook: GolfOutlook
  let zone: TimeZone
  var body: some View {
    DisclosureGroup("About the outlook & data") {
      VStack(alignment: .leading, spacing: 8) {
        Text(
          "Five outlooks: Excellent, Good, Mixed, Poor and Very poor. Excellent needs comfortable temperatures, light wind, little or no rain and comfortable margins inside your preferences. Good allows mild drawbacks or a brief small exceedance. Missing or stale data is not assigned an unhappy face."
        )
        Text(outlook.scoreMeaning)
        Text(outlook.method)
        if let run = outlook.runTime {
          Text("Model issued \(golfDate(run, zone: zone, pattern: "EEE MMM d, HH:mm z"))")
        }
        if let context = outlook.regionalContext {
          Text(
            "Regional rain probability: \(context.name), \(context.distanceKm.formatted(.number.precision(.fractionLength(1)))) km from the pin; issued \(golfDate(context.issuedAt, zone: zone, pattern: "EEE MMM d, HH:mm z")).\(context.stale ? " Update overdue." : "")"
          )
        }
        Text(
          "The model describes a grid cell, not exact fairway conditions. Check warnings and course guidance; this does not assess lightning, drainage or whether the course is open."
        )
        Text(
          "On supported iPhones with Apple Intelligence enabled, explanations are written on this device. Otherwise a rules-based description is shown. No cloud AI is used."
        )
      }.font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
    }
  }
}

private struct GolfDayCard: View {
  let day: GolfDay
  @ObservedObject var narrative: ForecastSummaryModel
  let outlook: GolfOutlook
  let zone: TimeZone
  let server: String
  @State private var showingDetails = true
  private var description: GolfDescription? {
    GolfDescription.completed(
      day: day,
      input: ForecastSummaryInput(golf: day, outlook: outlook, server: server), narrative: narrative
    )
  }
  private var accent: Color {
    day.outlookRating?.colour
      ?? (["within", "partial"].contains(day.state)
        ? .teal : day.state == "outside" ? .orange : .secondary)
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
          if let rating = day.outlookRating {
            GolfMoodIcon(rating: rating, issue: day.outlookIssue)
              .frame(width: 72, height: 72)
              .accessibilityIdentifier("golfOutlookIcon-\(day.id)")
            Text(rating.label).font(.subheadline.bold()).foregroundStyle(accent)
          } else {
            Image(systemName: "questionmark.circle").font(.title2).foregroundStyle(.secondary)
            Text(outlook.ruleVersion == "golf-fit-v4" ? "Not rated" : "Update needed")
              .font(.caption).foregroundStyle(.secondary)
          }
          Text("Golf outlook")
            .font(.caption2).foregroundStyle(.secondary)
        }.accessibilityElement(children: .contain)
      }
      if let issue = day.outlookIssue {
        Text("Main drawback: \(issue.label)").font(.subheadline.weight(.semibold)).foregroundStyle(
          accent)
      }
      Text(day.status).font(.caption).foregroundStyle(.secondary)
      if let description {
        Text(description.text)
          .font(.callout).fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("golfDescription-\(day.id)")
        Text(description.isGeneratedOnDevice ? "Written on this iPhone" : "Rules-based description")
          .font(.caption2).foregroundStyle(.secondary)
        if let note = description.note { Text(note).font(.caption).foregroundStyle(.secondary) }
      }
      DisclosureGroup("Round details", isExpanded: $showingDetails) {
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
    }.padding().background(
      Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16)
    )
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

/// Original-colour PNG sprites; the approved atlases are bundled, never downloaded.
struct GolfMoodIcon: View {
  let rating: GolfRating
  var issue: GolfIssue?
  static func image(rating: GolfRating, issue: GolfIssue?) -> UIImage? {
    let usesHeatAtlas = rating.column >= 2 && issue == .heat
    guard let atlas = UIImage(named: usesHeatAtlas ? "GolfHeatAtlas" : "GolfMoodAtlas")?.cgImage
    else { return nil }
    if usesHeatAtlas {
      let column = rating.column - 2
      let left = Int((Double(column) / 3 * Double(atlas.width)).rounded())
      let right = Int((Double(column + 1) / 3 * Double(atlas.width)).rounded())
      guard
        let cell = atlas.cropping(
          to: CGRect(x: left, y: 0, width: right - left, height: atlas.height))
      else { return nil }
      return UIImage(cgImage: cell)
    }
    let row = rating.column >= 2 ? (issue?.atlasRow ?? 0) : 0
    // The generated artwork has taller umbrella silhouettes. These verified
    // transparent gutters prevent drops or wisps leaking from adjacent sprites.
    let rowEdges = [0.0, 0.27, 0.49, 0.715, 1.0]
    let leftFraction = row == 1 && rating.column == 4 ? 0.792 : Double(rating.column) / 5
    let rightFraction = row == 1 && rating.column == 3 ? 0.792 : Double(rating.column + 1) / 5
    let left = Int((leftFraction * Double(atlas.width)).rounded())
    let right = Int((rightFraction * Double(atlas.width)).rounded())
    let top = Int((rowEdges[row] * Double(atlas.height)).rounded())
    let bottom = Int((rowEdges[row + 1] * Double(atlas.height)).rounded())
    guard
      let cell = atlas.cropping(
        to: CGRect(x: left, y: top, width: right - left, height: bottom - top))
    else { return nil }
    return UIImage(cgImage: cell)
  }
  var body: some View {
    Group {
      if let image = Self.image(rating: rating, issue: issue) {
        Image(uiImage: image).resizable().renderingMode(.original).scaledToFit()
      } else {
        Image(systemName: "questionmark.circle").resizable().scaledToFit().foregroundStyle(
          .secondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isImage)
    .accessibilityLabel(
      "\(rating.label) golf outlook\(issue.map { ", main drawback: \($0.label)" } ?? "")")
  }
}

func golfDate(_ date: Date, zone: TimeZone, pattern: String) -> String {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_CA")
  formatter.timeZone = zone
  formatter.dateFormat = pattern
  return formatter.string(from: date)
}

private func golfNumber(_ value: Double) -> String {
  value.formatted(.number.precision(.fractionLength(0...1)))
}
