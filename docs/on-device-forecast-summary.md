# Automatic on-device forecast outlook

iOS 1.0 (7), 2026-09-07 (deployment completed after midnight UTC).

The final signed build 7, including its widget extension and server-fact safeguards, was installed on the connected iPhone at 00:03 Halifax time on September 8. App identity and signing settings are unchanged.

“What changed?” and “Summary” remain adjacent text-height buttons below the daily/hourly selector. Summary is now only a show/hide control. The foreground forecast loader automatically prepares the summary when its data has loaded, even when Summary is collapsed or another tab is open. Closing the disclosure no longer cancels generation.

## Wording and data

The server's city-forecast ETL now prepares a compact weekly briefing: the sky pattern, possible versus expected precipitation days, and daytime/overnight temperature ranges. These calculations happen on the server. The native model receives these concise facts instead of a timetable. Older server snapshots without briefing metadata retain the bounded daily/nightly transcription path. Granular hourly rows, clock intervals and source timestamps are excluded from the narrative prompt. The full daily and hourly forecast screens are unchanged.

Guided generation requests three separate, short English sentences: the overall pattern, useful wet-weather timing or the main change, and temperatures. Each sentence has a distinct role to prevent repetition. The prepared precipitation and temperature sentences must be preserved exactly. If the native response changes those facts, introduces certain unsupported condition terms, or fails the prose checks, the app displays the server's already-readable three-sentence paragraph instead, explicitly labeled as server-prepared. This prevents the tested native model errors of invented snow, definite rain replacing possible showers, and temperatures written as “18s.” Validation also rejects incomplete sentences, lists, headings, copied intervals and excessive length. Server briefing facts expire at the next covered period boundary and are refreshed by ETL.

The phone handles wording and display of server-provided weather, not new weather calculations or collection. It uses Apple's local Foundation Models model, with no tools, cloud AI service, device-coordinate input or upstream weather collection. iOS 26+ and a ready, enabled Apple Intelligence model are required for the native summary attempt; the rest of the app remains compatible with iOS 17+. Generated wording may still make mistakes; the authoritative forecast and original issue time remain available.

## Refresh and lifecycle

- Identical forecast content is reused in memory. Polling metadata and hourly model changes alone do not launch inference.
- A changed bulletin prepares a replacement automatically while retaining the previous same-location text and issue time. No loading spinner or extra status row appears during this regular update.
- Region/server changes clear the previous summary. New data supersedes an unfinished old request; generation identities reject late responses.
- The shared app store owns the summary, not the disclosure. App backgrounding cancels unfinished work; returning to the foreground can resume it after loading.
- A failed automatic attempt is not retried on every polling cycle. The expanded panel explains availability/errors and offers an explicit retry.
- A 30-second watchdog rejects a late response. Fully expired forecasts clear the old text without asking the model to infer weather.
- Nothing is generated in a background execution task or in widgets.

## Compact forecast layout (build 8)

The forecast header now contains only the location, original bulletin issue date/time,
and Show on map. It uses a compact horizontal layout at normal text sizes and stacks
vertically at accessibility text sizes. The bookmark action lives in the navigation
toolbar; choosing a region and using the phone's location are unchanged. Actual
connection/location problems and an overdue-forecast warning remain outside the header.

Nearby observations starts collapsed for each forecast region. Its station readings
and detail/history sheet remain available when expanded. Routine refreshes do not
reset the disclosure. What changed? and Summary share a single optional selection,
so only one can be expanded at a time; tapping the open button closes it. Nearby
observations is independent. Automatic summary preparation still belongs to the
forecast loader and continues regardless of which panel is open. These are iOS-only
presentation changes and require no server update or restart.

Build 8 verification (September 8): all 123 unit tests and eight focused simulator
UI scenarios passed. They cover the three-item compact header, toolbar saving and
map navigation, accessibility-size header wrapping, initially collapsed and
independent observations, mutually exclusive insights with prepared-summary reuse,
silent daily/hourly refreshes, daily/hourly navigation, Halifax fallback and a
persisted default location. Screenshots were inspected. The signed app and widget
extension were installed on the connected iPhone at 08:39 Halifax time; physical
UI automation was not run. Bundle identities and the HTTP server address are unchanged.

## Town labels

The server ETL now preserves an official city-site `locality` for each forecast region. It prefers the first covered locality explicitly named in the region title; a small validated county preference table handles names such as New Glasgow and Kentville. Otherwise it uses a deterministic covered official site, never invented geocoding or population rankings. Areas without a city site retain their official place label.

The API and prepared widgets include this optional field. The iPhone uses it in forecast headings, selection, map details, saved places, defaults, summaries and widgets. Halifax is displayed as “Halifax.” Full region names remain searchable and stable region IDs, coordinates and saved selections remain intact. Old caches decode without the new field, with conservative compatibility labels until refreshed. Saved labels migrate by matching existing IDs. Actual observation station names are not shortened.

The address remains `http://wolf359.iolan:18080`. The weather API and Airflow services were rebuilt/relaunched; official forecast collection and widget preparation jobs completed successfully with the new labels. No databases were dropped, schema changes required, or data collection moved to clients.

## Verification

- 123 iOS unit tests passed, including automatic preparation, duplicate refreshes, revised content, cancellation, expiry, timeout, failure retry, sentence validation, factual fallback, and saved-label identity preservation.
- Simulator UI checks passed for preparing a real native summary before opening the button, compact expansion/collapse, silent daily/hourly refresh layout, and persisted default-location selection.
- A separate dedicated-simulator acceptance check exercised the live Halifax server and native inference. Native model wording is still subject to manual quality review on the phone; physical UI automation authorization was not retried.
- Final visual acceptance showed three concise native-produced sentences: mixed sunshine/cloud, possible showers Tuesday/Sunday versus expected showers Thursday, highs 18–21°C and lows 9–14°C. No incorrect snow, copied timetable, or malformed temperature units appeared in that final check. Four final UI scenarios passed. Physical-device rendering was not automated.
- The live simulator test is opt-in: set `TEST_RUNNER_WEATHERATLAS_LIVE_SUMMARY=1` when running `testLiveHalifaxSummaryOnSimulator`. Normal automated tests do not depend on the LAN server. A simulator test-runner busy/preflight failure was resolved before the final passing suite; it was not an application test assertion failure.
- 46 focused backend tests passed for city ingestion, API compatibility, prepared forecast insights, uncertain precipitation and missing-temperature preservation. Live regional/widget responses expose “Halifax”; the regional API also exposes the prepared weekly briefing.

Primary API references: [Apple Foundation Models](https://developer.apple.com/documentation/foundationmodels), [generation and availability](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models). Compiled against the Xcode 26.3 SDK.
