import Foundation

extension Product {
  /// Only published ECCC models belong in the consumer map picker. The API also
  /// calls research/custom simulations "forecast", so kind alone is not sufficient.
  var isStandardMapProduct: Bool {
    switch code {
    case "hrdps", "rdps", "gdps", "raqdps", "hrdpa", "rdpa", "hrepa": true
    default: false
    }
  }
}

struct MapDataSource: Identifiable, Sendable {
  let product: Product
  let field: WeatherField
  var id: String { product.code }
  var label: String { "ECCC · \(product.code.uppercased())" }
  var description: String {
    switch product.code {
    case "hrdps": "Local forecast (HRDPS)"
    case "rdps": "Regional forecast (RDPS)"
    case "gdps": "Global forecast (GDPS)"
    case "raqdps": "Air quality forecast (RAQDPS)"
    case "hrdpa": "Local precipitation analysis (HRDPA)"
    case "rdpa": "Regional precipitation analysis (RDPA)"
    case "hrepa": "Precipitation analysis ensemble (HREPA)"
    default: product.name
    }
  }
}

struct MapDataOption: Identifiable, Sendable {
  enum Kind: Equatable, Sendable { case none, field, wind, imagery, hotspots, stations }
  let id: String
  let title: String
  let rank: Int
  let kind: Kind
  var sources: [MapDataSource] = []
  var imageryCode: String? = nil
  var sourceLabel: String = ""

  static let noOverlay = Self(id: "none", title: "None", rank: .min, kind: .none)

  static func catalogue(
    products: [Product], fields: [String: [WeatherField]], imagery: [ImageryProduct]
  ) -> [Self] {
    var groups: [String: Self] = [noOverlay.id: noOverlay]
    for product in products.filter(\.isStandardMapProduct).sorted(by: {
      if ($0.latestRunTime != nil) != ($1.latestRunTime != nil) { return $0.latestRunTime != nil }
      return $0.priority == $1.priority ? $0.code < $1.code : $0.priority < $1.priority
    }) {
      let available = fields[product.code] ?? []
      for field in available {
        let (title, rank) = field.mapLabel
        let key = "field:\(field.code)"
        if groups[key] == nil {
          groups[key] = Self(id: key, title: title, rank: rank, kind: .field)
        }
        groups[key]?.sources.append(MapDataSource(product: product, field: field))
      }
      if let anchor = available.first(where: { $0.code == "wind_u_10m" }),
        available.contains(where: { $0.code == "wind_v_10m" })
      {
        if groups["wind"] == nil {
          groups["wind"] = Self(id: "wind", title: "Wind direction", rank: 35, kind: .wind)
        }
        groups["wind"]?.sources.append(MapDataSource(product: product, field: anchor))
      }
    }
    for product in imagery {
      let title: String
      let rank: Int
      switch product.code {
      case "radar_rain": (title, rank) = ("Rain radar", 70)
      case "satellite_natural": (title, rank) = ("Satellite — visible", 80)
      case "satellite_ir": (title, rank) = ("Satellite — infrared", 81)
      default: (title, rank) = (product.name, 85)
      }
      groups["imagery:\(product.code)"] = Self(
        id: "imagery:\(product.code)", title: title, rank: rank, kind: .imagery,
        imageryCode: product.code, sourceLabel: "ECCC · GeoMet")
    }
    groups["hotspots"] = Self(
      id: "hotspots", title: "Fire hotspots", rank: 90, kind: .hotspots,
      sourceLabel: "NRCan · CWFIS")
    groups["stations"] = Self(
      id: "stations", title: "Weather stations", rank: 89, kind: .stations,
      sourceLabel: "ECCC · Surface observations")
    return groups.values.sorted { $0.rank == $1.rank ? $0.title < $1.title : $0.rank < $1.rank }
  }
}

