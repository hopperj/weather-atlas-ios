# Fixed Weather Atlas HTTPS endpoint

Implemented 2026-09-08, build **1.0 (14)** for both app and embedded widget.
The only production weather-service endpoint is
`https://weatheratlas.ioresearch.ca`.

## App and settings

`WeatherAtlasEndpoint.productionURL` is shared between both targets.
`AppConfiguration.current` uses that fixed URL; the Release initializer also
ignores injected alternatives. The Info.plist URL is descriptive metadata, not a
user-overridable source. AppStore never selects a server from UserDefaults.
Its server URL is read-only outside the store, and its old `connect` method is
compiled only in Debug for unit-test cache-isolation scenarios.

The entire server configuration section, address field, Connect button and
HTTP warning are removed. Forecast/default-location settings are unchanged.
Privacy wording refers to the Weather Atlas service and HTTPS, not a
user-configured server. No public data, scientific model or backend is changed.

## Existing installations

An idempotent migration runs before the first production cache restore. It
recognizes the old `wolf359.iolan` ports and documented local/public aliases for
the same backend. It copies the selected legacy namespace's saved places,
selected region, paused-following flag, selected map pin, default forecast
location, and automatic/manual forecast snapshots into the canonical HTTPS
namespace. It fills only missing keys, preserving existing destination settings
and the original legacy data. Cache decoding, expiry and region checks still
apply; migration does not make stale weather fresh.

The obsolete `serverURL` preference is removed and can never reconnect the app
to HTTP. An unrelated custom server's data is retained in its old namespace,
but its region IDs and forecasts are not silently treated as canonical data.

## Widgets and links

Settings loaded from the App Group are normalized before any fetch. Known
legacy addresses become HTTPS while preserving selected/saved region records.
Unknown custom-server settings reset to the Weather Atlas default instead of
making requests to another host. The widget client independently enforces this
endpoint policy. It rejects unknown origins; normal requests and redirects
retain the existing same-origin checks, rejecting HTTP downgrades.

Old widget deep links from recognized Weather Atlas origins can still select
their forecast region, but cannot change the app endpoint. Foreign-server links
remain unable to switch the selected region. Widget messages now describe
internet connectivity rather than joining a private server network. Previously
cached widget timelines may remain visible until iOS requests their replacement;
all new production network requests use HTTPS.

## Transport and test isolation

The production app and widget remove the old local-network ATS setting and
`wolf359.iolan` insecure HTTP exception. The app also drops its local-network
purpose string. Default App Transport Security applies; no certificate-trust
bypass or HTTP fallback is introduced. Foreground approximate location and the
shared App Group remain unchanged.

Only a **Debug simulator** process may explicitly launch with
`-weatherAtlasTestServerURL http://localhost:8097` (or `127.0.0.1:8097`) for the
deterministic UI fixtures. This override reads process arguments, not persisted
settings. Other hosts, ports, credentials, paths and the obsolete `-serverURL`
argument cannot select a service. The hook is absent from physical-device and
Release builds. Unit tests can still inject isolated mock clients.

## Verification

Regression coverage includes the fixed bundled URL, ignored saved addresses,
known-origin preference migration and destination preservation, snapshots,
location-following and map pins, widget settings normalization, rejection of
foreign/downgraded URLs, legacy deep links, and the absence of server controls
in Settings. Packaged permission/transport tests cover both app and widget.

Build/test results are recorded after verification below. No App Store upload,
physical-device installation, server restart or certificate change is part of
this client update.

Verified with Xcode 26.3 and iPhone 17 Pro simulator (iOS 26.3.1):

- All **151 unit tests passed**, including the new endpoint/migration/widget
  and packaged-permission checks.
- Both fixture-based UI checks passed: forecast/map navigation and Settings
  with an obsolete saved server address. The Settings screenshot was inspected.
- The opt-in live HTTPS UI test passed without a fixture endpoint or cached
  manual forecast: the actual public service loaded Halifax, despite an obsolete
  saved HTTP address, and Settings had no server controls.
- The unsigned generic-iOS Release build passed. Its app and embedded widget
  both report build **14**, contain the public HTTPS endpoint, and have neither
  HTTP transport exceptions nor local-network purpose strings. The simulator
  endpoint flag and fixture URL are absent from both Release binaries.
- Strict Swift formatting and source plist syntax checks passed. The temporary
  local fixture server was stopped. Signing settings, identifiers and the App
  Group were preserved.

Local result bundles:

- `/tmp/weatheratlas-fixed-https-build/Logs/Test/Test-WeatherAtlas-2026.09.08_11-12-57--0300.xcresult`
- `/tmp/weatheratlas-fixed-https-build/Logs/Test/Test-WeatherAtlas-2026.09.08_11-15-38--0300.xcresult`
- `/tmp/weatheratlas-fixed-https-build/Logs/Test/Test-WeatherAtlas-2026.09.08_11-19-02--0300.xcresult`

Release artifact:
`/tmp/weatheratlas-fixed-https-release/Build/Products/Release-iphoneos/WeatherAtlas.app`.
