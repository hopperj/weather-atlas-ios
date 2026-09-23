# Single-selection iOS map

Implemented 2026-09-07, build **1.0 (3)**. This is a native UI/display change;
the web application, server APIs, collection jobs, model calculations, and
scientific validation gates are unchanged.

## Interaction

The **Model / Radar / Satellite** segmented control stays at the top of the map.
The non-imagery weather-data selector and compact model-source menu sit on the
row directly below it, and hide when Radar or Satellite is selected. The top tabs
remain usable while catalogues load or a mode has no collected frames. Returning
to Model restores the previous weather quantity and source; each imagery tab
remembers its selected product. Mode changes retain the existing cancellation,
single-selection and rendering rules.

The toolbar's **Map data** button remains available in every mode, including for
satellite-product selection and standalone fire observations. A single searchable
list presents plain-language names. Provider/model labels appear beside them in smaller,
secondary text; narrow screens and large text wrap the source onto a second
line without truncating the data name. A checkmark and accessibility selected
trait mark the sole active choice. Tapping it again does not deselect it.

Common choices come first: Temperature; Rain & snow amount (1 hour); Wind speed;
Wind direction; Wind gusts; Humidity; Cloud cover; Snowfall; Rain radar;
Satellite — visible/infrared; Fire hotspots. Availability determines which rows
exist. Pressure, air quality, precipitation analyses and experimental smoke
fields follow under **More data**; raw wind components appear last.

Fields with the same server field code appear once rather than once per model.
All supporting sources appear in the model-source menu below the top tabs, and
also remain accessible under the collapsed **Source & display options** section.
Choosing a different source preserves the selected quantity.
For a new quantity, retain the existing source if it supplies that field;
otherwise choose a source with a collected model run, then server priority.
Coverage selection appears when there is more than one domain. Precipitation
windows, preliminary/final analyses, percentiles, and PM2.5 versus PM10 are not
collapsed into misleading identical labels. Unknown fields retain their server
name instead of being silently hidden.

Radar and satellite images update automatically every minute while the map is
active. The manual **Refresh images** (formerly **Refresh frames**) option has
been removed to keep the selector simple; automatic updates are unchanged.

The source catalogues load when the map is first opened, with at most four
requests at once, so its model-source menu is ready without opening a sheet.
They do not run during the app's Forecast startup. A failed
source produces a retryable warning; successfully loaded sources remain usable.
Once started, the bounded catalogue finishes even if the sheet closes; reopening
joins the same request. Selecting a quantity before the initial coverage metadata
arrives explicitly loads that metadata instead of leaving the map empty.

## Exclusivity and rendering

- `selectedFieldCode` is a single value with a private setter. Array access is
  derived for existing request interfaces; no selection can append another field.
- Scalar model data uses one resolved raster and one opacity slider. Independent
  wind/fire toggles and per-layer opacity overrides were removed.
- **Wind direction** uses the server's existing 10 m vector endpoint, with no
  raster under the arrows. It uses the supporting wind-component timeline but
  does not display a hidden component field. Wind speed is also visible in arrow
  callouts. Vector requests remain viewport-bounded and cancellation-safe.
- A standalone wind frame installs its annotations and waits for the existing
  two-display-tick fence before enabling the full viewing interval. Scalar and
  imagery frames retain the complete-visible-tile/draw fence. The speed choices
  are 1×/2×/4×/8× = 0.75/0.375/0.1875/0.09375 seconds per fully displayed frame; no frame is
  skipped to keep up.
- **Fire hotspots** uses only satellite detection markers. An explicit available
  observation-date picker replaces the model playback controls. The latest
  available day is selected initially; **Latest available** refreshes the dates.
  Dates/points are not inferred from the previously displayed model time.
- Changing the data selection cancels pending raster/sample/vector/hotspot work,
  clears prior display metadata and observation points, and changes the renderer
  context. Late responses cannot reintroduce a previous overlay. Switching between
  wind arrows and a wind-component raster changes context even when both use the
  same underlying component timeline.
- Changing a frame of the same data selection still holds the previous complete
  frame until its replacement is drawn. Changing the data selection clears the
  unrelated image, avoiding an old dataset being shown with a new name.

Apple Maps, location markers and a selected sample pin are navigation aids, not
additional selectable weather datasets. Existing map-to-forecast navigation,
provider attribution and experimental smoke warnings remain.

## Verification

The restored top-navigation update passed all 99 unit tests and three focused
map UI tests. Model, Radar and Satellite screenshots were visually checked:
both selectors are below the bar in Model and absent in the two imagery modes.
The checks also cover source restoration, toolbar access to imagery options,
standalone wind/fire data and map-to-forecast navigation. No server changes or
physical-phone installation were needed for verification; rebuild the app to
install the updated layout on the phone.

Unit tests cover source deduplication/ordering, common names, distinct time-window
and scientific labels, single-field replacement, repeated selection, source
changes, mutually exclusive raster/vector/hotspot/imagery selections, cleared
render contexts, stale hotspot cancellation, and standalone wind playback gating.
The existing buffered playback tests remain in place.
Mode-navigation regressions also cover remembering model quantity/source and
satellite product, repeated-tab no-ops, empty imagery modes, choosing a tab before
its catalogue arrives, and an early round trip back to Model.

UI tests exercise the sorted list and secondary source labels, selected state,
alternate model selection, standalone wind/hotspots, observation-date controls,
switching back to a sampled weather field, radar/satellite choices, and map to
forecast navigation. The fixture now includes two forecast models and several
quantities so deduplication and source selection are actually exercised.
The top-tab UI test checks all three labels and selected states, verifies the
model/data controls are below the bar and absent in imagery modes, changes the
model from the new inline menu, and confirms that the previous selection returns.
It also opens display options from the toolbar while the model row is hidden.

Install the rebuilt app from Xcode to use this change on a physical phone;
Settings → About should show **1.0 (3)**. Signing settings and bundle ID are
preserved, and no physical-device installation is performed by the code change.

Verification completed with Xcode 26.3 / iPhone 17 Pro simulator, iOS 26.3.1:

- All 80 unit tests passed. All 12 UI tests passed; the three affected map UI
  tests were rerun with the final lifecycle/cancellation changes and passed.
- The simple-list/source-selection UI test also passed after the final neutral
  text/secondary-source styling adjustment. The menu screenshot was reviewed.
- The unsigned generic-iOS Release build passed and its packaged build number
  is `3`. Strict Swift formatting and Python fixture syntax checks passed.
- The temporary loopback test server was stopped after verification. No
  production server or ETL workflow was changed or restarted.

Result bundles (temporary local development artifacts):
`/tmp/weatheratlas-build/Logs/Test/Test-WeatherAtlas-2026.09.07_18-24-41--0300.xcresult`
(complete UI suite) and
`/tmp/weatheratlas-build/Logs/Test/Test-WeatherAtlas-2026.09.07_18-30-23--0300.xcresult`
(80 unit tests plus three map UI tests).
