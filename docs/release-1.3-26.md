# Weather Atlas 1.3 (26)

Prepared October 19, 2026. Requires a fresh Xcode build/archive; an older archive
does not acquire these changes. This task does not install, sign for distribution,
upload to TestFlight or submit to the App Store.

## What's changed

- **Astronomy / Clear sky:** a primary tab directly beside Golf, exact map pins
  and coordinate entry, independent saved observing sites, foreground GPS,
  native-time weather/cloud tables, Sun/Moon/twilight events, seven dated nights,
  explainable observing windows, adjustable cloud/wind limits and dim red viewing.
  Saved and Settings are retained in More. Hidden Astronomy tabs stop refreshing
  and listening for GPS. The redundant Forecast-page Astronomy button is removed.
- **Saved golf rounds:** persist multiple tee times across navigation/relaunches;
  assess just the selected round, not every day; arrange upcoming rounds
  chronologically; search verified Canadian courses or choose a named pin.
  The picker starts at the Forecast location, and up to five usual courses are
  reusable. The calendar closes after day selection. The main page has one
  Add tee time action. See [round-planner details](golf-round-planner.md).
- **Golf faces:** heat-limited Mixed/Poor/Very poor faces use increasingly full
  red thermometers, no toque, and progressively more sweat. Existing cold, wind
  and rain progressions remain. See [artwork](golf-outlook-artwork.md).
- **Forecast clarity:** hourly icons/POP use their matching issued ECCC hours;
  the strip starts at its first available forecast hour. Current conditions can
  show positive POP and sourced precipitation without compulsory empty/zero
  badges. Actual trace amounts show `<0.1 mm`; zero/missing amounts with positive
  precipitation risk show **Amount uncertain**, not invented millimetres.
- **Refresh and navigation:** preserve matching snapshots during routine refresh,
  keep point/region and response scope checks, and retain access to About under
  More → Settings. See [forecast refresh](forecast-startup-and-refresh.md).
- App and widget share **1.3 (26)** in Debug and Release, including the generated
  Xcode project; the previously closed 1.2 release train is not reused.

## Server compatibility

Astronomy uses the additive `/api/v1/astronomy/forecast` endpoint on the fixed
Weather Atlas HTTPS server. Deploy the updated server before testing that tab;
an old server gives an unavailable/error state. Existing released apps remain
compatible. No database migration, new ETL or phone-side weather collection is
required. The initial preview has **total cloud only**: layered cloud, seeing and
transparency are explicitly unavailable, not inferred from surface weather.

Golf storage remains on-device and uses the existing outlook API. Course search
and Canadian pin verification use Apple Maps. No booking, calendar, cloud sync,
background location or notification integration is added.

## Verification and remaining checks

All 222 simulator unit tests passed (seven opt-in checks skipped). Eight
navigation/Golf UI regressions passed, followed by four focused reruns after the
More navigation-stack cleanup. The unsigned Release build passed as **1.3 (26)**;
formatting and diff checks passed. Simulator fixtures are synthetic, not evidence
of live weather coverage. Server deployment/results are tracked in the
[server release notes](../../weatherapp/docs/release-2026-10-19.md).

On October 19 the updated API/web code (`9b08846`) was deployed to sparky. Public
HTTPS readiness and actual GDPS/RDPS/HRDPS point responses passed, including the
website's contract validation. This native feature commit is `384b20f`; its new
Astronomy tab can now be tested against the fixed public server. This is not a
claim that a signed build was uploaded or installed.

Still required before public distribution: real-device/accessibility checks,
live Astronomy horizon/latency review, and normal signing, archive and App Store
Connect steps. Specialist astronomy feeds remain separate roadmap work.
