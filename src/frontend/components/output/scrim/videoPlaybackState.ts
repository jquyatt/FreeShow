import type { FlywireVideoPlaybackState } from "../../../../types/Scrim"

interface PlayingVideoStateLike {
    currentTime: number
    duration: number
    paused: boolean
    loop: boolean
    type?: "background" | "item"
}

export interface PublishedVideoBinding {
    outputId: string
    sceneId: string
    assetId: string
    path: string
}

/** Resolve FreeShow's authoritative audio-clock state without exposing local paths. */
export function resolveFlywireVideoPlaybackState(binding: PublishedVideoBinding, states: Record<string, PlayingVideoStateLike>, playbackRate = 1, clearOnEnd = true, sentAt = Date.now()): FlywireVideoPlaybackState | null {
    const exactKey = `${binding.path}_${binding.outputId}`
    const state = states[exactKey]
    if (!state) return null

    const positionSeconds = finiteNonnegative(state.currentTime)
    const durationSeconds = finiteNonnegative(state.duration)
    const rate = Number.isFinite(playbackRate) && playbackRate > 0 ? playbackRate : 1
    return {
        outputId: binding.outputId,
        sceneId: binding.sceneId,
        assetId: binding.assetId,
        positionSeconds: durationSeconds > 0 ? Math.min(positionSeconds, durationSeconds) : positionSeconds,
        durationSeconds,
        paused: !!state.paused,
        loop: !!state.loop,
        clearOnEnd,
        playbackRate: rate,
        sentAt
    }
}

function finiteNonnegative(value: unknown) {
    const number = Number(value)
    return Number.isFinite(number) ? Math.max(0, number) : 0
}