extension WeatherField {
  /// Keep accumulation windows, analysis stages, and pollutant identities distinct.
  var mapLabel: (String, Int) {
    switch code {
    case "air_temperature_2m": ("Temperature", 10)
    case "total_precipitation_1h": ("Rain & snow amount · 1 hour", 20)
    case "wind_speed_10m": ("Wind speed", 30)
    case "wind_gust_10m": ("Wind gusts", 40)
    case "relative_humidity_2m": ("Humidity", 50)
    case "total_cloud_cover": ("Cloud cover", 60)
    case "snowfall_1h": ("Snowfall · 1 hour", 65)
    case "total_precipitation_3h": ("Rain & snow amount · 3 hours", 66)
    case "visibility_surface": ("Visibility", 100)
    case "mean_sea_level_pressure": ("Air pressure · sea level", 110)
    case "surface_pressure": ("Air pressure · ground level", 111)
    case "pm25_surface": ("Fine particles · PM2.5", 120)
    case "pm10_surface": ("Particles · PM10", 121)
    case "ozone_surface": ("Ozone", 122)
    case "nitrogen_dioxide_surface": ("Nitrogen dioxide", 123)
    case "sulfur_dioxide_surface": ("Sulfur dioxide", 124)
    case "precipitation_6h_final": ("Past rain & snow · 6 hours · final", 150)
    case "precipitation_24h_final": ("Past rain & snow · 24 hours · final", 151)
    case "precipitation_6h_preliminary": ("Past rain & snow · 6 hours · preliminary", 152)
    case "precipitation_24h_preliminary": ("Past rain & snow · 24 hours · preliminary", 153)
    case "precipitation_6h_ensemble": ("Past rain & snow · 6-hour ensemble", 154)
    case "precipitation_6h_percentile_25":
      ("Past rain & snow · 6 hours · lower estimate (25th percentile)", 155)
    case "precipitation_6h_percentile_75":
      ("Past rain & snow · 6 hours · upper estimate (75th percentile)", 156)
    case "wildfire_pm25_surface": ("Wildfire smoke · near ground", 200)
    case "wildfire_pm25_column": ("Wildfire smoke · full atmosphere", 201)
    case "wildfire_co_surface": ("Wildfire carbon monoxide", 202)
    case "wildfire_bc_surface": ("Wildfire soot · black carbon", 203)
    case "wildfire_injection_height": ("Smoke release height", 204)
    case "wildfire_pm25_dry_deposition": ("Smoke particles deposited · dry", 205)
    case "wildfire_pm25_wet_deposition": ("Smoke particles deposited · wet", 206)
    case "wind_u_10m": ("Wind component · east–west", 300)
    case "wind_v_10m": ("Wind component · north–south", 301)
    default: (name, 250)
    }
  }
}

struct PointGeometry: Decodable, Sendable {
  let coordinates: [Double]
}
struct WindCollection: Decodable, Sendable {
  struct Feature: Decodable, Sendable {
    struct Properties: Decodable, Sendable {
      let speed: Double
      let bearing: Double
    }
    let geometry: PointGeometry
    let properties: Properties
  }
  let unit: String
  let features: [Feature]
}
struct HotspotCollection: Decodable, Sendable {
  struct Feature: Decodable, Sendable {
    struct Properties: Decodable, Sendable {
      let observedAt: String?
      let sensor: String?
      enum CodingKeys: String, CodingKey {
        case observedAt = "observed_at"
        case sensor
      }
    }
    let geometry: PointGeometry
    let properties: Properties
  }
  let features: [Feature]
}
struct HotspotDates: Decodable, Sendable {
  struct Item: Decodable, Sendable { let dataDate: String }
  let items: [Item]
}
struct DisplayPoint: Identifiable, Equatable {
  let id: String
  let longitude: Double
  let latitude: Double
  let title: String
  let subtitle: String
  let bearing: Double?
  var stationID: String? = nil
  var stale = false
  var windSpeedMetresPerSecond: Double? = nil
}
