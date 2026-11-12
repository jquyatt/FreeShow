import { describe, expect, it } from "vitest"
import { resolveFlywireVideoPlaybackState } from "./videoPlaybackState"

const binding = {
    outputId: "default",
    sceneId: "default:123",
    assetId: "asset-video",
    path: "/media/portrait.mov"
}

describe("Flywire video playback state", () => {
    it("publishes the authoritative playhead without exposing its path", () => {
        const state = resolveFlywireVideoPlaybackState(
            binding,
            {
                "/media/portrait.mov_default": {
                    currentTime: 2.75,
                    duration: 8,
                    paused: true,
                    loop: false,
                    type: "background"
                }
            },
            1.25,
            false,
            1000
        )

        expect(state).toEqual({
            outputId: "default",
            sceneId: "default:123",
            assetId: "asset-video",
            positionSeconds: 2.75,
            durationSeconds: 8,
            paused: true,
            loop: false,
            clearOnEnd: false,
            playbackRate: 1.25,
            sentAt: 1000
        })
        expect(JSON.stringify(state)).not.toContain("portrait.mov")
    })

    it("does not apply stale playback from another video on the same output", () => {
        const state = resolveFlywireVideoPlaybackState(binding, {
            "/resolved/portrait.mov_default": {
                currentTime: 9,
                duration: 8,
                paused: false,
                loop: true,
                type: "background"
            }
        })

        expect(state).toBeNull()
    })
})
