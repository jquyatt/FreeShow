import type { FlywireLiveSourceRef } from "../../../../types/Scrim"

export function screenCaptureIntent(sourceId: string): FlywireLiveSourceRef {
    const match = /^(screen|window):(\d+):[01]$/.exec(sourceId)
    if (!match) throw new Error(`Invalid desktop capture source: ${sourceId}`)
    const windowId = Number(match[2])
    if (match[1] === "window" && (!Number.isSafeInteger(windowId) || windowId <= 0 || windowId > 0xffffffff)) throw new Error("Invalid native window ID")
    return {
        kind: "screenCapture",
        sourceId,
        target: match[1] === "screen" ? "display" : "window",
        nativeId: match[1] === "window" ? windowId : undefined,
        // Chromium's full-size <video> uses the initial object-fit: fill.
        fit: "fill",
        showsCursor: true,
        muted: true
    }
}

export function resolveCaptureDisplay(source: FlywireLiveSourceRef, screens: { id: string; displayId?: string }[]): FlywireLiveSourceRef {
    if (source.target === "window") return source
    const displayId = screens.find((screen) => screen.id === source.sourceId)?.displayId
    const nativeId = Number(displayId)
    if (!displayId || !Number.isInteger(nativeId) || nativeId <= 0 || nativeId > 0xffffffff) throw new Error(`Capture display unavailable: ${source.sourceId}`)
    return { ...source, nativeId }
}
