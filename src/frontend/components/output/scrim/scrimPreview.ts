import { writable } from "svelte/store"
import { SCRIM } from "../../../../types/Channels"
import type { Message } from "../../../../types/Socket"

export interface ScrimPreviewFrame {
    socketId?: string
    outputId: string
    revision: number
    frameId: number
    width: number
    height: number
    mimeType: string
    base64: string
    sentAt: number
}

export const scrimPreviewFrames = writable<Record<string, ScrimPreviewFrame>>({})

let initialized = false
const activeDemands = new Map<string, { maxWidth: number; framesPerSecond: number }>()
const socketOutputs = new Map<string, string>()

export function initScrimPreviewReceiver() {
    if (initialized) return
    initialized = true
    window.api.receive(
        SCRIM,
        (message: Message) => {
            if (message.channel === "PREVIEW_READY") {
                const outputId = String(message.data?.outputId || "")
                if (!outputId) return
                if (message.id) socketOutputs.set(message.id, outputId)
                clearPreviewFrame(outputId)
                const demand = activeDemands.get(outputId)
                if (demand) emitPreviewDemand(outputId, true, demand.maxWidth, demand.framesPerSecond, message.id)
            } else if (message.channel === "DISCONNECT") {
                const outputId = message.id ? socketOutputs.get(message.id) : ""
                if (message.id) socketOutputs.delete(message.id)
                if (outputId) clearPreviewFrame(outputId)
            } else if (message.channel === "PREVIEW_FRAME") {
                const frame = message.data as ScrimPreviewFrame | undefined
                if (!frame?.outputId || !frame.base64 || !frame.frameId) return
                scrimPreviewFrames.update((frames) => ({ ...frames, [frame.outputId]: { ...frame, socketId: message.id } }))
            }
        },
        "scrim-native-preview"
    )
}

export function setScrimPreviewDemand(outputId: string, enabled: boolean, maxWidth = 640, framesPerSecond = 12) {
    if (!outputId) return
    if (enabled) activeDemands.set(outputId, { maxWidth, framesPerSecond })
    else activeDemands.delete(outputId)
    emitPreviewDemand(outputId, enabled, maxWidth, framesPerSecond)
    if (!enabled) clearPreviewFrame(outputId)
}

function emitPreviewDemand(outputId: string, enabled: boolean, maxWidth: number, framesPerSecond: number, socketId?: string) {
    window.api.send(SCRIM, {
        id: socketId,
        channel: "PREVIEW_DEMAND",
        data: { outputId, enabled, maxWidth, framesPerSecond }
    })
}

function clearPreviewFrame(outputId: string) {
    scrimPreviewFrames.update((frames) => {
        if (!frames[outputId]) return frames
        const next = { ...frames }
        delete next[outputId]
        return next
    })
}

export function acknowledgeScrimPreviewFrame(outputId: string, frameId: number, socketId?: string) {
    if (!outputId || !frameId) return
    window.api.send(SCRIM, {
        id: socketId,
        channel: "PREVIEW_ACK",
        data: { outputId, frameId }
    })
}
