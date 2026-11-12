import { get } from "svelte/store"
import { OUTPUT, SCRIM } from "../../../../types/Channels"
import type { Message } from "../../../../types/Socket"
import { FLYWIRE_PROTOCOL_VERSION, type FlywireSceneEnvelope } from "../../../../types/Scrim"
import { connections, media, outputs, playingVideoState, showsCache, special, styles, templates, transitionData, variables } from "../../../stores"
import { resolveAdjacentSceneAssets, resolveSceneBundle } from "./resolveScene"
import { receiveChromiumTextLayout, subscribeChromiumTextLayouts } from "./chromiumTextLayout"
import { resolveFlywireVideoPlaybackState, type PublishedVideoBinding } from "./videoPlaybackState"
import { Main } from "../../../../types/IPC/Main"
import { requestMain } from "../../../IPC/main"
import { resolveCaptureDisplay } from "./liveSource"
import { getFlywireOutputCatalog, isPublishedFlywireOutput } from "./flywireOutputCatalog"

// Coalesce synchronous store updates into one resolved scene without delaying
// the presentation trigger. Text-bearing scenes have their own atomic
// Chromium-layout readiness gate below.
const SCENE_COALESCE_MS = 0

let initialized = false
let sequence = 0
let resolutionGeneration = 0
let publishTimer: ReturnType<typeof setTimeout> | null = null
let outputCatalog: ReturnType<typeof getFlywireOutputCatalog> = []
const subscriptions = new Map<string, string>()
const capabilities = new Map<string, Set<string>>()
const heldTextLayouts = new Map<string, string>()
const lastPublishedSceneSignatures = new Map<string, string>()
const publishedVideoBindings = new Map<string, PublishedVideoBinding>()
let latestPlayingVideoState: Record<string, any> = {}

/** Start the main-window Flywire publisher once the normal stores are available. */
export function initFlywirePublisher() {
    if (initialized) return
    initialized = true

    window.api.receive(SCRIM, receiveScrimMessage, "flywire-publisher")
    window.api.receive(
        OUTPUT,
        (msg: Message) => {
            if (msg.channel !== "MAIN_SCRIM_TEXT_LAYOUT") return
            const outputId = String(msg.data?.outputId || "")
            const itemId = String(msg.data?.itemId || "")
            const sourceKey = String(msg.data?.sourceKey || "")
            if (!outputId || !itemId || !sourceKey) return
            const measurement = msg.data?.measurement || null
            console.info(`[Flywire] Chromium text layout output=${outputId} item=${itemId} state=${measurement ? "measured" : "cleared"}`)
            receiveChromiumTextLayout(outputId, itemId, sourceKey, measurement)
        },
        "flywire-text-layout"
    )
    outputs.subscribe((allOutputs) => {
        const catalog = getFlywireOutputCatalog(allOutputs)
        if (JSON.stringify(catalog) !== JSON.stringify(outputCatalog)) {
            outputCatalog = catalog
            console.info(`[Flywire] configured output IDs: ${catalog.map(({ id }) => id).join(", ") || "(none)"}`)
            publishOutputCatalog()
        }
        scheduleFlywireScenes()
    })
    ;[showsCache, styles, templates, media, variables, transitionData].forEach((store: any) => store.subscribe(scheduleFlywireScenes))
    playingVideoState.subscribe((state) => {
        latestPlayingVideoState = state
        publishVideoPlaybackStates()
    })
    special.subscribe(publishVideoPlaybackStates)
    subscribeChromiumTextLayouts(publishMeasuredFlywireScenes)
}

export function scheduleFlywireScenes() {
    resolutionGeneration++
    if (publishTimer) clearTimeout(publishTimer)
    publishTimer = setTimeout(() => {
        publishTimer = null
        const outputIds = new Set(subscriptions.values())
        outputIds.forEach((outputId) => publishOutput(outputId))
    }, SCENE_COALESCE_MS)
}

function publishMeasuredFlywireScenes() {
    resolutionGeneration++
    if (publishTimer) {
        clearTimeout(publishTimer)
        publishTimer = null
    }
    const outputIds = new Set(subscriptions.values())
    outputIds.forEach((outputId) => publishOutput(outputId))
}

function receiveScrimMessage(msg: Message) {
    const socketId = msg.id || ""
    if (msg.channel === "CONNECTION") {
        connections.update((all) => {
            if (!all.SCRIM) all.SCRIM = {}
            all.SCRIM[socketId] = { active: "connected" }
            return all
        })
        return
    }

    if (msg.channel === "DISCONNECT") {
        subscriptions.delete(socketId)
        capabilities.delete(socketId)
        connections.update((all) => {
            if (all.SCRIM) delete all.SCRIM[socketId]
            return all
        })
        return
    }

    if (msg.channel === "LIST_OUTPUTS" && socketId) {
        publishOutputCatalog(socketId)
        return
    }
    if (msg.channel !== "SUBSCRIBE") return
    const outputId = String(msg.data?.outputId || "")
    if (!isPublishedFlywireOutput(get(outputs)[outputId])) {
        console.error(`[Flywire] subscription rejected socket=${socketId} output=${outputId}: output not available`)
        window.api.send(SCRIM, {
            id: socketId,
            channel: "ERROR",
            data: { code: "OUTPUT_NOT_AVAILABLE", outputId }
        })
        return
    }

    console.info(`[Flywire] subscription accepted socket=${socketId} output=${outputId}`)
    subscriptions.set(socketId, outputId)
    capabilities.set(socketId, new Set(Array.isArray(msg.data?.capabilities) ? msg.data.capabilities.filter((value: unknown) => typeof value === "string") : []))
    connections.update((all) => {
        if (!all.SCRIM) all.SCRIM = {}
        all.SCRIM[socketId] = { active: outputId }
        return all
    })
    publishOutput(outputId, socketId)
}

