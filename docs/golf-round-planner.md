# Saved golf rounds

Implemented in the iOS app, 2026-10-17. Development only until a new app build is
distributed; this feature does not require an API deployment or new ETL.

## Behaviour

- Golf opens to **Your next rounds**, with one card for each saved tee time.
  Add several rounds, including different times at the same course or rounds at
  different courses. **View round** shows just that round, including the two-hour
  before window, four-hour round and one-hour after window. The existing five
  outlook faces, weather preference checks and on-device explanations remain.
- **Add tee time** opens the round editor; its course chooser opens a map with
  a bottom search field. The duplicate **Find a Canadian course** bar is removed
  from the Golf page. Suggestions
  update as the user types. Selecting one moves the pin; **Use this course**
  confirms it. **Add tee time** is the only creation action on the main Golf page.
  To use a pin, open the editor's course chooser, tap or hold the map, verify the
  location, then use and optionally name the pin.
- The course map starts at the active Forecast region or exact Forecast map pin,
  not the previous golf location or previously selected course. Before a bulletin
  loads, the selected catalog/saved region or configured default supplies its
  coordinates; the built-in fallback is Halifax. The map occupies the visible
  space above the search panel and keyboard, so its center is not hidden by them.
- Up to five **Your usual courses** shortcuts appear immediately below the course
  chooser. They use the number of saved tee times (past and future), with the
  latest tee-time instant breaking ties, then a deterministic venue key. Repeated
  saves of one round do not inflate counts. Case/whitespace/diacritic variations
  and insignificant coordinate formatting are grouped; different locations remain
  distinct. Saved named pins can also be reused. Choosing a shortcut fills the
  course without a new map/search and preserves the entered local date and time.
  The list is derived from on-device saved rounds, not external course bookings;
  removing a saved round changes its course's usage count.
- The date row opens a calendar that closes immediately when a day is selected,
  including the already-selected day. Navigating months alone does not close it.
  Dates still follow the course's time zone and preserve the existing past-date
  editing and daylight-saving validation rules. No Calendar permission or booking
  integration is introduced.
- Apple Maps supplies course suggestions and country/time-zone metadata. Only
  results verified as Canadian are offered. On iOS 18+, search uses MapKit's
  golf POI category; iOS 17 uses a conservative golf/course-name search. Search
  is not an exhaustive Canadian course directory. If a course is absent, use a
  verified Canadian map pin. Pin lookup rejects non-Canadian or unverifiable
  locations rather than guessing a country or time zone.
- Each round stores the course-local date, hour, minute and IANA time zone.
  Travelling or changing the phone's time zone does not move the tee time.
  Nonexistent daylight-saving times are rejected; an ambiguous repeated time
  uses the first occurrence, matching the API.
- Upcoming cards are automatically arranged earliest first, including rounds
  added out of order and rounds whose date/time changes during an edit. The
  stored list and restored legacy lists use the same order. Comparison uses
  actual tee-time instants in each course's time zone; simultaneous rounds use
  a stable UUID tie-breaker. The collapsed past section remains newest first.
- Rounds beyond the API's today-through-six-days window remain saved as
  **Forecast pending** and make no forecast request yet. Within that window,
  insufficient model coverage remains unrated, never an invented poor face.
  Past tee times stay in a collapsed section until deleted; they do not request
  an obsolete forecast. This is not a historical weather archive.
- Cards refresh on entering Golf, foregrounding, the existing periodic forecast
  refresh, changed limits or pull-to-refresh. A failed refresh retains matching,
  dated weather with an error. Data for a different course, date or time is never
  shown as the edited round's forecast.

## Persistence and compatibility

`GolfSettingsStore` stores rounds as a versioned JSON array in UserDefaults under
`golfRounds:v1`. A UUID identifies each round independently, including two rounds
on the same day. Upsert and delete affect only that UUID. Invalid stored records
and duplicate IDs are filtered on restore. Round dates are not rolled forward.

The old `golfPreferences:v1` key still owns global weather limits and convenient
new-round time defaults. Existing limits survive the update. The previous screen
never persisted a selected date, so it cannot be safely migrated into a dated
round: users add their first saved round explicitly. Changing or removing one
round does not change another round or the regular Forecast location.

The app requests the existing `GET /api/v1/golf/outlook` endpoint with `days=1`,
the exact local date/time, coordinates, time zone and global limits. It validates
the response scope and count. There is no backend schema or rating change;
older app clients can continue requesting seven days. No course booking,
calendar integration, notification or cloud tee-time sync is implied.

