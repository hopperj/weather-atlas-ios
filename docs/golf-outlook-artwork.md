# Golf outlook artwork

Implemented locally 2026-10-13. The original-colour, alpha-transparent atlas is
bundled at `WeatherAtlas/Resources/Assets.xcassets/GolfMoodAtlas.imageset/`.
`GolfMoodIcon` selects the declared mood and weather cue; it does not classify
weather. Verified crop gutters keep adjacent raindrops/wisps out of each sprite.

Seventeen sprites are consumed: five plain faces plus three each for wind, cold,
heat and rain. Excellent and Good always use plain faces. Cold uses the thermometer
alone for Mixed, and combines it with the toque for Poor and Very poor. Its
blue level falls progressively. Rain uses two drops alone for Mixed, then an
umbrella plus heavier rain for Poor/Very poor. Stronger expressions distinguish
Poor from Very poor. Unknown/stale/started forecasts have no mood face. Heat
uses a separate `GolfHeatAtlas.imageset/golf-heat-atlas.png` strip derived from
the approved cold faces: no toques or snowflakes, warm red cheeks, and red
thermometers with increasing fill for Mixed, Poor and Very poor. The 2026-10-15
refinement leaves Mixed sweat-free, adds one sweat bead to Poor and three to
Very poor, preserving the expressions and thermometer progression. The API already
declares `primaryIssue: heat`; no API or production change is needed.

Heat integration verification: 11 focused Golf tests passed (two optional live
tests skipped), all 17 sprites were inspected on light and dark cards, and the
unsigned Release iOS app/widget build passed at version 1.3 (26).

The atlas was produced with the built-in image-generation tool, not the API/CLI
fallback, using the user-approved sheet as an editing reference. It is a new
versioned project asset, not a replacement of other weather icons. The subsequent
spacing-only alternative was not selected. Rendering tests exercise every sprite
on light and dark cards; the native Golf flow checks labels and absence of a
numeric rating. No image generation or network download occurs inside the app.

## Generation prompt

```text
Use case: background-extraction / precise-object-edit.
Asset type: one production-ready TRANSPARENT icon sprite atlas for the Weather Atlas iOS Golf page.
Input image is the approved visual reference. Preserve its polished yellow emoji heads, facial expressions, wind-wisp progression, cold thermometers and rain details.

Output a text-free, label-free image with a genuine transparent alpha background. EXACTLY FIVE equal-width columns and FOUR equal-height rows fill the entire rectangular canvas; no title, no margins outside the grid, no labels, no dashes, no cell borders, no background shapes, no shadows cast onto background. Centre each icon in its cell. All heads have the same size. Each complete icon, including weather accessories, fits within the central 80% of its cell with generous transparent clearance. Nothing crosses a cell boundary. Blank cells must be fully transparent. The atlas will be cropped into exact equal cells by the app.

ROW 1: the FIVE Standard faces from the reference, in column order Excellent, Good, Mixed, Poor, Very poor. Big joyful open smile; small pleased smile; neutral horizontal mouth; modest closed frown; much larger open miserable frown and tightly closed eyes. Preserve clear expression differences.
ROW 2: first two cells EMPTY. Columns 3, 4, 5 contain Mixed, Poor, Very poor WIND. Mixed has EXACTLY ONE cyan wind wisp; Poor has several stronger wisps and half-open weary eyes plus a modest frown; Very poor has the densest wind wisps, eyes tightly shut and a deep open frown.
ROW 3: first two cells EMPTY. Columns 3, 4, 5 contain Mixed, Poor, Very poor COLD. Mixed is the approved thermometer face WITHOUT A HAT, neutral mouth, chilly blue cheeks, blue thermometer and snowflake beside its head. Poor is the same approved Poor thermometer face with a BLUE KNIT TOQUE ADDED. Very poor is the same approved Very poor thermometer face, eyes shut and closed frown, with a BLUE KNIT TOQUE ADDED. Keep thermometer body sizes equal: Mixed has the reference's medium-low blue fill; Poor has a lower blue level, about half as tall; Very poor is almost bulb-only. Blue bulbs on all three. Keep hats within the cell, not covering the face or thermometer.
ROW 4: first two cells EMPTY. Columns 3, 4, 5 contain Mixed, Poor, Very poor RAIN. Mixed has the approved neutral face and EXACTLY TWO blue rain droplets, NO umbrella. Poor retains the approved modest closed frown, with heavier rain and a BLUE UMBRELLA ADDED above the head. Very poor retains the approved much deeper OPEN frown with worried brows, with the heaviest rain and a BLUE UMBRELLA ADDED. This is the user-requested progression: droplets alone for Mixed, umbrella plus more rain for Poor and Very poor.

Exactly FOURTEEN complete icons, occupying the stated 14 cells in a 5-by-4 grid. Do not add extra icons, text, checkerboard pattern, golf props, bodies, hands or a coloured background. Preserve the reference's art style and colour palette. No black/grey halo around cutouts. All unused pixels must be transparent.
```

