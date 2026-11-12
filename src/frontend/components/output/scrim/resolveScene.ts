import { get } from "svelte/store"
import type { Output } from "../../../../types/Output"
import type { Styles } from "../../../../types/Settings"
import type { OutBackground, OutSlide, Show, Slide } from "../../../../types/Show"
import type { FlywireAssetRef, FlywireLocalAsset, FlywireResolvedScene, FlywireScene, FlywireTextItem, FlywireUnsupportedContent } from "../../../../types/Scrim"
import { media, outputs, showsCache, styles, templates, transitionData } from "../../../stores"
import { shouldItemBeShown } from "../../edit/scripts/itemHelpers"
import { clone } from "../../helpers/array"
import { getCurrentStyle, getMetadata, getOutputLines, getOutputTransitions, getStyleTemplate, setTemplateStyle } from "../../helpers/output"
import { replaceDynamicValues } from "../../helpers/showActions"
import { createAssetId, resolveTextItem } from "./scenePrimitives"
import { attachChromiumTextLayout, chromiumTextLayoutRevisionKey, chromiumTextLayoutSourceKey, hasMatchingChromiumTextLayout, readChromiumTextLayout } from "./chromiumTextLayout"
import { resolveFlywireLayerTransition } from "./transitionState"
import { screenCaptureIntent } from "./liveSource"

/**
 * Resolve one normal FreeShow output into a complete renderer-neutral scene.
 * The companion bundle keeps local asset paths on the Electron side only.
 */
export function resolveSceneBundle(outputId: string, now = Date.now()): FlywireResolvedScene | null {
    const allOutputs = get(outputs)
    const currentOutput = allOutputs[outputId]
    if (!currentOutput || currentOutput.stageOutput || !currentOutput.scrim) return null

    const allStyles = get(styles)
    const currentStyle = getCurrentStyle(allStyles, currentOutput.style)
    const out = clone(currentOutput.out || {})
    const outSlide = out.slide || null
    const show = outSlide?.id && outSlide.id !== "temp" && outSlide.id !== "tempText" ? get(showsCache)[outSlide.id] : undefined
    const resolved = resolveSlide(show, outSlide, currentStyle, outputId)
    const resolution = currentOutput.forcedResolution || currentOutput.bounds || { width: 1920, height: 1080 }
    const canvas = {
        width: positiveNumber(resolution.width, currentOutput.bounds?.width || 1920),
        height: positiveNumber(resolution.height, currentOutput.bounds?.height || 1080)
    }
    const lineWindow = outSlide ? getOutputLines(outSlide, currentStyle.lines) : { start: null, end: null }
    const unsupported: FlywireUnsupportedContent[] = []
    const items: FlywireTextItem[] = []
    const pendingTextLayoutIds: string[] = []

    if (outSlide?.type && !["show", "section"].includes(outSlide.type)) {
        unsupported.push({
            kind: outSlide.type,
            reason: `Slide type '${outSlide.type}' is outside the Scrim prototype.`
        })
    } else if (resolved.slide?.items) {
        resolved.slide.items.forEach((item, itemIndex) => {
            if (!item) return
            const kind = item.type || "text"
            if (kind !== "text") {
                unsupported.push({
                    kind,
                    id: item.id,
                    reason: `Item type '${kind}' continues on the Electron renderer.`
                })
                return
            }
            if (!shouldItemBeShown(item, [], { outputId, slideIndex: outSlide?.index })) return
            if (item.clickReveal && !outSlide?.itemClickReveal) return

            const textItem = resolveTextItem(item, {
                outputId,
                outputResolution: canvas,
                outputStyle: currentStyle,
                outSlide: outSlide!,
                slideId: resolved.slideId,
                itemIndex,
                lineWindow,
                resolveText: (value) =>
                    replaceDynamicValues(value, {
                        type: "show",
                        showId: outSlide!.id,
                        layoutId: outSlide!.layout,
                        slideIndex: outSlide!.index,
                        id: resolved.slideId
                    })
            })
            if (textItem) {
                const revisionKey = chromiumTextLayoutRevisionKey(item, currentStyle, canvas)
                const textLayoutSourceKey = chromiumTextLayoutSourceKey(
                    {
                        showId: outSlide?.id,
                        layoutId: outSlide?.layout,
                        slideIndex: outSlide?.index,
                        slideId: resolved.slideId
                    },
                    revisionKey
                )
                const measurement = readChromiumTextLayout(outputId, textItem.id, textLayoutSourceKey)
                if (!hasMatchingChromiumTextLayout(textItem, measurement)) pendingTextLayoutIds.push(textItem.id)
                items.push(attachChromiumTextLayout(textItem, measurement))
            }
        })
    }

    if (out.effects?.length)
        unsupported.push({
            kind: "effects",
            reason: `${out.effects.length} active effect(s) continue on the Electron renderer.`
        })
    if (out.overlays?.length)
        unsupported.push({
            kind: "overlays",
            reason: `${out.overlays.length} active overlay(s) continue on the Electron renderer.`
        })
    const metadata = outSlide ? getMetadata(show, currentStyle, outSlide, get(templates)) : null
    if (metadata?.length)
        unsupported.push({
            kind: "metadata",
            reason: `${metadata.length} generated metadata item(s) are not in the static Scrim slice.`
        })

    const background = resolveBackground(currentOutput, currentStyle, outSlide, resolved.slide, out.background || null, unsupported)
    const transitions = getOutputTransitions(resolved.slideData, currentStyle.transition, get(transitionData), false)
    const mediaTransition = resolveFlywireLayerTransition(transitions.media, "media", unsupported)
    const textTransition = resolveFlywireLayerTransition(transitions.text, "text", unsupported)

    const scene: FlywireScene = {
        id: `${outputId}:${now}`,
        outputId,
        canvas,
        background: background.value,
        items,
        transition: {
            media: mediaTransition,
            text: textTransition
        },
        unsupported,
        source: {
            showId: outSlide?.id,
            layoutId: outSlide?.layout,
            slideIndex: outSlide?.index,
            slideId: resolved.slideId
        }
    }

    return { scene, localAssets: background.localAssets, pendingTextLayoutIds }
}

