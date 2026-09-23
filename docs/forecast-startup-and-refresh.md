# Forecast startup and five-minute refresh

Implemented 2026-09-07 in the native iOS client.

## Silent-refresh verification

The silent-refresh update passed all 96 unit tests and three focused simulator
UI tests: stable daily/hourly layout during separately delayed bulletin and
optional-feed updates, visible progress only on an empty initial load, and an
immediate saved forecast with no refresh indicator on relaunch. The tests also
verify that changed daily and hourly temperatures appear after the delayed
responses arrive. The saved-forecast screenshot was visually checked. This is
an iPhone app change; the server and ETL schedules are unchanged.

## Configurable default location

Settings → Forecast → Default location now lets the user search collected regions
and choose a fallback, initially Halifax. This preference is stored on the phone
per configured server, separately from a manual Forecast selection. A current GPS
fix or explicit manual selection continues to take priority. If GPS fails, is
denied, or times out, the chosen default replaces a previously cached GPS region.
While GPS is still pending, an existing matching automatic snapshot can still be
shown immediately as the last forecast location.

Custom defaults use their server-supplied representative coordinates for the
small nearest-region API request. The result must match the saved region ID;
otherwise the app checks the region catalogue, never silently substituting a
different city. Missing selected coverage is reported with instructions to choose
another default in Settings. Halifax retains its existing compact, name-checked lookup.

The preference participates in request identity and automatic snapshot matching.
Changing it synchronously invalidates old requests/snapshots before another
location can be displayed. The existing version-one snapshot format remains
readable for Halifax. No server deployment or upstream weather collection was
added to the phone; this only changes which server forecast is requested.

Default-location verification passed 89 unit tests and three targeted simulator
interface tests, including denied-location fallback, manual/GPS precedence, and
Settings selection/search/persistence/reset with 72-hour forecasts. The Settings
screenshot was visually checked. The iPhone app must be rebuilt for this selector;
the server API and its collection schedules are unchanged.

## Diagnosis

The initial investigation found that an automatic-location forecast did not start loading until either
Core Location supplied a fix or location acquisition failed/timed out. The
location timeout is 20 seconds, matching the reported startup delay. A local
diagnostic request to the regional forecast endpoint took approximately 0.084 s
(about 2 MB of JSON); the Halifax coordinate lookup took approximately 0.049 s
(about 3 KB). These are Mac-to-local-server measurements, not measured physical-
iPhone launch timings, but the deliberate location wait was a clear blocking
dependency in the client.

ForecastScreen also already had a 300-second refresh loop. It was scoped to the
visible Forecast tab, called location.refresh(), and cleared the displayed
forecast at the start of each model load. Thus periodic refresh could recreate
the initial location wait and blank the UI even when useful data existed.

## New startup behavior

- AppStore synchronously restores the last forecast for the configured server
  and current automatic/manual selection before presenting ForecastScreen.
  This does not make a network request or wait for location permission/GPS.
- The snapshot includes the issued regional bulletin, hourly forecast and
  matching model precipitation estimates. Original issue/model and last-update
  timestamps are retained; unavailable updates produce a saved-data warning.
- With automatic location and a saved prior region, that region appears as
  **Last forecast location** while location acquisition runs separately.
- Without a saved prior automatic region, request the server's Halifax Metro
  forecast immediately as **Default location**. No 20-second weather-loading
  dependency remains. A first-ever uncached load still requires the network.
- A later valid fix selects the server's nearest available region and changes
  the label to **Current location**. Explicit manual region choices always win.
- During network/location refresh, preserve the existing region and hourly
  data. Commit a new region only after its bulletin arrives; clear hourly data
  from any different region and discard precipitation estimates for a different
  bulletin. A failure retains previously loaded data with an explanation.
- Routine refreshes do not insert loading indicators or a temporary saved-data
  notice above existing content. The daily cards and hourly chart stay in place.
  Location/forecast/hourly spinners are reserved for initial loads with no data.
  Populated region/location pickers also update silently, and an existing map frame
  stays visible without a spinner while its replacement loads.

