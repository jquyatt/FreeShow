import { describe, expect, it } from "vitest"
import { resolveCaptureDisplay, screenCaptureIntent } from "./liveSource"

describe("native desktop capture identity", () => {
    it("resolves display identity from Electron metadata, never the sequential source number", () => {
        const intent = screenCaptureIntent("screen:0:0")
        expect(intent.nativeId).toBeUndefined()
        const resolved = resolveCaptureDisplay(intent, [{ id: "screen:0:0", displayId: "42" }])
        expect(resolved).toMatchObject({ nativeId: 42, target: "display", fit: "fill", muted: true })
        expect(JSON.stringify(resolved)).not.toContain("pixels")
    })

    it("preserves native window identity including FreeShow's own window IDs", () => {
        expect(screenCaptureIntent("window:987:1")).toMatchObject({ nativeId: 987, target: "window" })
        expect(resolveCaptureDisplay(screenCaptureIntent("window:987:0"), [])).toMatchObject({ nativeId: 987 })
    })

    it("fails closed for disappeared displays or malformed native identities", () => {
        const intent = screenCaptureIntent("screen:0:0")
        for (const screens of [[], [{ id: "screen:0:0", displayId: "" }], [{ id: "screen:0:0", displayId: "oops" }]]) {
            expect(() => resolveCaptureDisplay(intent, screens)).toThrow()
        }
        for (const id of ["screen:-1:0", "window:0:0", "window:4294967296:0", "camera:123", "window:1:0extra"]) {
            expect(() => screenCaptureIntent(id)).toThrow()
        }
    })
})
