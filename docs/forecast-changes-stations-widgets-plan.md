# Forecast changes, nearby stations, and iPhone widgets

Status: implemented and server-deployed, 2026-09-07; iOS 1.0 (4) installed on the connected iPhone. Physical-device widget acceptance checks remain open. The original plan below is preserved; see [implementation, verification, and rollout limits](../../weatherapp/docs/forecast-insights-implementation.md) for the actual delivery state.

## Scope and decisions

Add the three previously suggested features:

- **3 — What changed?** Meaningful differences between successive forecasts for a location.
- **5 — Nearby weather stations.** Actual observations on the map and alongside the forecast.
- **6 — Home and Lock Screen widgets.** Useful weather at a glance, using the same server.

All upstream retrieval, parsing, quality checks, history, weather calculations, and comparisons belong on the server. The app, widgets, and any later web UI only request prepared data, cache it for display, and render it. No client-side provider access or background location tracking.

Keep the testing default **http://wolf359.iolan:18080**. Do not upgrade it to HTTPS, expose the server publicly, or change the existing network setup as part of this work. Preserve foreground GPS/manual-location precedence, the configurable Halifax fallback, existing map controls, and silent routine refreshes.

## What the current code supports

- The backend already has Airflow ingestion, PostgreSQL/PostGIS, Redis, retained model runs, and additive `/api/v1` APIs. Reuse these rather than add another service stack.
- `python/weather_ingest/eccc_city_forecasts.py` replaces the latest raw city forecast XML and normalized snapshot. Historical daily bulletins are not currently preserved reliably enough for comparisons.
- `python/weather_api/forecast.py` prepares hourly point forecasts on demand; its timeline can choose different model runs for different valid hours. Comparing two ordinary hourly responses would confuse real forecast changes with rolling windows, newly available hours, and run selection.
- The iOS app already caches its latest forecast, but `WeatherAtlas/Services/ForecastRefresh.swift` uses ordinary app preferences, not storage shared with a widget extension. It is not a forecast-history database.
- The checked-in Xcode project targets iOS 17 and uses `com.ior.weatheratlas`. `project.yml` has a different, stale bundle identifier. Reconcile that discrepancy before adding an extension; preserve the actual app identity and signing team.

## Shared architecture

```text
ECCC bulletins, model runs, and station reports
                       ↓
Server ETL: collect → validate → preserve versions → calculate
                       ↓
PostgreSQL/PostGIS + raw archive + prepared display records
                       ↓
Read-only API on the configured Weather Atlas server
                       ↓
iPhone screens and widgets: display + small offline cache
```

New screen and widget requests must not trigger upstream downloads or expensive weather processing. Missing preparation returns an explicit pending/unavailable state. Existing hourly extraction helpers can move into bounded ETL jobs; switch the existing hourly API to the prepared records after parity tests, without changing its public contract.

Use shared response conventions: schema/content version, location identity, source issue/run or observation time, server generation time, freshness/expiry, units, coverage, and explicit unavailable reasons. Keep missing values distinct from zero. Support conditional requests with stable content versions; a polling timestamp alone must not make content appear changed.

## Milestone 0 — Foundations and early risks

1. **Capture daily forecast history.** Preserve accepted raw bulletins and normalized regional versions before replacing the latest pointer. Deduplicate by source identity and normalized-content hash, retain corrections, and publish atomically. Polling the same bulletin does not create another forecast version.
2. **Prepare comparable model snapshots.** After a model run is ingested, batch-sample registered forecast-region points for each required field/time. Load each raster once per batch where practical. Store product, domain, run time, valid time, region-coordinate version, units, and completeness. Do not combine runs inside a comparison snapshot.
3. **Bound the work.** Start with Halifax and a configured Atlantic Canada rollout set; expand after measuring ingest lag, sampling cost, and storage. Client requests never register collection jobs. Proposed retention is 30 days of compact forecast snapshots/comparisons; retain existing model-asset policies rather than keeping extra GRIB/COGs for this feature.
4. **Define contracts and fixtures.** Add representative complete, partial, stale, corrected, and missing-data responses before building screens. Make new features tolerate an older server without disabling the existing forecast or map.
5. **Run a widget feasibility spike.** Verify signing/App Groups, shared storage, and direct HTTP requests to `wolf359.iolan:18080` on a physical iPhone, including after the main app is suspended. Confirm the host app's local-network permission flow and an understandable setup state when access is not yet allowed.

