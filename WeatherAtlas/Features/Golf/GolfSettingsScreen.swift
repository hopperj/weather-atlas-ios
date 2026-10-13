import SwiftUI

struct GolfSettingsScreen: View {
  @ObservedObject var settings: GolfSettingsStore
  @Environment(\.dismiss) private var dismiss
  @State private var draft: GolfLimits
  init(settings: GolfSettingsStore) {
    self.settings = settings
    _draft = State(initialValue: settings.value.limits)
  }
  var body: some View {
    Form {
      Section("Temperature range") {
        Stepper(
          "Minimum: \(draft.minTemperatureC.formatted())°C", value: $draft.minTemperatureC,
          in: -30...49
        )
        .accessibilityIdentifier("golfMinimumTemperature")
        Stepper(
          "Maximum: \(draft.maxTemperatureC.formatted())°C", value: $draft.maxTemperatureC,
          in: -29...50
        )
        .accessibilityIdentifier("golfMaximumTemperature")
      }
      Section("Worst conditions you'll accept") {
        Stepper(
          "Sustained wind: \(draft.maxWindKmh.formatted()) km/h", value: $draft.maxWindKmh,
          in: 0...150, step: 5
        )
        .accessibilityIdentifier("golfWindLimit")
        Stepper(
          "Precipitation: \(draft.maxRainMm.formatted()) mm", value: $draft.maxRainMm, in: 0...100,
          step: 0.5
        )
        .accessibilityIdentifier("golfRainLimit")
        Stepper(
          "Rain probability: \(draft.maxPopPercent.formatted())%", value: $draft.maxPopPercent,
          in: 0...100, step: 10
        )
        .accessibilityIdentifier("golfPopLimit")
      }
      Section {
        Text(
          "These limits are checked separately for the two hours before, the four-hour round, and the hour afterward. Precipitation is the total in each window, not a daily amount or rate. Gusts are shown separately from your sustained-wind limit."
        )
        Text(
          "The five-level outlook reflects how comfortable the weather is for your preferences. Excellent needs comfortable margins and little or no rain; Good allows mild drawbacks. Wind and temperature consider how long discomfort lasts, so a brief small exceedance does not automatically mean Poor. The detailed preference checks remain separate. Your rain-chance preference applies only when a regional percentage is published. The outlook is not a probability of playing or an assurance that a course is open or safe."
        )
      }.font(.footnote).foregroundStyle(.secondary)
      if !draft.isValid {
        Text("Minimum temperature must be below maximum temperature.").foregroundStyle(.red)
      }
      Section {
        Button("Restore suggested limits") { draft = GolfLimits() }
      }
    }
    .navigationTitle("Golf weather limits")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          var value = settings.value
          value.limits = draft
          settings.save(value)
          dismiss()
        }.disabled(!draft.isValid).accessibilityIdentifier("saveGolfLimits")
      }
    }
  }
}