export function resolveScene(outputId: string, now = Date.now()): FlywireScene | null {
    return resolveSceneBundle(outputId, now)?.scene || null
}

export interface FlywireAssetPreload {
    ref: FlywireAssetRef
    localAsset: FlywireLocalAsset
}

/** Resolve a bounded window of neighboring slide backgrounds for receiver prewarming. */
export function resolveAdjacentSceneAssets(outputId: string, ahead = 3, behind = 1): FlywireAssetPreload[] {
    const currentOutput = get(outputs)[outputId]
    const outSlide = currentOutput?.out?.slide
    if (!currentOutput || !outSlide?.id || outSlide.id === "temp" || outSlide.id === "tempText") return []

    const show = get(showsCache)[outSlide.id]
    if (!show) return []
    const layoutId = outSlide.layout || show.settings.activeLayout
    const layoutSlides = show.layouts?.[layoutId]?.slides || []
    const currentIndex = outSlide.index ?? -1
    if (currentIndex < 0) return []

    const offsets = [...Array.from({ length: ahead }, (_, index) => index + 1), ...Array.from({ length: behind }, (_, index) => -(index + 1))]
    const result = new Map<string, FlywireAssetPreload>()
    offsets.forEach((offset) => {
        const slideRef = layoutSlides[currentIndex + offset]
        const mediaId = slideRef?.background
        const mediaEntry = mediaId ? show.media?.[mediaId] : undefined
        if (!mediaEntry?.path || (mediaEntry.type && !["image", "video"].includes(mediaEntry.type))) return
        const assetId = createAssetId(mediaEntry.path)
        const kind = mediaEntry.type === "video" ? "video" : "image"
        result.set(assetId, {
            ref: {
                assetId,
                kind,
                url: `/assets/${assetId}`,
                ...(kind === "video" ? { muted: mediaEntry.muted !== false, loop: mediaEntry.loop !== false } : {})
            },
            localAsset: { assetId, path: mediaEntry.path }
        })
    })
    return [...result.values()]
}