The 20-second timer remains only as a location-status diagnostic; it does not
gate loading the forecast. Recent foreground fixes (up to five minutes) can be
reused while acquiring a new fix. GPS remains foreground-only, active while the
Forecast tab is visible; periodic weather refresh does not restart it.

## Refresh ownership and lifecycle

ContentView, rather than the tab's view, owns the forecast request task and the
periodic schedule. AppStore owns the persistent in-memory ForecastModel.

- Refresh every 300 seconds while the application is active, including while
  the user views Map, Saved or Settings. Tab switches do not restart the clock.
- On transition back to active, the request's enabled state changes and a fresh
  request is made immediately; saved data stays visible meanwhile.
- Selection, server or location changes generate a new request. Revision checks
  and task cancellation prevent late responses from replacing newer selections.
  A synchronous selection change invalidates old responses before SwiftUI starts
  its next task.
- Pull-to-refresh requests fresh forecasts without resetting GPS.
- Inactive/background scenes cancel weather request work and stop the periodic
  loop. No background execution entitlement or exact suspended-app schedule was
  added. This is a foreground data-refresh feature, not an app-binary updater.

The issued bulletin loads first; hourly data and precipitation estimates refresh
independently in parallel. “Last updated” records the last fully successful
forecast refresh, not the bulletin's issue time. Partial failures do not move that
timestamp forward. Original bulletin/model timestamps still describe the data.

Forecast API calls bypass the local URLSession HTTP cache on explicit checks so
a just-unexpired response cannot turn a five-minute check into a ten-minute one.
The saved snapshot supplies fast display. Other API/tile cache policies are
unchanged, including native map playback buffering. No upstream-provider or ETL
schedule was changed by this work.

## Snapshot safety and limits

ForecastSnapshotStore uses local UserDefaults data, scoped by the exact configured
server URL. It retains at most the latest automatic and latest manual forecast
per server. A manual snapshot is accepted only for its exact selected region.
Automatic snapshots never become persisted manual location overrides.

Snapshots older than 24 hours, malformed snapshots, mismatched selections, or
bulletins with no remaining forecast periods are ignored. Expired hourly windows
are not restored. Precipitation estimates must match both region and bulletin
issue time. This is a display cache, not an offline archive or a claim that saved
forecasts are still current. No phone-coordinate history is written: only public
regional forecast data and cache/refresh timestamps are stored.

## Verification

Regression tests cover synchronous restoration before any API call, slow refresh
without blanking daily/hourly views, immediate Halifax startup without GPS, last-
region labeling while awaiting location, replacement by a fresh fix, network
failure retaining saved data, immediate stale-response invalidation, server and
manual/automatic cache separation, expiration/corruption, launch-time AppStore
restoration, recent-location reuse, forecast-only HTTP cache bypass, and the
300-second schedule across tab changes/cancellation/inactive state.

The scheduler's cadence is exercised with an injected sleep function rather
than waiting five wall-clock minutes in every test. A loopback-only UI fixture
can delay forecast responses through `/test/forecast-delay?seconds=6`. The cold-
relaunch UI test warms a snapshot, delays all forecast endpoints by six seconds,
relaunches, and requires saved forecast values within two seconds of launch
completion, without a spinner or transient refreshing notice. Additional UI tests
hold bulletin and optional forecast responses separately using
`/test/forecast-refresh`, reactivate the app through the normal refresh path, and
verify unchanged daily/hourly positions, retained values while waiting, and new
values after release. An empty-start test verifies that first-load progress remains.
These controls exist only in
the development fixture server, not in the application or production API.

Physical-device launch performance depends on iOS startup and network conditions.
Install the updated build on the phone to confirm real-world behavior; the Mac's
endpoint timing is not a substitute for a physical-iPhone measurement.

Verification completed with Xcode 26.3 / iPhone 17 Pro simulator, iOS 26.3.1:

- All 71 unit tests and all 10 interface tests passed (81 distinct tests).
- The final cold-relaunch/delayed-network test also passed after the refresh
  notice was compacted, and its screenshot was visually checked.
- Strict Swift formatting and fixture Python syntax checks passed.
- The final unsigned Release build for generic iOS devices passed. Device
  signing settings were preserved and no physical-device installation was made.
- The temporary loopback fixture server was stopped after verification.

Local result bundles: the full UI suite is
`/tmp/weatheratlas-build/Logs/Test/Test-WeatherAtlas-2026.09.07_16-46-33--0300.xcresult`;
the final unit/cache-policy checks and startup UI test are
`/tmp/weatheratlas-build/Logs/Test/Test-WeatherAtlas-2026.09.07_16-51-55--0300.xcresult`;
the final compact startup notice is covered by
`/tmp/weatheratlas-build/Logs/Test/Test-WeatherAtlas-2026.09.07_16-53-39--0300.xcresult`.
These temporary artifacts are not a permanent publication archive.

## Follow-up: black-screen / serial startup regression (build 2)

The user subsequently reported approximately 30 seconds of black screen, another
30 seconds before location acquisition, and another 30 seconds before that
location's forecast, without a visible Halifax fallback. The earlier simulator
tests did **not** establish physical-phone launch performance: they used only two
regions and checked saved data after `XCUIApplication.launch()` had returned.
That left both country-scale decoding and time spent inside launch unmeasured.
The original 20-second location dependency was real, but not a sufficient
explanation for this follow-up report.

### Measured findings

On 2026-09-07, the live regional response contained 641 regions and 1,981,747
bytes. Network transfer on the Mac took 0.158 seconds. Compiling the actual app
models and decoder in optimized Swift 6 and decoding those same bytes three
times gave 4.151, 4.209 and 4.155 seconds before the change. A new
`ISO8601DateFormatter` was being created and configured for every date string.
Using immutable `Date.ISO8601FormatStyle` parsers reduced these runs to 0.062,
0.048 and 0.047 seconds. This is a decoder benchmark, **not** a measured
end-to-end iPhone startup speedup.

The configured LAN host's Halifax requests were also checked, not only localhost:
regional lookup 0.072 seconds / 3,093 bytes, hourly 0.064 seconds / 17,158 bytes,
precipitation estimates 0.056 seconds / 11,494 bytes. All returned HTTP 200.
These measurements rule out a fixed 30-second delay in those particular server
responses, but cannot rule out the phone's networking or debugger behavior.

Read-only inspection of the connected phone found an approximately 18 KB app
preferences file and no matching app crash reports. A time-profile recording of
the already-running app was attempted, but Xcode's trace exporter crashed; no
claim about the phone's blocking stack is based on that recording. The initial
black-screen interval has not been reproduced/measured on the physical phone.

### Implementation changes

1. **Small Halifax request.** Use the existing nearest-region endpoint at the
   Halifax reference point for the uncached default. Verify that the returned
   region is actually Halifax Metro in Nova Scotia; never silently substitute a
   different region. Only a literal unsupported-route 404 falls back to the old
   full catalogue. This requires no server deployment. Manual region lookup and
   the selector still support the complete catalogue, with the faster decoder.
2. **Do not cancel the first bulletin for GPS.** Location acquisition runs
   independently. Until the automatic forecast has a bulletin (or its first
   attempt fails), GPS fixes do not change the forecast task's identity. Once
   that gate opens, the current-location request can replace Halifax while its
   already-loaded bulletin remains visible. A failure latches the gate open so
   clearing a transient error cannot produce a Halifax/GPS retry loop. Server
   changes reset this startup state; explicit manual selections still win.
3. **Cheap first view.** Construct the location service lazily, not while creating
   the root state object. Begin service setup from a cancellable task after a
   short 150 ms presentation opportunity; this is not a GPS/weather timeout.
   Repeated stop calls do nothing when inactive, and stopping never constructs
   the service. The map is not constructed until first selected. Keep it alive
   after that so map state survives tab switches.