function publishOutputCatalog(socketId?: string) {
    window.api.send(SCRIM, { id: socketId, channel: "OUTPUT_CATALOG", data: outputCatalog })
}

function publishOutput(outputId: string, onlySocketId = "") {
    void publishResolvedOutput(outputId, onlySocketId).catch((error) => {
        console.error(`[Flywire] scene preparation failure output=${outputId} action=retain-current:`, error)
    })
}

async function publishResolvedOutput(outputId: string, onlySocketId = "") {
    const generation = resolutionGeneration
    const bundle = resolveSceneBundle(outputId)
    if (!bundle) return
    if (bundle.pendingTextLayoutIds.length) {
        const holdKey = `${bundle.scene.source.showId || ""}:${bundle.scene.source.layoutId || ""}:${bundle.scene.source.slideIndex ?? -1}:${bundle.scene.source.slideId || ""}:${bundle.pendingTextLayoutIds.join(",")}`
        if (heldTextLayouts.get(outputId) !== holdKey) {
            heldTextLayouts.set(outputId, holdKey)
            console.info(`[Flywire] holding scene output=${outputId} pending Chromium text layout=${bundle.pendingTextLayoutIds.join(",")}`)
        }
        return
    }
    heldTextLayouts.delete(outputId)

    if (bundle.scene.background.live?.target === "display") {
        const screens = await requestMain(Main.GET_SCREENS)
        if (generation !== resolutionGeneration) return
        bundle.scene.background.live = resolveCaptureDisplay(bundle.scene.background.live, screens || [])
    }

    const sceneSignature = JSON.stringify({ ...bundle.scene, id: "" })
    if (!onlySocketId && lastPublishedSceneSignatures.get(outputId) === sceneSignature) {
        console.info(`[Flywire] skipping duplicate scene output=${outputId}`)
        return
    }

    bundle.localAssets.forEach((asset) => window.api.send(SCRIM, { channel: "REGISTER_ASSET", data: asset }))
    const envelope: FlywireSceneEnvelope = {
        protocol: "flywire",
        version: FLYWIRE_PROTOCOL_VERSION,
        type: "scene",
        sequence: ++sequence,
        sentAt: Date.now(),
        scene: bundle.scene
    }

    const video = bundle.scene.background.video
    const videoPath = video ? bundle.localAssets.find((asset) => asset.assetId === video.assetId)?.path : undefined
    if (video && videoPath) {
        publishedVideoBindings.set(outputId, {
            outputId,
            sceneId: bundle.scene.id,
            assetId: video.assetId,
            path: videoPath
        })
    } else {
        publishedVideoBindings.delete(outputId)
    }

    const socketIds = onlySocketId ? [onlySocketId] : [...subscriptions.entries()].filter(([, subscribedOutputId]) => subscribedOutputId === outputId).map(([socketId]) => socketId)
    const mediaTransition = bundle.scene.transition.media
    const textTransition = bundle.scene.transition.text
    console.info(`[Flywire] publishing scene output=${outputId} revision=${envelope.sequence} scene=${bundle.scene.id} media=${mediaTransition.type}/${mediaTransition.durationMs}ms/${mediaTransition.easing} text=${textTransition.type}/${textTransition.durationMs}ms/${textTransition.easing}`)
    socketIds.forEach((socketId) => {
        if (bundle.scene.background.live && !capabilities.get(socketId)?.has("screenCapture.v1")) {
            window.api.send(SCRIM, { id: socketId, channel: "ERROR", data: { code: "CAPABILITY_REQUIRED", outputId, capability: "screenCapture.v1" } })
            return
        }
        window.api.send(SCRIM, { id: socketId, channel: "SCENE", data: envelope })
    })
    if (!onlySocketId) lastPublishedSceneSignatures.set(outputId, sceneSignature)
    socketIds.forEach((socketId) => publishVideoPlaybackState(outputId, socketId))

    const preloads = resolveAdjacentSceneAssets(outputId)
    preloads.forEach(({ localAsset }) => window.api.send(SCRIM, { channel: "REGISTER_ASSET", data: localAsset }))
    if (preloads.length) {
        console.info(`[Flywire] prewarming assets output=${outputId} count=${preloads.length}`)
        socketIds.forEach((socketId) =>
            window.api.send(SCRIM, {
                id: socketId,
                channel: "PRELOAD_ASSETS",
                data: { outputId, assets: preloads.map(({ ref }) => ref) }
            })
        )
    }
}

function publishVideoPlaybackStates() {
    subscriptions.forEach((outputId, socketId) => publishVideoPlaybackState(outputId, socketId))
}

function publishVideoPlaybackState(outputId: string, socketId: string) {
    const binding = publishedVideoBindings.get(outputId)
    if (!binding) return
    const mediaEntry = get(media)[binding.path]
    const playbackRate = Number(mediaEntry?.speed) || 1
    const clearOnEnd = get(special).clearMediaOnFinish !== false
    const state = resolveFlywireVideoPlaybackState(binding, latestPlayingVideoState, playbackRate, clearOnEnd)
    if (!state) return
    window.api.send(SCRIM, { id: socketId, channel: "PLAYBACK", data: state })
}
