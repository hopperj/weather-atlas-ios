# Forecast location map — build 9

Show on map now opens a full-screen location picker within Forecast, not the
Model/Radar/Satellite tab. The picker uses its own standard MapKit map containing
only city/town markers and the user's dropped pin. It has no weather tile layer,
station layer, playback, legend or weather sampling. Opening and closing it does
not mutate the other map's selected mode, product or viewport.

Users can tap or hold an empty part of the map to drop a pin, select a forecast
town marker (clusters zoom in), or search the server's available forecast towns.
The city list also searches original region names and provinces. Selecting a
town moves the map to its representative location. Use this forecast explicitly
confirms the selection; Cancel leaves the existing forecast selection unchanged.

Pins are sent only to the configured server's existing `/api/v1/forecast/nearest`
endpoint. The server chooses the regional forecast; the phone neither computes
proximity nor fetches weather from an upstream provider. The picker identifies
this as the nearest available regional forecast, not an exact-point forecast or
a claim that the point lies inside a verified forecast polygon. Out-of-coverage,
lookup and older-server errors disable confirmation until another choice succeeds.
Rapid selections and dismissal invalidate late responses.

Confirmation stores the chosen region ID and, for a pin, its exact coordinates
in server-scoped preferences so the picker reopens at that pin. This is one
explicit user selection, not GPS history. Choosing a different town or returning
to Use my location clears the pin. The Settings default is unaffected. Automatic
summaries, regular refreshes, daily/hourly forecasts and widget region selection
continue using the server's selected forecast region.

In build 11 the forecast location icon is a toggle. When following is on, tapping
it stops foreground location updates immediately and fixes the forecast to the
currently displayed region. It retains the bulletin, hourly/precipitation data,
summary and issue time in place, rejecting any late coordinate lookup. The held
region is saved as the manual selection; normal weather refreshes continue for
that region. The outline icon turns following back on. Stopping before the first
region arrives also persists an off state without silently restarting GPS; a
manual choice or another tap re-enables the appropriate workflow.

No backend update or restart is required. The default remains
`http://wolf359.iolan:18080`, and app/widget identities and signing are unchanged.

## Verification — September 8, 2026

All 130 unit tests passed, including seven new map-selection tests for server
matching, errors/retry, stale-response rejection, pin persistence, invalid pins,
city filtering and an annotation-only map surface. Five simulator UI scenarios
passed: the compact header, silent refresh, exclusive summary controls, preserving
the separate weather map on Cancel, and city/marker/pin selection with confirmation
and relaunch persistence. The latter verifies that opening the picker does not
request model/imagery catalogues, weather layers or point samples. Its initial
test locator was corrected to use MapKit's internal map accessibility element.

The final clean-map screenshot was inspected. Signed build 9 and its widget
extension were installed on the connected iPhone at 08:57 Halifax time. No
physical-device UI automation was run.

### Build 11 — location-following toggle

All 137 unit tests passed, including new coverage for holding the visible
forecast without restoring an older manual cache, rejecting late GPS lookups,
and persisting an early off state separately for each server. Four simulator UI
scenarios passed: the new on/off/relaunch/resume flow, silent daily/hourly
refresh, denied-location fallback and manual-region/GPS switching. The toggle
test also verifies that weather refreshes keep running without nearest-location
requests after following is stopped. Its outline-icon screenshot was inspected.

Signed build 11, including its widget extension, was installed on the connected
iPhone at 09:16 Halifax time. No physical-device UI automation was run.