Apple documents that extensions generally share their containing app's local-network permission, and that some background operations cannot prompt when permission is undetermined. The simulator does not implement local-network privacy, so this gate requires a device. [Apple local-network guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

**Exit gate:** two comparable forecast versions can be stored and read; preparation is bounded and idempotent; a signed widget can display shared data and the physical-device network behavior is understood. History starts accumulating immediately. Do not fabricate or promise recovery of daily bulletins already overwritten.

## Milestone 1 — Feature 3: “What changed?”

### User experience

Add a compact, expandable **What changed?** section below the daily/hourly selector. Show up to three significant changes, with both forecast issue times. Example presentation, not actual weather data:

- “Tuesday afternoon is now 3°C warmer.”
- “Tuesday night rainfall increased from 4 mm to 10 mm.”
- “Peak wind gusts increased from 40 to 55 km/h.”

Expansion shows the affected periods and old/new values. Separate official daily/nightly bulletin changes from model-hourly changes and label their sources. Routine updates preserve the section's layout and expanded state.

The first baseline is **the previous published comparable forecast**, not “since you last opened the app.” Later, a 24-hour comparison can be added without requiring per-user server history. With only one version, show “Building forecast history”; distinguish that from “No significant changes” and incomplete comparison coverage.

### Server work

- Store immutable bulletin versions, run-specific point snapshots, and prepared comparison results. Use stable region IDs and coordinate versions.
- Match daily/nightly periods by their actual time intervals and period type, not relative names such as “Today.” Match hourly values by valid timestamp, same model/product/domain, and the same point.
- Compare only overlapping, sufficiently complete coverage. A missing value becoming available is availability information, not a zero-to-value weather change. Keep corrections auditable and reprocess affected comparisons safely.
- Compute temperature, precipitation, probability, and wind changes only where both sources supply comparable quantities. Distinguish percentage points from percentages, precipitation accumulation intervals, millimetres of liquid equivalent, and centimetres of snow depth. Never compare different accumulation windows.
- Initial configurable highlight thresholds: temperature 2°C; gusts 10 km/h; daily rain probability 20 percentage points; rainfall 2 mm absolute change plus 25% relative change where the old amount is nonzero. A zero baseline uses an absolute threshold only. These are product defaults to tune, not official hazard criteria.
- Generate deterministic structured highlights and short templates on the server. Do not require an AI service. Defer precipitation-onset narratives until event matching and data completeness can be verified.
- Publish a comparison only against an eligible prior version. Do not make partial newest-run ingestion look like a sudden forecast improvement or deterioration.

**Proposed API:** `GET /api/v1/forecast/changes?area_id=…&baseline=previous`. Return source-separated comparison groups, baseline/current identities, coverage, highlights, and detail rows. Reading it performs no ETL.

**Exit gate:** correct results across midnight, daylight-saving changes, unchanged re-ingestion, corrections, different run coverage, location changes, and missing fields; no false highlights caused solely by the advancing 72-hour window. Failure of this optional endpoint leaves the normal forecast usable.

## Milestone 2 — Feature 5: Nearby weather stations

### User experience

- Add **Weather stations** to the existing map-data chooser, retaining the Model/Radar/Satellite top bar. Treat it as a standalone data selection consistent with existing observation layers.
- Show station markers, with a selectable observed quantity such as temperature, wind, or precipitation where available. Cluster dense areas; distinguish stale/missing values visually and accessibly.
- Tapping a station opens its name, distance, observation time, source, available measurements, and a recent 24–48-hour chart. Keep gaps visible instead of interpolating observations.
- Add a nearby-observations section to Forecast with a few suitable stations. Prefer a fresh valid report over a closer unusable one. Explain when no fresh station is nearby.
- Explicitly say **Observed at [station]**. Station conditions are not a measurement at the user's exact location, and an observed/forecast difference is not automatically a forecast error.

