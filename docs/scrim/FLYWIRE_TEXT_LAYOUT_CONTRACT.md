# Flywire Chromium-authored text-layout contract

Date: 2026-08-11

Protocol: Flywire v1, backward-compatible optional extension

## Gate result

The forced-break text-fidelity gate **passes** for the supported static-text
slice. Chromium remains the visual line-breaking authority; Scrim shapes and
draws each published visual line with CoreText.

The representative ten-fixture matrix covers plain text, explicit newlines,
shrink-to-fit near wrapping, balanced multiline text, mixed rich-text weights,
left/center/right alignment, and regular/bold controls. All visual line ranges
and selected PostScript faces match. Maximum measured deltas are:

| Measurement              | Maximum delta |
| ------------------------ | ------------: |
| Full line advance        |      0.040 px |
| Rich run advance         |      0.040 px |
| Horizontal line position |      0.016 px |
| Baseline position        |      0.498 px |
| Total block height       |      0.491 px |
| Total block top          |      0.245 px |

These are subpixel raster-grid differences, not layout divergences. The pinned
gate tolerances are 0.25 px for line/run advances and horizontal position,
0.75 px for baselines, and 0.55 px for block geometry.

Artifacts:

- `scrim/Fixtures/forced-break-fidelity-fixtures.json`
- `scrim/Artifacts/forced-break-chromium.json`
- `scrim/Artifacts/forced-break-coretext.json`

## Wire representation

`FlywireTextItem.visualLines` is an optional ordered array:

```json
{
  "text": "Great is Your faithfulness\nMorning by morning new mercies I see",
  "runs": ["the existing structured Flywire runs"],
  "visualLines": [
    { "location": 0, "length": 26 },
    { "location": 27, "length": 19 },
    { "location": 46, "length": 17 }
  ]
}
```

Each entry is a half-open `location`/`length` range measured in UTF-16 code
units, the indexing model shared by browser DOM `Range`, JavaScript strings,
`NSRange`, and `NSAttributedString`.

The canonical text is exactly `runs.map(run.text).joined()`. Visual ranges do
not split, copy, flatten, or restyle those wire runs. A line can cross any
number of rich-run boundaries. Scrim creates the full attributed string once
and takes an attributed substring for each range, so CoreText retains the
original attributes and owns shaping, fallback, glyph choice, and glyph
positions.

Each run also carries Chromium's effective computed presentation style, not
only CSS declarations stored on the FreeShow item. The optional v1 typography
extension includes:

- the resolved CSS family and, when deterministically known, the exact
  PostScript face;
- effective font size, numeric weight, font style, fill, underline, letter
  spacing, word spacing, and pixel line height;
- structured text-shadow values, text stroke width/color, and text transform;
  and
- item-level computed horizontal and vertical alignment.

`lineHeightPx` is the authoritative computed line-box height. The older
unitless `lineHeight` remains a backward-compatible fallback. Likewise,
`fontPostScriptName` takes precedence over family/trait synthesis when Scrim
has registered that exact authored face.

Explicit authored newlines are excluded gaps between adjacent visual ranges.
Soft visual wraps have contiguous ranges. Trailing wrap whitespace stays in
the preceding range, matching Chromium's `white-space: pre-wrap` model.

## Publisher obligations

FreeShow measures the actual rendered output DOM after all layout-affecting
work is complete:

- template and rich-run styles are applied;
- dynamic values and visible-line selection are resolved;
- output scaling and the final text container are present;
- shrink-to-fit has completed; and
- Chromium has performed `text-wrap: balance` or the applicable normal wrap.

For each rendered rich-text span, the publisher reads `getComputedStyle` at
that boundary and serializes the effective values after defaults, inheritance,
templates, output scaling, and autosize have all run. Captured span text must
still match the corresponding resolved Flywire run boundary before its style
is attached, preserving rich-text run identity.

The publisher reconstructs canonical text from the rendered
`.textContainer` nodes, treats `<br>` and authored line blocks as newlines, and
groups grapheme DOM ranges by visual line. It attaches a measurement only when
the rendered text exactly equals the resolved Flywire text and the measured
box matches the Flywire frame within 0.5 px. Preview, autosize-precompute,
stage, scrolling, chord, and list copies do not publish ranges in this slice.

A text-bearing scene is published atomically. Measurements are scoped to the
authored show/layout/slide identity as well as output and item ID; a
measurement from the preceding slide cannot satisfy the next scene. FreeShow
holds a scene until every supported text item has a matching completed DOM
measurement, then publishes the complete scene once. Exact duplicate resolved
scenes are suppressed so a late redundant measurement cannot restart the
transition. Completion of the final required measurement releases the scene
immediately. Synchronous FreeShow store changes are coalesced into the next
task, but the publisher adds no fixed scene-settle delay. No source-style
intermediate scene is presented.

The output renderer may precompute a bounded set of adjacent text slides to
remove this gate from the take path. Such probes must live inside the same
output styling/inheritance context as the visible slide. Their cache key
includes the fully template-resolved item, effective output style, target
resolution, and authored slide identity. A probe rendered under root/default
inheritance is not a valid measurement for the output and must never seed a
scene.

No shaped glyphs, glyph IDs, outlines, or rasterized text cross the wire.

## Receiver obligations

When `visualLines` is present, Scrim validates before accepting the scene:

1. run text concatenates exactly to `text`;
2. ranges are ordered, non-overlapping UTF-16 character boundaries;
3. each range is inside `text` and contains no explicit newline; and
4. every non-newline code unit is covered exactly once; uncovered gaps contain
   newlines only.

An invalid forced layout rejects the Flywire envelope. It must not silently
fall back to a different native wrap.

For a valid layout, Scrim creates one `CTLine` per attributed substring. It
does not invoke a CoreText framesetter to choose breaks and does not implement
CSS balancing. CoreText still performs native shaping within each fixed line.
Horizontal flush uses the Flywire alignment. Fixed CSS line height is translated
to line-box height, with the natural ascent/descent box centered for baseline
placement. Vertical alignment is applied to the resulting complete block.

When `visualLines` is absent, the v1 compatibility path retains CoreText's
independent wrapping. That path is not claimed to preserve Chromium-balanced
layout; fidelity-sensitive FreeShow text must carry the authored ranges.

## Deliberate non-contracts

This extension does not standardize Chromium's balancing algorithm, publish
shaped glyphs, or rasterize browser text. It also does not promise exact
antialiasing parity between Chromium and CoreGraphics. The contract preserves
authored visual breaks and rich-run identity while leaving platform-native
font shaping and rasterization in Scrim.
