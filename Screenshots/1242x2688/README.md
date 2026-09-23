# Weather Atlas screenshots

Three original PNG screen captures, each **1242 × 2688 pixels**, RGB without
alpha. Captured September 8, 2026 from build 1.0 (12), on an iPhone 11 Pro Max
simulator running iOS 26.3, in light appearance. The simulator status bar is
normalized to 09:41. Images are not resized, cropped or reconstructed.

- `01-daily-forecast.png`: Halifax daily/nightly forecast and weather icons.
- `02-hourly-forecast.png`: the next 72 hours and temperature chart.
- `03-weather-map.png`: HRDPS temperature over Atlantic Canada, map modes and timeline.

Weather comes from the running `http://wolf359.iolan:18080` server, not the UI-test
fixture. Each capture waits for loaded data, verifies native pixel dimensions
and checks that no loading indicator is visible. All three were visually reviewed.
The ZIP in the parent directory contains only the three full-resolution PNGs.

To repeat on a dedicated iPhone 11 Pro Max simulator, boot it, set light
appearance and the desired status-bar overrides, then run the opt-in test:

```sh
TEST_RUNNER_WEATHERATLAS_SCREENSHOTS=1 xcodebuild \
  -project WeatherAtlas.xcodeproj -scheme WeatherAtlas \
  -destination 'platform=iOS Simulator,id=YOUR_DEDICATED_SIMULATOR_ID' \
  -parallel-testing-enabled NO \
  -only-testing:WeatherAtlasUITests/WeatherAtlasUITests/testCaptureLiveAppScreenshots1242x2688 test
```

Export attachments from the resulting test report with `xcresulttool`.
The capture test is skipped by default and on physical devices. It changes no
production app behavior or server data. The phone was not automated or reinstalled
for this capture; the dedicated simulator was shut down afterward.
