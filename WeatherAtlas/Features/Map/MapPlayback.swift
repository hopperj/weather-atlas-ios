import ImageIO
import MapKit

enum MapPlaybackSpeed: Int, CaseIterable, Identifiable {
  case normal = 1
  case double = 2
  case quadruple = 4
  case octuple = 8
  var id: Int { rawValue }
  var label: String { "\(rawValue)×" }
  var secondsPerFrame: Double { 0.75 / Double(rawValue) }
}

/// A new ticket starts a full dwell. Invalidating it cancels, never resumes, a partial dwell.
struct MapPlaybackTicket: Equatable {
  let frameID: String
  let displayRevision: Int
  let speed: MapPlaybackSpeed
}

struct MapFramePresentation {
  let id: String
  let time: Date
  let caption: String
  let title: String
  let legends: [ResolvedLayer]
  let layers: [MapRasterLayer]
  let wind: [DisplayPoint]
}

enum MapFrameState {
  case loading, displayed
  case failed(String)
}

struct RasterTile: Hashable, Sendable {
  let z: Int
  let x: Int
  let y: Int
  var mapRect: MKMapRect {
    let size = MKMapSize.world.width / Double(1 << z)
    return MKMapRect(x: Double(x) * size, y: Double(y) * size, width: size, height: size)
  }
  func url(template: String, baseURL: URL) throws -> URL {
    let path = template.replacingOccurrences(of: "{z}", with: String(z))
      .replacingOccurrences(of: "{x}", with: String(x))
      .replacingOccurrences(of: "{y}", with: String(y))
    guard let url = URL(string: path), WeatherAPI.sameOrigin(url, baseURL) else {
      throw WeatherAPIError.externalResource
    }
    return url
  }
  static func covering(_ rect: MKMapRect, viewWidth: Double) -> [RasterTile] {
    let box = rect.intersection(.world)
    guard !box.isNull, !box.isEmpty, viewWidth > 0, rect.width > 0 else { return [] }
    let z = max(0, min(22, Int(ceil(log2(MKMapSize.world.width * viewWidth / rect.width / 256)))))
    let count = 1 << z
    let size = MKMapSize.world.width / Double(count)
    let xs = max(0, Int(floor(box.minX / size)))...min(count - 1, Int(ceil(box.maxX / size)) - 1)
    let ys = max(0, Int(floor(box.minY / size)))...min(count - 1, Int(ceil(box.maxY / size)) - 1)
    return ys.flatMap { y in xs.map { RasterTile(z: z, x: $0, y: y) } }
  }
}

struct PreparedRasterTile: @unchecked Sendable {
  let tile: RasterTile
  let image: CGImage  // Decoded and immutable before publication to the renderer.
  let opacity: Double
  let layerIndex: Int
}

/// Whole-frame preparation. A single failed/invalid tile fails the frame, not just a square.
final class RasterFrameLoader: @unchecked Sendable {
  private let cache = NSCache<NSURL, RasterImage>()
  init() { cache.totalCostLimit = 64 * 1024 * 1024 }

