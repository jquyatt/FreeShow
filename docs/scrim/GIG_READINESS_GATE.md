# Scrim media-first gig-readiness gate

Date established: 2026-08-24

## Goal

Ship a narrow Scrim release that is safe to trial on a real show where normal
outputs are overwhelmingly photos and silent videos. FreeShow remains the show
authority and its Electron output remains available as the fallback.

This gate is intentionally not a promise to reproduce every FreeShow feature.
It is a promise that the supported media path behaves predictably under show
conditions.

## Supported release contract

- One normal FreeShow output subscribed by logical output ID.
- Solid-color, still-image, and background-video scenes.
- JPEG and PNG still images.
- Local H.264 MP4 video, muted, with authored looping behavior.
- Landscape, portrait, and square media.
- Still images retain FreeShow's background fill behavior.
- Videos are aspect-fitted and centered; unused canvas area uses the authored
  scene background color.
- Independent media/text None and Fade transitions with authored duration and easing.
- Static text within the documented Flywire text-layout contract.
- Borderless native output with no macOS window corner mask.
- The physical Electron audience renderer may remain enabled for dual-render
  fallback or be explicitly suppressed in Scrim-only mode. Re-enabling it is the
  operational fallback.

## Explicitly outside the first gig trial

- Video items or overlays; only background video is supported.
- Audible video and selection of an audio output device.
- Seeking, timecode, external synchronization, or matching an already-running
  Electron video clock.
- Animated GIF playback, live inputs, cameras, web content, PDF/PPT, effects,
  stage outputs, and output overlays.
- Display hot-plug recovery without restarting Scrim.

If audible video is required for the trial show, this gate is not passed until
audio routing and start/stop behavior receive their own acceptance tests.

## Must-pass behavior

### Fidelity

- Each representative photo and video is upright, centered, and uses the
  declared fill/fit behavior at the target output resolution.
- Color, opacity, text, and transition geometry do not change between initial
  presentation and later frames.
- No rounded output corners, unintended clipping, stretching, or one-frame
  orientation errors occur.

### Takes and transitions

The following sequence matrix must run without a dip to black, stale scene,
unstyled first frame, or independently fading item:

1. photo to photo;
2. photo to video;
3. video to photo;
4. video to video;
5. the same asset taken repeatedly;
6. media/text None and Fade variants across every supported easing;
7. rapid forward/back takes across at least ten adjacent scenes;
8. clear/black and return to media.

For a warmed photo, Scrim's first changed frame must appear within two refresh
intervals of the take. For video, the first decoded frame must be ready before
the incoming scene becomes visible; transition time must not conceal asset
loading.

### Playback

- Every video take starts from the authored beginning.
- A looping video crosses its end without a black frame or pause.
- A non-looping video follows FreeShow's resolved **Clear media when finished**
  preference: clear when enabled, or hold its final frame when disabled.
- Operator play, pause, and scrub actions remain synchronized to FreeShow's
  authoritative audio clock.
- Portrait and square videos remain fully visible for their complete duration.
- Repeated video takes do not leave hidden players consuming resources.

### Failure and recovery

- A missing, unreadable, or unsupported media asset never replaces valid
  program output with an accidental black/solid scene. Scrim retains the last
  successfully presented scene and emits an actionable error containing output
  ID, revision, asset ID, and failure reason.
- Restarting Scrim reconnects, resubscribes, and presents the current scene
  without requiring another take.
- Restarting the Flywire server or FreeShow permits Scrim to reconnect and
  recover the current scene.
- Superseded revisions cannot appear after a newer revision.

### Soak and resource use

- Run the representative show for two hours with at least 500 automated or
  manual takes and repeated video loops.
- No crash, progressive trigger delay, visible cache corruption, runaway player
  count, or sustained memory growth after the working media set has cycled.
- Diagnostic logs remain concise enough to identify the last received,
  prepared, and presented revision during a failure.

### Operator handoff

- Build and launch use a release Scrim binary, not an implicit debug rebuild.
- A short runbook records the exact FreeShow toggle, Flywire port, output ID,
  display selection, start order, expected connected log, fallback procedure,
  and clean shutdown procedure.
- The known-unsupported list is visible before the show is loaded into Scrim.

## Current status

| Area | Status | Evidence / remaining work |
| --- | --- | --- |
| Still-image presentation | Implemented | Opaque asset endpoint, decoded-image cache, adjacent-image prewarm |
| Background-video presentation | Implemented | Native AVFoundation playback, audio-clock sync, scrub/pause/rate/loop/clear-on-end intent, portrait aspect-fit |
| Media/text transitions | Implemented, needs live verification | Independent retained layers; None hard-cuts; Fade preserves FreeShow duration/easing; unsupported effects hard-cut with a diagnostic |
| Static text | Implemented for documented slice | Chromium visual breaks plus computed typography contract |
| Native operator preview | Implemented, needs live verification | Scrim JPEG feed is demand/ack gated; Chromium scene remains only as disconnected fallback |
| Scrim-only output mode | Implemented and live-verified 2026-08-24 | Per-output switch closed the physical Electron audience window while Scrim output, image/video takes, static text, hidden Chromium typography measurement, and native operator preview remained correct. Existing Electron-only and dual-render defaults are unchanged. |
| Three-state performance comparison | Live-measured in two mode orders 2026-08-24 | Production FreeShow/release Scrim, 18 recorded 60-second samples. Scrim-only removed one renderer process, reduced warmed memory, tied the tested video at whole-display cost, and kept active P95 close to Electron-only. Static CPU favored Electron-only; Dual was highest-cost steady mode. See `docs/scrim/PERFORMANCE_RESULTS_2026-08-24.md`. |
| Present state across renderer-mode changes | Fixed, needs final live smoke check | Mode changes carry the runtime Present state. Entering Scrim-only no longer publishes a false output state; returning to Chromium recreates and presents its window when Present was already on. Both directions have focused regression coverage. |
| Socket reconnect/current scene | Implemented, needs scenario test | Client reconnects and publisher sends current scene on subscription |
| Video first-frame prewarm | Implemented and live-verified 2026-08-24 | Three consecutive distinct videos prewarmed concurrently within the 3-ahead/1-behind window; takes used cached first frames in 0 ms. Two direct jumps four slides ahead correctly remained cold (`cached=false`, 16–18 ms), passed through the same preparation gate, and were visually confirmed without a black or stale frame. Prewarming did not create players or start playback. |
| Media failure fail-safe | Implemented, needs live verification | Required images must decode and videos must yield a real first frame before presentation; failures retain the last valid scene and identify output/revision/asset/reason; corrupt-image and missing-video tests pass |
| Video loop/clear/final-frame hold | Implemented, needs live verification | Flywire publishes resolved loop and clear-on-end policy; revised test-show clips cover stop and loop cases |
| Format/orientation matrix | **Open verification** | Add representative JPEG, PNG, landscape/portrait/square H.264 fixtures |
| Long soak/resource stability | **Open verification** | Two-hour/500-take run not yet completed |
| Release build and operator runbook | **Open blocker** | Current workflow is prototype-oriented |
| Audible video | Excluded | Use Electron output for the first trial |

## Release decision

Scrim is ready for a supervised gig trial only when every open blocker above is
closed and all must-pass scenarios have dated evidence. Open verification items
may not be waived merely because the equivalent single manual take worked once.

During the first trial, keep the Electron output live and routable as the
immediate fallback. Promotion beyond a supervised trial requires at least one
complete show with no Scrim-caused fallback.
