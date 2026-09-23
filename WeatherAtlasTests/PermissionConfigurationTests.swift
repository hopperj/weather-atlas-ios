import Foundation
import XCTest

final class PermissionConfigurationTests: XCTestCase {
  func testAppDeclaresOnlyPhoneOrientationsWithoutRequiringFullScreen() throws {
    let info = try readPlist(Bundle.main.bundleURL.appendingPathComponent("Info.plist"))
    let phoneOrientations = [
      "UIInterfaceOrientationPortrait",
      "UIInterfaceOrientationLandscapeLeft",
      "UIInterfaceOrientationLandscapeRight",
    ]
    XCTAssertEqual(info["UISupportedInterfaceOrientations"] as? [String], phoneOrientations)
    XCTAssertNil(info["UISupportedInterfaceOrientations~ipad"])
    XCTAssertNotEqual(info["UIRequiresFullScreen"] as? Bool, true)
  }

  func testAppAndWidgetTargetOnlyTheIPhoneDeviceFamily() throws {
    for bundle in [Bundle.main.bundleURL, widgetBundleURL] {
      let info = try readPlist(bundle.appendingPathComponent("Info.plist"))
      XCTAssertEqual(info["UIDeviceFamily"] as? [Int], [1])
      if let capabilities = info["UIRequiredDeviceCapabilities"] {
        // Xcode adds arm64 to device builds; no artificial iPhone-only hardware gate.
        XCTAssertEqual(capabilities as? [String], ["arm64"])
      }
    }
  }

  func testAppRequestsOnlyForegroundLocationWithReducedAccuracy() throws {
    let info = try readPlist(Bundle.main.bundleURL.appendingPathComponent("Info.plist"))
    let purposeKeys = Set(info.keys.filter { $0.hasSuffix("UsageDescription") })
    XCTAssertEqual(
      purposeKeys, ["NSLocationWhenInUseUsageDescription"])
    for key in purposeKeys {
      let purpose = try XCTUnwrap(info[key] as? String)
      XCTAssertFalse(purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      XCTAssertTrue(purpose.contains("server"), "The purpose must explain the server connection")
    }
    XCTAssertEqual(info["NSLocationDefaultAccuracyReduced"] as? Bool, true)
    assertNoUnneededCapabilities(info)
  }

  func testWidgetDoesNotRequestItsOwnLocationOrLocalNetworkPermissions() throws {
    let info = try readPlist(widgetBundleURL.appendingPathComponent("Info.plist"))
    XCTAssertFalse(info.keys.contains { $0.hasSuffix("UsageDescription") })
    XCTAssertNil(info["NSLocationDefaultAccuracyReduced"])
    assertNoUnneededCapabilities(info)
  }

  func testAppAndWidgetUseDefaultTransportSecurityWithoutHTTPExceptions() throws {
    for bundle in [Bundle.main.bundleURL, widgetBundleURL] {
      let info = try readPlist(bundle.appendingPathComponent("Info.plist"))
      XCTAssertNil(info["NSAppTransportSecurity"])
      XCTAssertNil(info["NSLocalNetworkUsageDescription"])
    }
  }

  func testBundledPrivacyManifestDeclaresOnlyTheRequiredLocalPreferencesReason() throws {
    let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
    let manifest = try readPlist(url)
    XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
    XCTAssertEqual(manifest["NSPrivacyTrackingDomains"] as? [String], [])
    let access = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
    XCTAssertEqual(access.count, 1)
    let defaults = try XCTUnwrap(access.first)
    XCTAssertEqual(
      defaults["NSPrivacyAccessedAPIType"] as? String, "NSPrivacyAccessedAPICategoryUserDefaults")
    XCTAssertEqual(defaults["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"])
  }

  private var widgetBundleURL: URL {
    Bundle.main.bundleURL.appendingPathComponent("PlugIns/WeatherAtlasWidgets.appex")
  }

  private func readPlist(_ url: URL) throws -> [String: Any] {
    try XCTUnwrap(
      PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        as? [String: Any])
  }

  private func assertNoUnneededCapabilities(
    _ info: [String: Any], file: StaticString = #filePath, line: UInt = #line
  ) {
    for key in [
      "NSLocationAlwaysUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription",
      "NSLocationTemporaryUsageDescriptionDictionary", "NSWidgetWantsLocation",
      "UIBackgroundModes", "BGTaskSchedulerPermittedIdentifiers", "NSBonjourServices",
    ] {
      XCTAssertNil(info[key], "Unneeded configuration: \(key)", file: file, line: line)
    }
  }
}
