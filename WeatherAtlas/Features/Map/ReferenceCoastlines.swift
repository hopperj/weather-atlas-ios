import MapKit

/// Static cartographic artwork, prepared outside the app; never weather collection or ETL.
enum ReferenceCoastlines {
  @MainActor private static let polylines: [MKPolyline] = {
    guard
      let url = Bundle.main.url(forResource: "NaturalEarthCoastlines", withExtension: "geojson"),
      let data = try? Data(contentsOf: url),
      let features = try? MKGeoJSONDecoder().decode(data)
    else { return [] }
    return features.compactMap { $0 as? MKGeoJSONFeature }.flatMap { feature in
      feature.geometry.flatMap { geometry -> [MKPolyline] in
        if let line = geometry as? MKPolyline { return [line] }
        if let lines = geometry as? MKMultiPolyline { return lines.polylines }
        return []
      }
    }
  }()

  @MainActor static func overlay() -> MKMultiPolyline {
    let overlay = MKMultiPolyline(polylines)
    overlay.title = "Reference coastline"
    return overlay
  }

  /// Natural Earth's regional-scale generalisation must not imply street-level precision.
  static func opacity(zoomScale: MKZoomScale) -> CGFloat {
    guard zoomScale.isFinite, zoomScale > 0 else { return 0 }
    let zoom = log2(zoomScale * MKMapSize.world.width / 256)
    return max(0, min(1, 8.5 - zoom))
  }
}

final class ReferenceCoastlineRenderer: MKMultiPolylineRenderer {
  override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
    let opacity = ReferenceCoastlines.opacity(zoomScale: zoomScale)
    guard opacity > 0 else { return }
    if path == nil { createPath() }
    guard let path else { return }
    context.saveGState()
    defer { context.restoreGState() }
    context.setLineJoin(.round)
    context.setLineCap(.round)
    for (colour, width) in [
      (UIColor.white.withAlphaComponent(0.85), 2.4),
      (UIColor(red: 82 / 255, green: 101 / 255, blue: 112 / 255, alpha: 0.9), 0.8),
    ] {
      context.setAlpha(opacity)
      context.setStrokeColor(colour.cgColor)
      context.setLineWidth(width / zoomScale)
      context.addPath(path)
      context.strokePath()
    }
  }
}
