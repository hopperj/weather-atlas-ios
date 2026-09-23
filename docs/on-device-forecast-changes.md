# Important forecast changes

iPhone app 1.0 (17), September 13, 2026.

“What changed?” now displays a short English paragraph instead of numeric change
rows. When important candidate changes exist, the same Apple Foundation Models
service used by Summary receives the previous and current ECCC daily/nightly
bulletins and writes one to three sentences. This is on-device wording, not
weather collection or a new forecast. No cloud AI service, new permission, or
third-party weather source is involved.

## Source and relevance

The app requests `/api/v1/forecast/changes?area_id=…&include_forecasts=true`.
The server reads two distinct bulletins from ETL-owned immutable history and
returns their issue times, coordinates, absolute period times, conditions,
high/low temperatures, PoP and precipitation amounts. It preserves ranges and
unknown values. Metadata-only duplicate deliveries are skipped; weather
corrections issued at the same time remain eligible. Legacy clients receive
their existing response unless they opt in.

The server also supplies conservative candidate facts from comparable periods:

- Changed condition descriptions, which the model can dismiss as mere rewording.
- Temperature changes of at least 3°C and PoP changes of at least 30 percentage points.
- Amount changes of at least 5 mm or 2 cm, and at least 25%, using matching units
  and identical intervals. Range endpoints are retained; snow depth is not
  converted into liquid rain.

Minor hourly-model wind changes are not fed into this daily/nightly comparison.
Newly added days, elapsed periods, changing relative names and today's advancing
start time do not become weather changes. Missing values are not zero. Both
complete source bulletins accompany the candidate facts, so the model can
interpret context and preserve possible versus expected weather.

If no candidates remain, the panel directly says “No important changes were
found in the comparable forecast details.” That sentence is explicitly labeled
as a bulletin comparison, not claimed to be AI-generated. This prevents the
tested native model from turning a one-degree adjustment into a significant
change. Missing history or incomparable data gets an availability explanation,
not a claim that the forecast is unchanged.

## Generation and lifecycle

- Generation begins automatically once the paired data and displayed forecast
  agree, after the regular Summary finishes. Opening the disclosure is not required.
- The model receives absolute day/night intervals and both source issue times;
  relative labels such as “Today” are omitted. Input is bounded; oversized pairs
  are rejected rather than asymmetrically truncated.
- Guided generation produces an assessment and a paragraph. Validation limits
  output to three sentences and 85 words, rejects lists, invented quantities and
  selected unsupported weather terms, and removes padding about unchanged or
  unknown fields. These checks reduce errors, but are not a semantic proof;
  generated paragraphs retain the Apple Intelligence accuracy disclaimer.
- The existing summary cache, cancellation, superseding-request checks,
  30-second watchdog, availability messages and explicit retry are reused.
  Routine refreshes keep the old same-location text and issue time until the new
  paragraph is ready; no loading spinner is introduced.
- Missing/mismatched history clears an obsolete comparison. A changed region,
  source coordinates or displayed bulletin cannot reuse another pair's text.
- Summary and What changed remain mutually exclusive, text-height disclosures.
  Nearby observations remains independently collapsible and initially closed.

Actual generated comparisons require iOS 26+, an eligible iPhone and a ready,
enabled Apple Intelligence model. The rest of the app remains iOS 17+. The
no-important-change message does not require an available model. Forecasts are
not sent to a cloud AI service. Generation only runs in the foreground, not in
widgets or background execution jobs.

## Verification

Backend tests cover paired history, independent ETags, legacy compatibility,
minor-change suppression, missing data, period matching and important candidates.
Native tests include rain introduced, rain removed, possible showers, a one-degree
adjustment, an identical forecast, a full week with only one meaningful change,
the exact UI fixture pair, and a read-only comparison of live Halifax
bulletins. All 165 iOS unit tests passed with native acceptance enabled, and the
unsigned Release iPhone app/widget build succeeded. UI checks use the real model/availability path and synthetic weather
served only by the loopback test fixture, never a canned AI paragraph.

Both final insight UI tests passed with native paragraphs required, covering
compact controls, mutual exclusion, prepared-text reuse and independent nearby
observations. The daily/hourly background-refresh layout regression also passed.
Captured screenshots were inspected. The comparison panel has explicit
accessibility grouping so its container does not override the paragraph's label
or identifier. Results are in `.build/changes-summary-verified-unit.xcresult`,
`.build/changes-summary-final-accessibility.xcresult`, and the layout case in
`.build/changes-summary-verified-ui.xcresult` (that earlier run's two identifier
failures were corrected and rerun in the final accessibility result).

To include native acceptance in the unit run, start `Support/fixture_server.py`
on loopback port 8097 and set `TEST_RUNNER_WEATHERATLAS_NATIVE_CHANGES=1` and
`TEST_RUNNER_WEATHERATLAS_NATIVE_FIXTURES=1` for an explicitly selected iOS 26+
simulator. Without those opt-ins, native/live-network tests are skipped. The
`WEATHERATLAS_NATIVE_CHANGES` opt-in also makes UI acceptance require an actual
paragraph, rather than treating an availability/error message as success.

The API container was rebuilt and relaunched for this additive endpoint change.
No ETL jobs, database tables, or other services were restarted or changed.
No physical iPhone was automated or installed during this update.