function resolveSlide(show: Show | undefined, outSlide: OutSlide | null, currentStyle: Styles, outputId: string) {
    if (!outSlide)
        return {
            slide: null as Slide | null,
            slideId: undefined as string | undefined,
            slideData: null
        }

    let slideId: string | undefined
    let slideData: any = null
    let slide: Slide | null = null
    if (outSlide.id === "temp" || outSlide.id === "tempText") {
        slide = {
            group: null,
            color: null,
            settings: {},
            notes: "",
            items: clone(outSlide.tempItems || [])
        }
    } else {
        const layoutRef = show?.layouts?.[outSlide.layout || show.settings.activeLayout]?.slides || []
        const ref = layoutRef[outSlide.index ?? -1]
        slideId = ref?.id
        slideData = ref?.data || ref || null
        if (slideId && show?.slides?.[slideId]) slide = clone({ ...show.slides[slideId], id: slideId })
    }

    if (slide) slide.items = setTemplateStyle(outSlide, currentStyle, slide.items, outputId, slide.customDynamicValues)
    return { slide, slideId, slideData }
}

function resolveBackground(currentOutput: Output, currentStyle: Styles, outSlide: OutSlide | null, slide: Slide | null, outBackground: OutBackground | null, unsupported: FlywireUnsupportedContent[]) {
    const styleTemplate = outSlide ? getStyleTemplate(outSlide, currentStyle, slide?.customDynamicValues) : null
    const color = currentOutput.transparent ? "transparent" : styleTemplate?.settings?.backgroundColor || slide?.settings?.color || currentStyle.background || outSlide?.settings?.backgroundColor || "black"
    const styleBackground = currentStyle.clearStyleBackgroundOnText && (outSlide || outBackground) ? "" : currentStyle.backgroundImage || ""
    const templateBackground = styleTemplate?.settings?.backgroundPath || ""
    const candidate: OutBackground | null = templateBackground ? { path: templateBackground, type: "image" } : outBackground || (styleBackground ? { path: styleBackground, type: "image" } : null)
    const localAssets: FlywireLocalAsset[] = []
    const value: FlywireScene["background"] = { color }

    if (!candidate) return { value, localAssets }
    const candidateType = candidate.type || "media"
    if (candidateType === "screen") {
        value.live = screenCaptureIntent(candidate.id || candidate.path || "")
        return { value, localAssets }
    }
    if (!["media", "image", "video"].includes(candidateType)) {
        unsupported.push({
            kind: `background:${candidateType}`,
            id: candidate.id,
            reason: `Background type '${candidateType}' continues on the Electron renderer.`
        })
        return { value, localAssets }
    }

    const mediaId = candidate.path || candidate.id || ""
    const mediaEntry = get(media)[mediaId]
    const path = candidate.path || mediaEntry?.path || (candidate.id ? get(media)[candidate.id]?.path : "") || ""
    if (!path) {
        unsupported.push({
            kind: "background:image",
            id: candidate.id,
            reason: "The background image has no resolvable local asset."
        })
        return { value, localAssets }
    }

    const assetId = createAssetId(path)
    const resolvedType = candidateType === "video" || mediaEntry?.type === "video" ? "video" : "image"
    if (resolvedType === "video") {
        value.video = {
            assetId,
            kind: "video",
            url: `/assets/${assetId}`,
            muted: candidate.muted ?? mediaEntry?.muted ?? true,
            loop: candidate.loop ?? mediaEntry?.loop ?? true
        }
    } else {
        value.image = { assetId, kind: "image", url: `/assets/${assetId}` }
    }
    localAssets.push({ assetId, path })
    return { value, localAssets }
}

function finiteNumber(value: any, fallback: number) {
    const number = Number.parseFloat(String(value ?? ""))
    return Number.isFinite(number) ? number : fallback
}

function positiveNumber(value: any, fallback: number) {
    const number = finiteNumber(value, fallback)
    return number > 0 ? number : fallback
}
