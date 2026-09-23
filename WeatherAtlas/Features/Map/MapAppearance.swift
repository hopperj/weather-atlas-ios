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

  @MainActor static func windImage(speed: Double?) -> UIImage {
    windImages[windSize(speed: speed) - 20]
  }

  // These tiny, code-drawn symbols need no image assets, permissions or network.
  @MainActor private static let windImages: [UIImage] = (20...30).map { size in
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
      UIColor(red: 36 / 255, green: 55 / 255, blue: 70 / 255, alpha: 1).setFill()
      path.fill()
    }
  }
}
