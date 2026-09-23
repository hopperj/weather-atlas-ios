# Complete-frame map playback

Implemented 2026-09-07 for the native iOS application. This changes display
orchestration only; weather values, server tiles, temperature colour ranges and
the web application's separate playback implementation are unchanged.

## User-facing contract

The controls at the bottom of the play/slider card select a minimum viewing
time for each **complete, displayed weather frame**:

| Speed | Viewing time |
| --- | ---: |
| 1× (default) | 0.75 seconds |
| 2× | 0.375 seconds |
| 4× | 0.1875 seconds |
| 8× | 0.09375 seconds |

Build 1.0 (15) doubles the previous speeds, anchored to the revised request of
2× = 0.375 seconds. The same timing applies to model, radar, satellite and wind playback.
They replace the previous fixed 1.2-second polling loop. Loading and drawing do
not use up the viewing allowance. A slow connection can lengthen the actual
time between frames; this is intentional. No requested frame is skipped.

The current complete frame and its timestamp/legend remain visible while its
replacement loads. A failure pauses playback and offers Retry. Retry requests
the failed frame again, rather than jumping back to the first forecast hour.
Changing product, coverage or layer selection clears unrelated prior imagery.
Manual stepping/scrubbing is still allowed and cancels superseded work.

## Why metadata readiness was insufficient

Previously, MapScreen waited 1.2 seconds, checked MapScreenModel.isLoading, then
advanced. That flag covered layer-metadata resolution, not MapKit's asynchronous
256-pixel tile requests. Each time removed all old tile overlays and installed
new ones. Individual squares could appear progressively, and playback could
advance before the final square arrived.

## Current rendering and timing sequence

1. Resolve the single selected layer for the exact requested model run/valid
   time, or select the exact radar/satellite observation. For standalone wind
   direction, fetch only that frame's viewport-specific vectors. Missing fields
   or wind failures do not silently become a successful animation frame.
2. Enumerate every raster tile intersecting the visible map rectangle at the
   current zoom. RasterFrameLoader retrieves up to eight tiles concurrently
   across the selected layers, validates same-origin URLs, HTTP status and image
   content, and decodes all images before returning the complete set. One failed
   tile fails the entire preparation. Cancellation discards partial results.
3. Install the immutable prepared set in a persistent BufferedRasterRenderer.
   It draws tiles in layer order with the requested opacities, without doing
   network work inside draw calls. The previous raster stays installed until
   this complete replacement is available. It no longer tears down/re-adds a
   MapKit tile overlay for every frame.
4. RasterDrawCoverage accounts for MapKit's potentially partitioned draw calls.
   Readiness requires all parts of the target viewport to have been drawn, not
   just one draw call or a period of network inactivity. Transparent/no-data
   tiles are valid if returned as valid images; HTTP failures are not treated as
   transparent weather data.
5. After drawing completes, wait two CADisplayLink ticks before acknowledging
   presentation. This is a display-cycle fence, not a network-settling timeout.
   The displayed timestamp, forecast caption and legend are then committed, and
   SwiftUI starts the cancellable viewing-time task for that presentation.
6. At expiry, advance exactly one timeline entry (wrapping at the end), only if
   the presentation ticket is still current. Loading, camera movement, scrubbing,
   a speed change, pause/resume and new presentations invalidate older tickets.
   A reloaded viewport receives a fresh full viewing allowance. Leaving the map
   or backgrounding the app pauses playback.

Build 1.0 (3) makes wildfire hotspots a standalone observation selection, with a
date selector replacing the animation controls; they never overlay model or
imagery data. Standalone wind frames have no hidden raster: their annotations
are installed and pass the display-tick fence before the viewing timer starts.
Apple Maps' basemap is not
part of the weather-frame readiness gate. This does not change the underlying
weather-model spatial resolution; zooming beyond that resolution can still
reveal the original grid.

## Resource and security boundaries

