<p align="center">
  <img src="Assets/ScrimIcon.svg" alt="Scrim icon: a theater curtain with the FreeShow mark projected onto it" width="160">
</p>

# Scrim / Flywire prototype

**Experimental preview.** Scrim is currently intended for local testing and
rehearsals on the same Mac as the Flywire-enabled FreeShow build below. Keep
FreeShow’s Electron output available as a fallback. This is not a supported or
notarized production release.

Scrim is an optional native macOS scene sink. FreeShow continues to own show
state, templates, dynamic values, output-specific line selection, and its normal
Electron output windows. The prototype supports normal outputs containing a
solid, image, or native video background plus text. Unsupported active content
is named in every scene and remains visible on the Electron renderer.

**Tested setup:** one FreeShow output on one Mac, with photo and video slides
and some text. Multi-output shows and broader text styling are not yet
validated for live use.

## Run the vertical slice

### Start FreeShow with Flywire

Scrim is the renderer, not the show controller. Run it alongside the Flywire-enabled
FreeShow branch (`scrim/1.6.7-port`). The Scrim ZIP does not include FreeShow, and
a FreeShow build without **Scrim / Flywire** in Settings cannot feed it.

Use Node.js 22.12 or later and the
[FreeShow development prerequisites](../README.md#help-the-development).
Clone the [FreeShow fork](https://github.com/jquyatt/FreeShow) and run:

```sh
git clone --branch scrim/1.6.7-port https://github.com/jquyatt/FreeShow.git FreeShow-Scrim
cd FreeShow-Scrim
npm install
npm start
```

Quit any other FreeShow instance first. This dev launcher uses the normal
FreeShow user configuration and clears port 3000 before starting Vite.

1. Open **Settings → Connections** and enable **Scrim / Flywire**. The local
   endpoint is `http://127.0.0.1:5514` by default.
2. Open **Settings → Outputs**, select the output you want to test, and enable
   **Publish this output over Flywire**. Leave **Use Scrim instead of the
   Electron output window** off for the first test so Electron remains available
   as a fallback.
3. Start Scrim using one of the options below. Turn on **Present** and take a
   slide in FreeShow. Scrim subscribes to the `default` output unless you pass
   another output ID with `--output`.

### Local macOS package

Run `npm run scrim:package` from the repository root. It builds the native
release executable and writes `Scrim.app` and a ZIP to a new directory under
`dist/`. The result is ad-hoc signed for local testing, not notarized or ready
for external distribution. It does not include FreeShow: start a compatible
Flywire-enabled FreeShow build first.

The curtain icon in the macOS menu bar opens **About Scrim**, which shows the
version, build, credits, and a link to the FreeShow fork on GitHub. To link to
another fork, set `SCRIM_REPOSITORY_URL` to its HTTPS GitHub repository URL when
running `npm run scrim:package`. The full-color app icon is built from `Assets/ScrimIcon.svg`; the
monochrome menu bar adaptation is drawn at native display scale.

Opening `Scrim.app` in Finder starts a windowed preview subscribed to the local
`default` FreeShow output. The feed is chosen at launch: `--output` overrides
`SCRIM_OUTPUT_ID`, which overrides `default`. The menu bar shows the selected
feed; there is no live picker yet. For a deliberate HDMI test, quit that
instance and launch:

```sh
open -a /path/to/Scrim.app --args --fullscreen --screen 1 --output default
```

Confirm the screen index first. If the target is unplugged, Scrim hides the
fullscreen window and waits for that same display to return. The `swift run`
developer launch still defaults to fullscreen on an eligible external display.

### Developer launch

1. Enable Flywire and output publishing as described above. Once the feed works,
   you can enable **Use Scrim instead of the Electron output window**. This
   suppresses that output's physical Electron window while retaining a hidden
   text-only Chromium measurement host in the operator renderer.
2. Find the logical FreeShow output ID in the saved output configuration or the
   `[Flywire] configured output IDs` console message. From the repository root,
   start a fullscreen Scrim output (the usual ID is `default`):

   ```sh
   npm run scrim -- --output default
   ```

   `--output` is a FreeShow output key, not a macOS display number.
   `--host` overrides the local endpoint; this FreeShow branch listens only on
   loopback. `--screen N` selects an initial macOS display index, independently
   of the FreeShow feed. Without `--screen`, Scrim chooses the
   first active, non-mirrored external display that is not the main display.
   Fullscreen never falls back to the main display; use `--windowed` for that.

Scrim does not activate or take keyboard focus when it launches. Quit it from
the Scrim icon in the macOS menu bar, or press Control-C in the terminal that
launched it.

When no secondary display is connected, add `--windowed` to create a normal,
resizable and closable 16:9 test window without changing the renderer or
Flywire scene path:

```sh
npm run scrim:windowed -- --output default
```

The first run builds Scrim with Swift Package Manager, so it may take longer
while Swift downloads dependencies. Subsequent runs reuse the local build.
For a different output or FreeShow host, add options after `--`, for example
`npm run scrim:windowed -- --output sanctuary --host http://127.0.0.1:5514`.

To check macOS capture permission and exercise a disposable window/display:

```sh
npm run scrim:capture-check
```

To run the end-to-end Flywire/preview check with temporary windows:

```sh
npm run scrim:capture-test
```

The check requires Screen Recording permission and does not change the FreeShow
show. Scrim offers **Allow Screen Capture…** from its menu-bar icon if permission
needs to be granted; restart Scrim after granting it.

The output window is borderless, fills the selected display in pixels, does not
activate, and requests frames from `CVDisplayLink`. Each Flywire take is prepared
as a media layer and a complete text layer. The compositor retains the prior
layers and independently applies FreeShow's resolved media and text transition
settings. This release contract supports only **None** (a true hard cut) and
**Fade**, including the authored duration and easing. Other transition effects
are reported and presented as hard cuts instead of being visually approximated.
Text items still move as one prepared text layer; identical text is retained
without a fade/dip. Scrim keeps bounded decoded image and video-first-frame
caches. FreeShow publishes neighboring media up to three slides ahead and one
slide behind; Scrim prepares those assets concurrently without starting video
playback.
Background video is fetched through the same opaque asset URL, decoded by
AVFoundation, aspect-fitted within the canvas, always muted, and honors Flywire's
authoritative playback state: playhead, pause, rate, loop, and the resolved
**Clear media when finished** preference. A non-looping video either clears or
holds its cached final frame accordingly. FreeShow remains the only program-audio
authority. Live video participates in the media transition below the independently
transitioned text layer.

Display and window backgrounds selected from FreeShow's Screen source use
native ScreenCaptureKit capture. Flywire carries a source identity rather than
pixel frames, and the same native capture stream feeds Scrim's output and its
operator preview. Captures wait for a first complete frame before a revision is
presented, share streams across retained transition scenes, and hold their last
frame if the source closes. Scrim-only mode requires Screen Recording
permission for the Scrim executable. See
`docs/scrim/FLYWIRE_LIVE_SOURCE_CONTRACT.md` for the protocol, lifecycle, and
disposable live-capture probes.

Media preparation is fail-closed. A scene containing an image is not eligible
for presentation until that image has decoded, and a video scene is not eligible
until AVFoundation has opened its video track and decoded a display-oriented
first frame. A missing, unreadable, or unsupported asset therefore leaves the
last valid scene on program and emits an error with the output, revision, asset,
and reason. Media outside the neighbor window uses the same validation gate on
demand, so an uncached take remains safe even when it is not prewarmed.

When an output has Scrim enabled, its operator preview uses reduced-resolution
frames returned by the native compositor instead of mounting a second Chromium
`Output` scene. Static scenes return one frame per presented revision; video and
active transitions are capped at 15 fps. The acknowledgement-gated transport is
strictly lossy and cannot block program presentation. See
`docs/scrim/SCRIM_NATIVE_PREVIEW_CONTRACT.md`.

Scrim-only mode does not remove FreeShow's main Electron process. It removes the
separate physical audience renderer for that output; the lightweight hidden host
still resolves inherited typography and Chromium-authored visual line breaks.
Because Scrim's AVPlayer is permanently muted, use dual-render mode whenever the
Electron output window is required as the program-audio source.

## Text fidelity experiment

`Fixtures/autosize-comparison.show` is a valid FreeShow show with a real
shrink-to-fit slide. Import it, display it at 1920×1080 in Chromium and Scrim,
and compare:

- the `chromiumFontSize` published in Flywire against CoreText's font size;
- line count and break positions;
- rendered bounding height and baseline placement.

The matching Flywire fixture is covered by `swift test`. Forensic instrumentation
found and fixed two native translation defects (zero kern disabled font kerning,
and CSS line height used the wrong CoreText property). Font faces and unwrapped
widths match closely. FreeShow now publishes the final Chromium UTF-16 visual-line
ranges after autosize and balanced wrapping; Scrim shapes those attributed
substrings with CoreText and does not independently wrap them. The representative
forced-break matrix passes with subpixel geometry deltas. See
`docs/scrim/FLYWIRE_TEXT_LAYOUT_CONTRACT.md`. The renderer contains no font-size
fudge or balanced-wrap emulation.

To regenerate the detailed artifacts after installing FreeShow's dependencies:

```sh
node scrim/Tools/chromium-fidelity.mjs
node scrim/Tools/forced-break-fidelity.mjs
cd scrim
SCRIM_FIDELITY_OUTPUT="$PWD/Artifacts/coretext-fidelity.json" swift test
SCRIM_FORCED_FIDELITY_OUTPUT="$PWD/Artifacts/forced-break-coretext.json" swift test
```

## Protocol decisions

- Flywire v1 sends full scenes, not diffs.
- Scene coordinates are target pixels with a top-left origin.
- Text is literal and carries structured runs plus Chromium's cached autosize
  result and UTF-16 visual-line ranges when available. Ranges preserve run
  identity; CoreText still owns shaping.
- Scene media identity is an opaque `assetId`. Local paths are registered only
  inside Electron and exposed to Scrim as `/assets/{assetId}`. Background media
  declares whether the asset is an image or video. A separate `PLAYBACK` message
  carries the authoritative FreeShow audio clock, loop intent, playback rate,
  and resolved clear-on-end policy without exposing a local path.
- Consumers must prepare all required scene media before presenting a revision.
  Preparation failure rejects that revision; it must not degrade to an empty or
  background-only scene.
- Every scene carries independently resolved media and text transitions. The
  native contract accepts `cut` or `fade`, duration in milliseconds, and one of
  FreeShow's named easing curves (`linear`, `back`, `sine`, `circ`, `cubic`,
  `elastic`, or `bounce`).
- The Swift `ScrimCore` target has no AppKit window or Socket.IO dependency, so
  its scene/compositor code can be adapted for iOS/iPadOS later.

Video items, stage outputs, overlays, effects, NDI and other network live inputs,
PDF/PPT, cameras, web, drawings, and a polished operator UI are outside this
slice. This slice supports screen/window backgrounds and synchronized
background-video playback with operator scrubbing.

The finish line for a supervised media-first show trial is documented in
`docs/scrim/GIG_READINESS_GATE.md`.
