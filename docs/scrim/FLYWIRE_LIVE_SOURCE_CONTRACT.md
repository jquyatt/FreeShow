# Flywire native live-source contract

Flywire v1 can identify a macOS display or window for Scrim to capture with
ScreenCaptureKit. It sends the source identity and presentation settings only;
captured pixels never travel through Electron or Flywire. Native capture is
muted. Scrim supports a live source as the scene background alongside the
existing solid-color, image, and video backgrounds.

## Wire reference

```json
{
  "kind": "screenCapture",
  "sourceId": "window:731:0",
  "target": "window",
  "nativeId": 731,
  "fit": "fill",
  "showsCursor": true,
  "muted": true
}
```

`sourceId` is the Electron desktop-capturer identity for the selected source.
For a display, FreeShow resolves Electron's `display_id` metadata into the
native CoreGraphics display ID before publication; the `screen:N` source
ordinal is not a native display ID. For a window, the native window ID is
carried directly. Missing or malformed identities fail closed rather than
silently selecting a different source.

`fit` accepts `fill`, `contain`, or `cover`; an optional normalized top-left
`crop` rectangle is applied before fitting. FreeShow's current screen-source
element uses a full-size video with `object-fit: fill`, so that is the default.
The cursor is included by default. Audio capture is always disabled regardless
of source metadata.

The client advertises `screenCapture.v1` when subscribing. A publisher must not
send a live-source scene to a client without that capability. Old clients keep
rendering their last valid scene and receive `CAPABILITY_REQUIRED`.

## Lifecycle and presentation

Scrim validates the descriptor and requires a local Flywire connection because
native display/window IDs have meaning only on the same Mac. It starts capture
when preparing an incoming scene and waits up to five seconds for its first
complete frame. A preparation failure leaves the outgoing scene on program.
Rapidly superseded preparations are released and cannot replace a newer
revision. Scenes sharing the same capture reuse one ScreenCaptureKit stream;
the stream stops after the last retained scene releases it.

ScreenCaptureKit supplies only the newest available frame; Scrim does not queue
old frames. A failed or disappeared source holds its last valid frame until a
new scene replaces it. Window content bounds are cropped using ScreenCaptureKit
frame attachments so resize follows the source's current aspect ratio. Display
capture excludes Scrim's own windows to prevent recursive feedback. Capture is
limited to 3840×2160 and 60 fps, with aspect preserved when that limit scales a
larger source. Core Image converts the current sample to a native image for the
existing compositor.

Program and operator preview use the same crop, fit, and grouped media-layer
drawing. The complete background-plus-live-frame image is faded as one unit;
this avoids applying transition opacity twice. Media and text retain their
existing independent transition timing. Preview continues to use its existing
acknowledged, reduced-size JPEG path.

Screen Recording permission must be granted to the Scrim app/executable. The
menu-bar **Allow Screen Capture…** item opens the macOS permission flow; restart
Scrim after granting permission. The diagnostic command
`scrim/.build/debug/ScrimMac --capture-check` exercises a disposable fixture
window, live updates and resize, source disappearance, display capture, and
missing-source rejection. The Flywire integration probe
`node scrim/Tools/capture-integration.mjs` uses a temporary loopback server and
disposable windows; it checks capabilities, program/preview updates, output
isolation, failure retention, and stale-revision rejection.

## Extension boundary

The native `LiveFrameSource` lifecycle is the seam for future source adapters.
An adapter should own discovery and frame delivery while the scene keeps the
same preparation gate, lease lifecycle, compositor, and preview. NDI, cameras,
and network transports are not part of this protocol revision. Adding them
requires explicit source identity, transport health/reconnect rules, and any
needed audio contract; they must not be represented as a screen/window ID.