Saved rounds and limits remain on the device. Apple Maps receives course searches
and pin verification; Weather Atlas receives each in-range round's coordinates,
schedule and limits for its weather assessment. No new location permission or
cloud AI service is introduced.

## Verification

`GolfRoundTests` covers persisted multiple rounds, independent edits/deletes,
legacy preferences, chronological add/edit/restore ordering, simultaneous times,
cross-province time-zone ordering, invalid and duplicate records, country/time-zone/date/DST
validation, pending/past request suppression, `days=1`, response scope checks,
and late search/pin/forecast responses. An opt-in
`WEATHERATLAS_LIVE_COURSES=1` test checks Apple Maps course search plus Canadian
and non-Canadian pin verification.

`GolfUITests` uses the local synthetic weather fixture and a simulator-only fake
course directory. It adds two courses, changes tabs, relaunches, checks a focused
single-round assessment, adds and names a pin, removes it independently, and
checks the shared weather-limit settings. It enters course search through
**Add tee time**, checks that the duplicate bottom search is absent, and verifies
that Add tee time remains available at accessibility text sizes without a separate
main-page Drop pin action. Pin creation is tested through the tee-time editor.
Test-only course data/reset flags are
excluded from Release builds. The fixture server respects the `days` parameter.

Initial development verification (2026-10-17): 207 tests passed, six unrelated opt-in tests
skipped, no failures. This includes the live Apple Maps check and three UI
tests. The unsigned generic-iOS Release build passed as 1.3 (26). A read-only
request to the current public API also confirmed `days=1` returns exactly the
requested course-local tee time. No production services were changed.

### Controls and chronological ordering — 2026-10-19

The duplicate bottom course-search bar and separate main-page **Drop pin** button
are removed. **Add tee time** is the sole main-page creation action; its editor
retains course autocomplete and Canadian pin verification.
The store sorts restored rounds and every saved edit/addition by the actual tee-time
instant, with a deterministic tie-breaker for simultaneous rounds. The screen uses
that canonical ordering, so editing a round can move its card without changing its
identity, other rounds, or forecast scope. No saved-data schema migration is needed.

Verification: all 215 iOS unit tests passed (seven opt-in checks skipped), including
four new ordering regressions for out-of-order additions/persistence, restoring old
unordered lists, edited dates/times, and course time zones/stable ties. All three
Golf interface tests passed, including course selection through Add tee time,
independent pin editing/deletion, persistence across tab changes/relaunch, absence
of the duplicate search bar and the accessibility-size Add tee time button. Screenshots were
visually checked. The unsigned Release app/widget build passed as 1.3 (26), as did
strict Swift formatting and diff checks. Initial Xcode startup stalls cleared on
retry; no simulator reset or data erasure was performed. The local test server was
stopped. No production deployment, phone installation or App Store upload occurred.

After simplifying the main page to Add tee time only, all three Golf interface
tests were rerun successfully. They also confirm that pins can still be created,
named, edited and deleted through the editor's course chooser. The unsigned
Release build and strict formatting/diff checks passed again; chronological
sorting and the saved-round schema were not changed by this UI-only revision.

MapKit reference: [local search](https://developer.apple.com/documentation/mapkit/mklocalsearch),
[point-of-interest filters](https://developer.apple.com/documentation/mapkit/mklocalsearch/request/pointofinterestfilter).

### Forecast-centered picker and course shortcuts — 2026-10-19

The course picker now starts at the Forecast location, including an exact forecast
pin, instead of the previous golf selection. Its map is laid out above the search
panel and keyboard so that the chosen location stays at the visible map center.
The editor offers up to five usual-course shortcuts based on saved rounds, and its
calendar dismisses after choosing either the selected day again or a different day.

New regression coverage checks ranking, the five-course limit, persistence,
repeated edits/deletes, name normalization, distinct locations, forecast region/pin
and fallback selection, and course-local calendar selections across a clock change.
Interface tests check a Sydney forecast opening the picker, the position and
one-tap use of course shortcuts, calendar dismissal, and an actually changed date.
Screenshots confirm Sydney is centered above the keyboard and that the shortcuts
and date control use the editor's existing appearance.

All 220 unit tests passed (seven opt-in checks skipped), and all five Golf interface
tests passed after the map layout correction. The unsigned Release app/widget
build passed as 1.3 (26), along with strict Swift formatting and
diff checks. The temporary local fixture server was stopped. These changes do not
require an API deployment, migration, or new permission; no production service,
phone installation, or App Store submission was changed.

Calendar reference: [single-date selection delegate](https://developer.apple.com/documentation/uikit/uicalendarselectionsingledatedelegate).