### Data and ETL

Use ECCC land-station SWOB-ML for the first release. ECCC provides station reports through its Datamart and AMQP notifications, a daily-updated station list, and correction identifiers; reporting cadence varies, including some minute reports. Validate the parser against its linked product guide and real fixtures. Defer marine, partner, and personal-station feeds. [ECCC station-data documentation](https://eccc-msc.github.io/open-data/msc-data/obs_station/readme_obs_insitu_swobdatamart_en/)

- Reuse the existing server ingestion infrastructure with allowlisted observation notifications, bounded retries, deduplication, a daily station-catalogue reconciliation, and bounded recovery after outages. Start in Atlantic Canada, then expand Canada-wide after load validation.
- Store station identity/network, public coordinates/elevation, and metadata revisions. Observation rows retain observed/received times, source revision/hash, quality flags, original units, and measurement/accumulation intervals.
- Normalize supported measurements server-side. Missing, trace, suspect, and unsupported values remain explicit. Do not silently combine old individual measurements into a seemingly fresh complete report.
- Maintain a fast latest-acceptable-observation view plus indexed history. Handle corrections and out-of-order delivery without allowing an older report to replace a newer one.
- Make freshness cadence-aware. A starting policy is stale after twice the expected reporting interval plus a grace period; unknown cadence is labeled conservatively and monitored. Show original observation time even after a successful server refresh.
- Proposed initial retention: 30 days normalized observations and seven days raw reports, with a storage-budget check before enabling cleanup. Limit minute-report subscriptions in the initial rollout. No existing data is deleted by this plan.

### Read APIs and limits

Proposed endpoints:

- `GET /api/v1/observations/stations?bbox=…&field=…` — bounded map results, with pagination or server clustering.
- `GET /api/v1/observations/nearby?latitude=…&longitude=…` — quality/freshness-aware ranking and server-calculated distance; suggested default radius 100 km, maximum five results.
- `GET /api/v1/observations/stations/{id}` — metadata and latest observations.
- `GET /api/v1/observations/stations/{id}/history?field=…&start=…&end=…` — capped time range and resolution; any aggregation happens server-side.

Use PostGIS geography indexes and strict bounding-box/radius/time limits. Support antimeridian bounds. Request cancellation and selection identities prevent late results from another map area or forecast location appearing. Do not retain device-coordinate history or log precise coordinate query strings; station coordinates themselves are public metadata.

**Exit gate:** repeat/corrected/out-of-order reports are safe; unit and quality semantics are tested; unavailable precipitation never becomes zero; stale and no-coverage states are clear; map requests remain bounded; observations continue collecting with no clients open.

## Milestone 3 — Feature 6: Home and Lock Screen widgets

### First release

- **Small Home Screen:** location, forecast temperature/icon, available daily high/nightly low, and data age.
- **Medium Home Screen:** the same summary plus the next six server-prepared hourly entries and forecast precipitation where available.
- **Lock Screen:** inline, circular, and rectangular variants with a compact forecast temperature/condition or daily range, according to available space.
- Tapping opens the matching location in Forecast. Do not overwrite the user's saved default simply because they tapped a fixed-location widget.

Use explicitly forecast values in the first release; do not label model temperature as a fresh observation. A later station-oriented widget can use the observations API with its source and age intact.

Configuration offers a fixed saved location or the app's default location, initially Halifax. Also support **Last app location**, explicitly meaning the most recent foreground-selected region, not live background GPS. An unconfigured installation uses Halifax when data is available; an unreachable unconfigured server shows setup guidance, not invented weather.

### Implementation

1. Add a WidgetKit extension and a small shared module/source group for display models, weather icons, date formatting, and same-origin server configuration. Keep it independent of MapKit screens and location services.
2. Add a provisioned App Group to the app and extension while preserving existing app signing. Store only a small, versioned, per-server/per-region display snapshot and widget configuration there; migrate without erasing ordinary app preferences. App Groups provide a shared container between an app and its extension. [Apple App Groups documentation](https://developer.apple.com/documentation/xcode/configuring-app-groups)
3. Add `GET /api/v1/widgets/forecast?area_id=…`. The server prepares compact display/timeline entries, precipitation summaries, condition codes, source times, expiry, and suggested next refresh. No widget downloads model files, processes raw observations, or computes weather summaries.
4. Render cached data immediately. When WidgetKit permits, request the prepared payload directly from the configured server with bounded timeout and the existing same-origin/HTTP rules. Use atomic, version-checked shared-cache writes so older responses or another server's data cannot overwrite the current snapshot.
5. Build timelines from the server's dated forecast entries. Future forecast entries must not imply a new observation or reset the original issue/update time. Include explicit stale/expired states; show no-data guidance once usable coverage ends.
6. Request timeline reloads when the app receives changed matching data or configuration, not on every screen refresh. A suggested 30–60-minute network refresh is advisory: iOS controls reload budgets and scheduling, so there is no five-minute or live-update guarantee. [Apple widget refresh guidance](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date)
7. Carry over the necessary scoped HTTP transport configuration to extension requests; keep the local-network usage description in the containing app as Apple specifies. Verify this on the actual device rather than assuming the app's successful connection proves extension networking works.

With the LAN-only address, fresh remote updates require the phone to be able to reach that network. Off-network widgets should retain clearly dated usable forecasts and explain loss of connectivity. Public hosting, VPN setup, widget push notifications, Live Activities, and an Apple Watch app are outside this release.

**Exit gate:** correct layouts across supported widget families, larger text, appearance/tint, and privacy settings; correct deep links; multiple locations/server changes stay isolated; locked/unlocked device, first setup, denied permissions, Wi-Fi changes, offline periods, app suspension, and expired coverage all behave honestly. Simulator success alone is insufficient.

## Delivery, verification, and rollout

Implement in this order: **history/preparation and widget spike → forecast changes → stations → complete widgets**. Begin history collection before the comparison UI so real baselines accumulate. Stations do not depend on comparison calculations; widgets reuse the common prepared-data contract and do not need to wait for a station-specific widget design.

Likely code areas:

| Area | Planned work |
| --- | --- |
| Backend `database/`, `python/weather_ingest/`, `airflow/dags/` | Numbered migrations, immutable revisions, batch preparation, station collection, bounded retention and reconciliation |
| Backend `python/weather_api/` and tests | Prepared read models, additive APIs, validation, freshness, provenance, contract fixtures |
| iOS `Models/`, `Services/`, `App/AppStore.swift` | New response models, optional API capabilities, selection-safe state, shared widget configuration/cache |
| iOS `Features/Forecast/`, `Features/Map/` | Change details, station map/details, silent optional-section updates |
| iOS project and new widget/shared targets | Signing-preserving extension setup, App Group, timelines, deep links, family previews |

For each milestone:

1. Add parser/calculation/database/API tests and iOS decoding/state/UI fixtures. Run existing forecast, location, map-selection, and animation regression tests.
2. Verify that repeated requests cause no upstream retrieval or ETL; measure API latency, payload size, batch duration, database growth, and queue lag on the current server before setting performance budgets.
3. Back up the database and apply checksum-tracked migrations explicitly using the existing deployment procedure, never on API startup. Deploy server additions before clients depend on them.
4. Start ingestion/preparation with bounded coverage and inspect real output. Monitor last successful ingestion, freshest usable data, failed/quarantined reports, comparison readiness, queue lag, and disk admission limits.
5. Enable each feature independently. Missing capability or a failed optional endpoint must not replace the main forecast with a generic “server needs an update” error.
6. Roll back by disabling the affected feature/job and restoring the prior read path; preserve collected history. Do not drop new tables or delete source archives as a rollback shortcut.

Creating the original plan performed no deployment. Its subsequent implementation applied the migrations, deployed the jobs/APIs, and installed a signed app/widget build as recorded in the implementation report above. Do not treat the physical-device widget exit gate as passed until its remaining checks are completed.
