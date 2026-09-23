import Foundation

/// Compatibility labels for saved forecasts from before the server supplied a locality.
/// New labels come from ECCC city metadata preserved by the server's ETL.
enum ForecastLocationName {
  static func display(_ name: String, locality: String? = nil) -> String {
    if let locality = locality?.trimmingCharacters(in: .whitespacesAndNewlines), !locality.isEmpty,
      locality != name.trimmingCharacters(in: .whitespacesAndNewlines)
    {
      return locality
    }
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    switch value {
    case "Halifax Metro and Halifax County West", "Halifax Metro": return "Halifax"
    case "Sydney Metro and Cape Breton County", "Sydney Metro": return "Sydney"
    default: break
    }
    for prefix in ["City of ", "Town of "] where value.hasPrefix(prefix) {
      return String(value.dropFirst(prefix.count)).components(separatedBy: " - ")[0]
    }
    // Never guess a town from an ambiguous county, or split a hyphenated town name.
    return value
  }
}
