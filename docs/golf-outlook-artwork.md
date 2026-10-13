# Golf outlook artwork

Implemented locally 2026-10-13. The original-colour, alpha-transparent atlas is
bundled at `WeatherAtlas/Resources/Assets.xcassets/GolfMoodAtlas.imageset/`.
`GolfMoodIcon` selects the declared mood and weather cue; it does not classify
weather. Verified crop gutters keep adjacent raindrops/wisps out of each sprite.

Fourteen sprites are consumed: five plain faces plus three each for wind, cold
and rain. Excellent and Good always use plain faces. Cold uses the thermometer
alone for Mixed, and combines it with the toque for Poor and Very poor. Its
blue level falls progressively. Rain uses two drops alone for Mixed, then an
umbrella plus heavier rain for Poor/Very poor. Stronger expressions distinguish
Poor from Very poor. Unknown/stale/started forecasts have no mood face. Heat
uses a plain face, accompanied by the Heat text label.

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
