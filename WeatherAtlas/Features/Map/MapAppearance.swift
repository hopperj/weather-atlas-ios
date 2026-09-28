import MapKit

enum MapAppearance {
  static let weatherOpacity = 0.62

  @MainActor static func configure(_ map: MKMapView, weatherOverlay: MKOverlay) {
    let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
    configuration.pointOfInterestFilter = .excludingAll
    configuration.showsTraffic = false
    map.preferredConfiguration = configuration
    // Apple keeps its native place labels above this level. The static reference
    // coastline is drawn after the weather and never participates in frame swaps.
    map.addOverlay(weatherOverlay, level: .aboveRoads)
    map.addOverlay(ReferenceCoastlines.overlay(), level: .aboveRoads)
  }

  static func windSize(speed: Double?) -> Int {
    guard let speed, speed.isFinite, speed >= 0 else { return 24 }
    return 20 + Int((min(speed, 45) / 45 * 10).rounded())
  }

  // Presentation-only m/s scale, matching the web map. Whole-m/s colours keep
  // the symbol cache bounded; the callout retains the exact server speed.
  static let windSpeedColours: [(speed: Int, hex: String)] = [
    (0, "#2563eb"), (5, "#0d9488"), (10, "#65a30d"), (15, "#eab308"),
    (20, "#ea580c"), (30, "#dc2626"), (40, "#a21caf"),
  ]
  static let windMaxColourSpeed = 40

  static func windColourIndex(speed: Double?) -> Int? {
    guard let speed, speed.isFinite, speed >= 0 else { return nil }
    return Int(min(speed, Double(windMaxColourSpeed)))
  }

  static func windColourHex(speed: Double?) -> String {
    guard let bounded = windColourIndex(speed: speed) else { return "#243746" }
    for index in 1..<windSpeedColours.count {
      let low = windSpeedColours[index - 1]
      let high = windSpeedColours[index]
      guard bounded <= high.speed else { continue }
      let fraction = Double(bounded - low.speed) / Double(high.speed - low.speed)
      let start = UInt32(low.hex.dropFirst(), radix: 16)!
      let end = UInt32(high.hex.dropFirst(), radix: 16)!
      let channels = [16, 8, 0].map { shift in
        let first = Double((start >> shift) & 255)
        let last = Double((end >> shift) & 255)
        return Int((first + fraction * (last - first)).rounded())
      }
      return String(format: "#%02x%02x%02x", channels[0], channels[1], channels[2])
    }
    return windSpeedColours.last!.hex
  }

  @MainActor static func windImage(speed: Double?) -> UIImage {
    let size = windSize(speed: speed)
    let key = WindImageKey(size: size, colour: windColourIndex(speed: speed))
    if let image = windImages[key] { return image }
    let image = drawWindImage(size: size, hex: windColourHex(speed: speed))
    windImages[key] = image
    return image
  }

  private struct WindImageKey: Hashable {
    let size: Int
    let colour: Int?
  }
  @MainActor private static var windImages: [WindImageKey: UIImage] = [:]

  // These tiny, code-drawn symbols need no image assets, permissions or network.
  @MainActor private static func drawWindImage(size: Int, hex: String) -> UIImage {
    let width = CGFloat(size)
    return UIGraphicsImageRenderer(size: CGSize(width: width, height: width)).image { context in
      context.cgContext.scaleBy(x: width / 48, y: width / 48)
      let path = UIBezierPath()
      path.move(to: CGPoint(x: 24, y: 4))
      for point in [
        CGPoint(x: 38, y: 18), CGPoint(x: 29, y: 18), CGPoint(x: 29, y: 44),
        CGPoint(x: 19, y: 44), CGPoint(x: 19, y: 18), CGPoint(x: 10, y: 18),
      ] {
        path.addLine(to: point)
      }
      path.close()
      path.lineWidth = 4
      path.lineJoinStyle = .round
      UIColor.white.setStroke()
      path.stroke()
      let rgb = UInt32(hex.dropFirst(), radix: 16)!
      UIColor(
        red: CGFloat((rgb >> 16) & 255) / 255,
        green: CGFloat((rgb >> 8) & 255) / 255,
        blue: CGFloat(rgb & 255) / 255, alpha: 1
      ).setFill()
      path.fill()
    }
  }
}