  func prepare(layers: [MapRasterLayer], tiles: [RasterTile], api: WeatherAPI) async throws
    -> [PreparedRasterTile]
  {
    guard !layers.isEmpty, layers.count <= 3, !tiles.isEmpty, tiles.count <= 256 else {
      throw WeatherAPIError.invalidResponse
    }
    let requests = try layers.enumerated().flatMap { index, layer in
      try tiles.map { tile in
        (index, layer.opacity, tile, try tile.url(template: layer.template, baseURL: api.baseURL))
      }
    }
    return try await withThrowingTaskGroup(of: PreparedRasterTile.self) { group in
      var next = 0
      func enqueue() {
        let (index, opacity, tile, url) = requests[next]
        next += 1
        group.addTask { [self] in
          try Task.checkCancellation()
          let image: CGImage
          if let cached = cache.object(forKey: url as NSURL) {
            image = cached.image
          } else {
            let (data, response) = try await api.session.data(from: url)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType?.hasPrefix("image/") == true,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(
                source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              decoded.width > 0, decoded.height > 0,
              decoded.width <= 1024, decoded.height <= 1024
            else { throw WeatherAPIError.invalidResponse }
            image = decoded
            cache.setObject(
              RasterImage(image), forKey: url as NSURL,
              cost: image.bytesPerRow * image.height)
          }
          return PreparedRasterTile(tile: tile, image: image, opacity: opacity, layerIndex: index)
        }
      }
      for _ in 0..<min(8, requests.count) { enqueue() }
      var result: [PreparedRasterTile] = []
      while let tile = try await group.next() {
        result.append(tile)
        if next < requests.count { enqueue() }
      }
      try Task.checkCancellation()
      return result.sorted { $0.layerIndex < $1.layerIndex }
    }
  }
}

private final class RasterImage {
  let image: CGImage
  init(_ image: CGImage) { self.image = image }
}

/// MapKit may draw a viewport in several calls. Every piece must be drawn before dwell starts.
struct RasterDrawCoverage {
  private(set) var remaining: [MKMapRect]
  init(_ rect: MKMapRect) { remaining = rect.isEmpty || rect.isNull ? [] : [rect] }
  mutating func record(_ drawn: MKMapRect) -> Bool {
    remaining = remaining.flatMap { rect in
      let overlap = rect.intersection(drawn)
      guard !overlap.isNull, !overlap.isEmpty else { return [rect] }
      return [
        MKMapRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
        MKMapRect(
          x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
        MKMapRect(
          x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
        MKMapRect(
          x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height),
      ].filter { !$0.isEmpty }
    }
    return remaining.isEmpty
  }
}

final class BufferedRasterOverlay: NSObject, MKOverlay {
  var coordinate: CLLocationCoordinate2D { .init(latitude: 0, longitude: 0) }
  var boundingMapRect: MKMapRect { .world }
}

/// No network requests during drawing: the entire replacement frame is already decoded.
final class BufferedRasterRenderer: MKOverlayRenderer, @unchecked Sendable {
  private let lock = NSLock()
  private var tiles: [PreparedRasterTile] = []
  private var coverage = RasterDrawCoverage(.null)
  private var revision = 0
  private var onDrawn: (@Sendable () -> Void)?

  func install(
    _ tiles: [PreparedRasterTile], viewport: MKMapRect,
    onDrawn: @escaping @Sendable () -> Void
  ) {
    lock.lock()
    self.tiles = tiles
    coverage = RasterDrawCoverage(viewport.intersection(.world))
    revision += 1
    self.onDrawn = onDrawn
    lock.unlock()
    setNeedsDisplay()
  }

  override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
    lock.lock()
    let tiles = self.tiles
    let revision = self.revision
    lock.unlock()
    context.interpolationQuality = .high
    for tile in tiles where tile.tile.mapRect.intersects(mapRect) {
      let box = rect(for: tile.tile.mapRect)
      context.saveGState()
      context.setAlpha(tile.opacity)
      context.translateBy(x: box.minX, y: box.maxY)
      context.scaleBy(x: 1, y: -1)
      context.draw(tile.image, in: CGRect(origin: .zero, size: box.size))
      context.restoreGState()
    }
    lock.lock()
    var callback: (@Sendable () -> Void)?
    if revision == self.revision, !tiles.isEmpty, coverage.record(mapRect) {
      callback = onDrawn
      onDrawn = nil
    }
    lock.unlock()
    callback?()
  }
}

/// Allow completed drawing to reach the screen before acknowledging presentation.
@MainActor final class MapPresentationFence: NSObject {
  private var link: CADisplayLink?
  private var ticks = 0
  private var completion: (() -> Void)?
  func wait(_ completion: @escaping () -> Void) {
    cancel()
    self.completion = completion
    let link = CADisplayLink(target: self, selector: #selector(tick))
    self.link = link
    link.add(to: .main, forMode: .common)
  }
  func cancel() {
    link?.invalidate()
    link = nil
    ticks = 0
    completion = nil
  }
  @objc private func tick() {
    ticks += 1
    guard ticks >= 2 else { return }
    let callback = completion
    cancel()
    callback?()
  }
}
