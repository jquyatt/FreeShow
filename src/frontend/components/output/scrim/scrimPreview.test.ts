import { get } from "svelte/store"
import { beforeEach, describe, expect, it, vi } from "vitest"

describe("Scrim native preview transport", () => {
    beforeEach(() => {
        vi.resetModules()
    })

    it("resends active demand after Scrim reconnects and acknowledges displayed frames", async () => {
        const sent: any[] = []
        let receive: ((message: any) => void) | undefined
        vi.stubGlobal("window", {
            api: {
                receive: (_channel: string, callback: (message: any) => void) => (receive = callback),
                send: (_channel: string, message: any) => sent.push(message)
            }
        })

        const preview = await import("./scrimPreview")
        preview.initScrimPreviewReceiver()
        preview.setScrimPreviewDemand("audience", true, 640, 12)
        expect(sent[sent.length - 1]).toMatchObject({ channel: "PREVIEW_DEMAND", data: { outputId: "audience", enabled: true } })

        receive?.({ channel: "PREVIEW_READY", id: "socket-1", data: { outputId: "audience" } })
        expect(sent[sent.length - 1]).toMatchObject({ channel: "PREVIEW_DEMAND", data: { outputId: "audience", enabled: true } })

        receive?.({
            channel: "PREVIEW_FRAME",
            data: { outputId: "audience", revision: 7, frameId: 3, width: 640, height: 360, mimeType: "image/jpeg", base64: "frame", sentAt: 1 }
        })
        expect(get(preview.scrimPreviewFrames).audience?.revision).toBe(7)

        preview.acknowledgeScrimPreviewFrame("audience", 3, "socket-1")
        expect(sent[sent.length - 1]).toMatchObject({ id: "socket-1", channel: "PREVIEW_ACK", data: { outputId: "audience", frameId: 3 } })

        preview.setScrimPreviewDemand("audience", false)
        expect(get(preview.scrimPreviewFrames).audience).toBeUndefined()
        expect(sent[sent.length - 1]).toMatchObject({ channel: "PREVIEW_DEMAND", data: { outputId: "audience", enabled: false } })
    })
})