4. **Shared, lazy transport.** AppStore owns one API transport shared with the
   map. Construct URLSession/URLCache on first use, not in SwiftUI's body and
   not during AppStore initialization. Transport initialization is protected by
   a lock; all existing server-origin, redirect, and cache policies remain.
5. **Fast parsing without loss of time semantics.** Parse whole/fractional ISO
   timestamps, including explicit timezone offsets. Regression tests verify
   subsecond precision and invalid input handling. No forecast values, source
   times, interpolation, precipitation estimation or map playback rules change.
6. **Diagnostics and identifiable build.** Log store creation/readiness, root
   appearance, location service construction, and network/decode durations under
   `com.ior.weatheratlas`, categories `startup` and `network`. Logs omit coordinate
   queries and credentials. Settings → About displays the bundled version and
   build; this patch is **1.0 (2)**.

The five-minute foreground refresh schedule and saved-forecast display remain.
Nothing adds an exact background schedule while iOS suspends the app. Halifax
cannot be supplied offline on a first-ever install; useful saved data remains
the path for immediate repeat launches.

### Reproducing the decoder measurement

Save a public `/api/v1/forecast/regions` response outside the repository. Compile
`Support/benchmark_decode.swift` alongside `WeatherAtlas/Services/WeatherAPI.swift`
and `WeatherAtlas/Models/*.swift`, using `swiftc -swift-version 6 -O`. Run the
resulting executable with the saved JSON file path. It reports bytes, regions
and three decode durations. No private phone data or credentials are needed.

### Regression verification and physical follow-up

The country-scale test decodes 20,000 timestamps within a two-second budget,
alongside timezone/subsecond correctness checks. Lifecycle tests verify lazy
location construction, idempotent stopping, and the first-bulletin GPS gate.
The UI fixture now serves 641 regions. A cold, uncached Halifax test delays that
catalogue by ten seconds, requires visible Halifax within eight seconds
**including `app.launch()`**, and verifies that neither the national catalogue
nor the map's product catalogue was requested at startup. The saved-data test
continues to delay all forecast feeds by six seconds.

To confirm the reported device-only black screen, rebuild/install build 2 in
Xcode, then stop the debug session and launch from the phone's Home Screen as
well as from Xcode. Check that Halifax or a labeled saved forecast appears while
GPS resolves. If the stall remains, the startup logs distinguish time before
app initialization, store restoration, location service setup, and network
versus decoding. A delay before the first app log cannot be explained by the
forecast endpoint's response time alone. Do not delete saved places or change
server/network settings as a speculative fix.

Build-2 verification on the iPhone 17 Pro / iOS 26.3.1 simulator:

- All 75 unit tests passed, including a rerun after the final diagnostic changes.
- All 11 UI tests passed with the country-scale fixture. Cold uncached launch
  through visible Halifax took 4.743 seconds including XCTest launch/synchronization
  overhead; this was not an isolated first-paint measurement or a phone timing.
  The resulting screenshot was inspected.
- The unsigned Release build for generic iOS devices passed and its packaged
  build number was checked as `2`. No phone installation or server restart was
  performed. Existing signing and bundle-ID settings were preserved.
- Strict Swift formatting and Python fixture syntax checks passed.

Local result bundles are
`/tmp/weatheratlas-build/Logs/Test/Test-WeatherAtlas-2026.09.07_17-23-34--0300.xcresult`
(all UI tests) and
`/tmp/weatheratlas-build/Logs/Test/Test-WeatherAtlas-2026.09.07_17-28-30--0300.xcresult`
(final unit tests). These are temporary development artifacts.

Both cold-launch and delayed-network saved-forecast UI tests were rerun against
the final build-2 code and passed:
`/tmp/weatheratlas-build/Logs/Test/Test-WeatherAtlas-2026.09.07_17-29-28--0300.xcresult`.
The temporary loopback fixture server was stopped after verification. The
production weather server and ETL pipelines were not restarted or changed.
