import type { FlywireLayerTransition, FlywireTransitionEasing, FlywireUnsupportedContent } from "../../../../types/Scrim"

const flywireTransitionEasings = new Set<FlywireTransitionEasing>(["linear", "back", "sine", "circ", "cubic", "elastic", "bounce"])

/**
 * Translate the effective FreeShow layer transition without approximating its
 * unsupported visual effects. Text uses the authored between-slide override;
 * media uses its incoming override, matching the two output components.
 */
export function resolveFlywireLayerTransition(source: any, layer: "media" | "text", unsupported: FlywireUnsupportedContent[] = []): FlywireLayerTransition {
    const fallbackDuration = layer === "media" ? 800 : 500
    const transition = (layer === "text" ? source?.between || source?.in : source?.in) || source || {}
    const authoredType = String(transition.type || "fade").toLowerCase()
    const durationMs = Math.max(0, finiteNumber(transition.duration, fallbackDuration))
    const authoredEasing = String(transition.easing || "sine").toLowerCase() as FlywireTransitionEasing
    const easing = flywireTransitionEasings.has(authoredEasing) ? authoredEasing : "linear"

    if (authoredType === "none" || durationMs === 0) return { type: "cut", durationMs: 0, easing }
    if (authoredType === "fade") return { type: "fade", durationMs, easing }

    unsupported.push({
        kind: `transition:${layer}`,
        reason: `Scrim supports only None and Fade ${layer} transitions; '${authoredType}' is presented as a hard cut.`
    })
    return { type: "cut", durationMs: 0, easing }
}

function finiteNumber(value: any, fallback: number) {
    const number = Number.parseFloat(String(value ?? ""))
    return Number.isFinite(number) ? number : fallback
}
