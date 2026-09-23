import Foundation

/// A completed response or a terminal fallback, never a provisional paragraph.
/// Queued, running, cancelled and superseded analyses do not display filler.
struct GolfDescription: Equatable {
  let text: String
  let isGeneratedOnDevice: Bool
  let note: String?

  @MainActor static func completed(
    day: GolfDay, input: ForecastSummaryInput, narrative: ForecastSummaryModel
  ) -> GolfDescription? {
    guard !narrative.isGenerating else { return nil }
    if narrative.summaryID == input.id, let text = narrative.text {
      return GolfDescription(
        text: text, isGeneratedOnDevice: narrative.isGeneratedOnDevice, note: nil)
    }
    guard narrative.currentInput?.id == input.id, narrative.messageInputID == input.id,
      let message = narrative.message
    else {
      return nil
    }
    // Unavailable device model, failure, timeout or no eligible forecast: no
    // generated response will follow this completed server assessment.
    return GolfDescription(text: day.fallbackSummary, isGeneratedOnDevice: false, note: message)
  }
}
