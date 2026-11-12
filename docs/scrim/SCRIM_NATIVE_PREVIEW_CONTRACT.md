# Scrim native preview contract

The FreeShow operator preview is a lossy observation of Scrim's presented output. It is never part of the program presentation path and must never apply backpressure to that path.

## Lifecycle

1. A Scrim client announces `PREVIEW_READY` with its `outputId` after connecting.
2. A visible FreeShow preview sends `PREVIEW_DEMAND` with `outputId`, `enabled`, `maxWidth`, and `framesPerSecond`.
3. Scrim sends a `PREVIEW_FRAME` only after the corresponding revision has been presented.
4. FreeShow sends `PREVIEW_ACK` after the image has loaded or failed to decode.
5. Scrim permits at most one unacknowledged frame. It may abandon that frame after a timeout; it never queues replacement frames behind it.
6. Hiding or destroying the preview sends `PREVIEW_DEMAND` with `enabled: false` and stops production.

Still scenes publish once per presented revision. Video and active transitions publish at the demanded rate, currently capped at 15 fps. Frames are reduced-resolution JPEG images and contain no audio.

FreeShow unmounts its duplicate Chromium scene after the first native frame arrives. If the matching Scrim client disconnects or has not produced a frame yet, the existing Chromium preview remains the operational fallback.

## Multiple outputs

Every message is keyed by FreeShow `outputId`. FreeShow stores frames independently per output, and demand for one output cannot enable another. The native coordinator can scale by creating one isolated output session per output ID; each session owns its display, revision state, player, presentation window, and preview gate while sharing immutable asset and font caches.

Preview transport is latest-frame-wins. A slow or hidden operator UI may reduce or stop previews without changing scene receipt, preparation, transition timing, video playback, or presentation.
