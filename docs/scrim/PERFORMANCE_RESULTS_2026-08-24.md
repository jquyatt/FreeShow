# Scrim three-state performance results

Date measured: 2026-08-24

## Environment

- Apple-silicon macOS host with the connected 1920 × 1080 program display.
- One locally packaged production FreeShow build: no Vite server, DevTools, or
  TypeScript watcher.
- One `swift build -c release` Scrim binary.
- Spotify stopped; FreeShow's macOS status poll was corrected so it did not
  relaunch Spotify or generate background errors.
- The same show, output, display path, and operator window were retained across
  all states.
- Two complete passes were run in different mode orders.
- Every steady workload used a 60-second, one-second-resolution sample. Active
  takes were manually paced at approximately one take every three seconds.

The packaged benchmark app was ad-hoc signed and retained the already-installed
Electron-compatible native modules rather than rebuilding the unrelated NDI
module. It is valid for this local media comparison but is not the final
distribution package.

## Mode validation

| Mode | FreeShow processes | Scrim processes | Physical renderer state |
| --- | ---: | ---: | --- |
| Electron-only | 10 | 0 | Electron output active |
| Dual | 10 | 1 | Electron output active underneath Scrim |
| Scrim-only | 9 | 1 | Electron audience renderer closed |

The process-count transition independently confirmed that Scrim-only removed
the separate audience renderer even when Scrim visually covered the same
external display.

## Two-run ranges

App CPU includes the complete FreeShow process tree plus Scrim when present.
Display-stack CPU adds WindowServer to that app total. RSS is the combined
resident memory of FreeShow and Scrim. The values below are the range of the two
per-run medians.

| Workload | Mode | App CPU median | App + WindowServer median | Combined RSS median |
| --- | --- | ---: | ---: | ---: |
| Still image | Electron-only | 8.0–8.3% | 9.8–11.6% | 1,092–1,172 MB |
| Still image | Dual | 11.9–13.5% | 17.7–18.8% | 1,105–1,406 MB |
| Still image | Scrim-only | 9.3–10.6% | 15.0–18.5% | 1,059–1,070 MB |
| Looping portrait video | Electron-only | 38.1–43.0% | 76.3–77.9% | 1,147–1,213 MB |
| Looping portrait video | Dual | 47.2–48.5% | 79.1–85.6% | 1,046–1,399 MB |
| Looping portrait video | Scrim-only | 42.0–42.4% | 74.8–76.1% | 1,075–1,115 MB |
| Active takes | Electron-only | 27.1–36.8% | 56.6–74.5% | 1,172–1,226 MB |
| Active takes | Dual | 17.0–34.4% | 42.5–53.3% | 1,170–1,418 MB |
| Active takes | Scrim-only | 20.6–26.3% | 42.5–42.8% | 1,100–1,145 MB |

The active-take medians are shown for completeness but are cadence-sensitive.
Their display-stack P95 values are more comparable:

| Mode | Active-take display-stack P95, run 1 | Run 2 |
| --- | ---: | ---: |
| Electron-only | 105.2% | 104.9% |
| Dual | 105.8% | 121.4% |
| Scrim-only | 105.0% | 107.7% |

Raw one-second samples and generated matrices are in
`scrim/Artifacts/performance/`. The primary matrices are
`comparison-run1.md` and `comparison-run2.md`.

## Findings

1. **Scrim-only genuinely removes the physical Chromium audience renderer.**
   FreeShow lost one renderer process immediately, and the run-two warmed RSS
   median was 82–113 MB below Electron-only across the three workloads.
2. **Electron-only is the static-CPU winner.** Scrim's display link and native
   compositor cost more than Chromium's mostly idle still output. Scrim-only was
   close at the app level but not lower after WindowServer was included.
3. **The tested video is effectively a tie between Electron-only and
   Scrim-only at whole-display cost.** Scrim-only app CPU was sometimes a little
   higher, but WindowServer was lower in both passes. Its display-stack median
   was 0.2–3.1 percentage points below Electron-only. Dual was highest.
4. **Scrim-only did not worsen active-take peaks meaningfully.** Its two P95
   values were within 0.2 and 2.8 percentage points of Electron-only. Dual had
   the highest second-pass peak.
5. **Dual is a safety mode, not a performance mode.** It retains the fallback
   renderer and therefore carries both rendering paths. Its stable workloads
   were consistently the most expensive.
6. **Memory growth during the first full media traversal is shared behavior.**
   Electron-only grew about 80–86 MB during each active pass; Dual grew about
   140 MB. Scrim-only varied with cache temperature. These short samples do not
   replace the required long soak or establish the final memory plateau.

## Decision

The performance comparison supports a supervised Scrim-only trial for silent
photo/video shows. It recovers one Chromium renderer and useful memory without
introducing a material active-take peak penalty. It should not be sold as a
universal CPU optimization: static output favors Electron, and the tested video
was close after compositor cost was included.

Dual remains the appropriate first-gig fallback configuration when instant
return to the Electron output or Electron-owned program audio is required. It
should not be chosen for resource savings.

## Remaining limitations and follow-up

- Repeat the video workload with several representative codecs, frame rates,
  resolutions, and durations before making a general video-efficiency claim.
- Complete the two-hour/500-take soak and verify that both media caches plateau.
- Capture GPU/energy telemetry with a dedicated macOS instrument if GPU
  attribution becomes a release criterion.
- The observed Present-state reset was fixed after this run. Renderer-mode
  changes now carry the current runtime Present state: entering Scrim-only
  removes the Chromium audience window without publishing an inactive state,
  and leaving Scrim-only recreates and shows Chromium when Present was already
  on. Both transitions have regression coverage; retain a live smoke check in
  the packaging checklist.