Decoded images use an NSCache with a 64 MiB cost target (in addition to URLSession's
existing HTTP cache). Active/preparing frame images are also retained until
their work completes or is discarded; the cache target is not a total process
memory limit. The reusable raster loader rejects empty raster frames, more than three layers, or
viewports requesting more than 256 tiles per layer. It does not silently drop
tiles to meet this limit. New camera/selection requests cancel obsolete loads,
and generation checks reject late network/draw/display callbacks.

The iOS path prepares each replacement frame in full and reuses cached tiles.
It does **not** implement the web client's 12-future-frame look-ahead queue.
The no-skipping/full-viewing-time guarantee does not depend on speculative
look-ahead; time spent loading a replacement is additional to its viewing time.
Future look-ahead could reduce these waits without changing this contract.

All image requests use the configured WeatherAPI session and same-origin and
redirect policy. No additional weather-provider access, ingestion, interpolation
or meteorological processing was introduced. Physical-device signing settings
were preserved; the checked-in Xcode project was updated in place.

## Verification

Build 1.0 (15), 2026-09-08: all 28 playback unit tests and the targeted simulator
UI test pass. The UI test verifies all four exact displayed durations and runs
2× playback with deliberately delayed tiles. The next frame was requested
0.689 seconds after the slow frame's final tile response, retaining the new
0.375-second minimum complete-frame viewing interval plus presentation overhead.
The signed iPhone build succeeded. This timing-only change adds no permissions,
changes no data sources and leaves the web client's separate fps controls alone.

The previous mapping (2× = 0.75 seconds per frame) passed all 99 unit tests and
the targeted playback UI test. The UI check exercises all four displayed
durations, then plays at 2× with 1.4-second tile delays and confirms that the
complete frame still receives its full 0.75-second viewing allowance.

Automated regression coverage includes the four durations; metadata-only
readiness; per-viewport complete draw coverage; stale completion rejection;
camera/reload timer invalidation; speed changes, pause/resume and scrubbing;
one-at-a-time advancement and wraparound; retention of the displayed timestamp
while the next frame loads; failure/retry; tile origin enforcement; slowest-tile
and multi-layer barriers; undecodable/missing images; cancellation; and empty
frame rejection. The app's single-selection model constrains visible raster
datasets to one; the loader's internal multi-layer tests remain lower-level
coverage, not a user-facing multi-layer feature.

The loopback-only Support/fixture_server.py can delay every tile of the second
model frame by setting WEATHER_TEST_SLOW_TILE_SECONDS=1.4. Its test-only event
endpoint records monotonic request/response times. An XCUITest selects all four
speed controls, plays at 2×, and verifies that the first request for the following
frame is at least 0.375 seconds after the final response for the slow frame.
In the original passing run (before the faster speed mapping), the slow frame loaded in about 2.83 seconds and the
next request followed its final tile response by about 0.887 seconds. Thus loading
did not consume its viewing allowance. The test also checks actual MapKit drawing
readiness through the on-screen status, rather than injecting a fake ready event.

That original run passed all 58 unit tests and both targeted UI tests (60 total) on
the iPhone 17 Pro simulator, iOS 26.3.1, with Xcode 26.3. The UI playback test
zoomed in by 2× before playing; the measured post-final-tile interval was 0.886
seconds. The speed-control layout and complete zoomed viewport were visually
checked in the test screenshot. The other UI test covers existing wind/hotspot
and map-to-forecast interaction. Strict Swift formatting checks and Python fixture
syntax compilation passed. The final unsigned Release build for generic iOS
devices passed too. The broader forecast/settings UI suite was not rerun.

Final local result bundle:
`/tmp/weatheratlas-build/Logs/Test/Test-WeatherAtlas-2026.09.07_16-18-26--0300.xcresult`.
These temporary test artifacts are not a permanent research archive. Physical-
iPhone visual verification still requires building/running the updated app on
the phone; no device installation or signing changes were performed.