## Heat strip generation prompt

Generated with the built-in image tool on 2026-10-13 using the bundled original
atlas as the editing/style reference. The output is a 2172 × 724 alpha-transparent
PNG, cropped into three equal cells by the app. The original atlas is unchanged.

```text
Use case: precise-object-edit.
Asset type: a production-ready transparent sprite strip of THREE heat-condition face icons for the Weather Atlas iOS Golf outlook.
Input image 1 is the existing approved sprite atlas, used as an editing/style reference. Derive ONLY the three Cold faces in row 3, columns 3, 4, and 5. Do not reproduce the full reference atlas.
Primary request: make heat variants of these Mixed, Poor, and Very poor cold faces. Keep the exact same polished yellow emoji rendering style, head proportions, black features, and distinct facial expressions. Remove ALL knit hats/toques, snowflakes, and cold-blue cheek colouring. Replace the cold thermometer with a hot RED thermometer beside each face. Use subtle warm/red cheeks instead of blue.
Composition: ONE horizontal row of THREE equal-width square cells on a rectangular canvas (3:1 aspect ratio). Each complete icon, including its thermometer, must be centred in its cell with generous genuine-transparent padding; keep heads at the same size and thermometers at the same size and placement. Nothing may cross cell boundaries.
Left cell, Mixed heat: approved neutral eyes and straight mouth, no hat; the red thermometer tube is about 50% full.
Middle cell, Poor heat: approved worried brows and modest closed frown, no hat; the same red thermometer tube is about 75% full.
Right cell, Very poor heat: approved tightly squeezed eyes and teeth-baring distressed grimace, no hat; the same red thermometer tube is almost 100% full.
All three thermometers have RED bulbs and red liquid columns, pale silver/white casings, matching the reference shape. Each red column is clearly higher than the previous one. The Very poor face must be visibly more distressed than Poor, not merely have a fuller thermometer.
Constraints: exactly THREE complete icons, no extra faces, no hats, no snowflakes, no rain, no wind lines, no sweat drops or unrelated accessories, no bodies, no text/labels/numerals, no title, no border, no background shape, no cast shadow, no watermark. Preserve the existing cold faces' identities and expression progression, changing only the heat cues and removing hats. Genuine alpha transparency, not a painted checkerboard or opaque background.
```

## Sweat refinement prompt

Edited with the built-in image tool on 2026-10-15. The final PNG replaces the
bundled heat strip at the same 2172 × 724 dimensions with genuine alpha; the
original no-sweat generation above is retained as provenance.

Both focused sprite tests passed after this refinement. Light/dark rendered
contact sheets were inspected, and the unsigned Release app/widget build passed.

```text
Use case: precise-object-edit.
Asset type: existing transparent three-cell Golf heat-face sprite strip for the Weather Atlas iOS app.
Input image 1: EDIT TARGET. Make only the sweat-bead additions requested below. Preserve the entire current artwork, style, facial expressions, yellow heads, warm cheeks, red thermometers, their progressively increasing fill levels, icon sizes, cell positions and transparent padding.
Left face (Mixed): leave entirely unchanged and sweat-free.
Middle face (Poor): add EXACTLY ONE clearly visible glossy cyan-blue sweat bead on the outer forehead/temple, following the face's curved surface. Do not cover an eye, eyebrow, mouth or thermometer.
Right face (Very poor / hottest): add THREE clearly visible glossy cyan-blue sweat beads at the forehead and temples, spaced apart and attached to the face, to show substantially more sweating than the middle face. Keep the existing squeezed eyes and teeth-baring grimace unchanged.
Maintain ONE horizontal row of THREE equal-width square cells on a 3:1 transparent canvas. The complete icons including sweat beads stay inside their own cells with transparent clearance at boundaries. Preserve the current head and thermometer placement, without enlarging or recentering them.
Constraints: change ONLY by adding these sweat beads; no hats, no snowflakes, no new accessories, no rain falling around the heads, no extra faces, no labels, no text, no borders, no watermark, no background. Preserve genuine alpha transparency; do not render a checkerboard.
```
