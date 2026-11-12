export const FLYWIRE_PROTOCOL_VERSION = 1 as const

export interface FlywireSize {
    width: number
    height: number
}

export interface FlywireRect extends FlywireSize {
    x: number
    y: number
}

export interface FlywireAssetRef {
    assetId: string
    kind: "image" | "video"
    url: string
    muted?: boolean
    loop?: boolean
}

/** Authoritative FreeShow playback state for one published video scene. */
export interface FlywireVideoPlaybackState {
    outputId: string
    sceneId: string
    assetId: string
    positionSeconds: number
    durationSeconds: number
    paused: boolean
    loop: boolean
    clearOnEnd: boolean
    playbackRate: number
    sentAt: number
}

export interface FlywireBackground {
    color: string
    image?: FlywireAssetRef
    video?: FlywireAssetRef
    live?: FlywireLiveSourceRef
}

/** Local capture intent. Frames never travel over Flywire. IDs are host/session scoped. */
export interface FlywireLiveSourceRef {
    kind: "screenCapture"
    sourceId: string
    target: "display" | "window"
    nativeId?: number
    fit: "contain" | "cover" | "fill"
    /** Normalized top-left source rectangle, applied before fit. */
    crop?: FlywireRect
    showsCursor: boolean
    muted: true
}

export interface FlywireTextShadow {
    offsetX: number
    offsetY: number
    blurRadius: number
    color: string
}

export interface FlywireTextStyle {
    fontFamily: string
    /** Exact face selected by Chromium when it can be resolved. */
    fontPostScriptName?: string
    fontSize: number
    fontWeight: number
    fontStyle?: string
    italic: boolean
    color: string
    underline: boolean
    letterSpacing: number
    wordSpacing: number
    /** Legacy unitless line-height multiplier. */
    lineHeight?: number
    /** Chromium's effective computed line-height in canvas pixels. */
    lineHeightPx?: number
    textShadows?: FlywireTextShadow[]
    textStrokeWidth?: number
    textStrokeColor?: string
    textTransform?: string
}

export interface FlywireTextRun {
    text: string
    style: FlywireTextStyle
}

/** A half-open UTF-16 range into FlywireTextItem.text. */
export interface FlywireTextLineRange {
    location: number
    length: number
}

export interface FlywireTextItem {
    id: string
    kind: "text"
    frame: FlywireRect
    text: string
    runs: FlywireTextRun[]
    visualLines?: FlywireTextLineRange[]
    textAlign: "left" | "center" | "right" | "justified"
    verticalAlign: "top" | "center" | "bottom"
    opacity: number
    backgroundColor?: string
    textFit: "none" | "shrinkToFit" | "growToFit"
    chromiumFontSize?: number
}

export type FlywireItem = FlywireTextItem

export type FlywireTransitionEasing = "linear" | "back" | "sine" | "circ" | "cubic" | "elastic" | "bounce"

export interface FlywireLayerTransition {
    type: "cut" | "fade"
    durationMs: number
    easing: FlywireTransitionEasing
}

export interface FlywireUnsupportedContent {
    kind: string
    id?: string
    reason: string
}

export interface FlywireScene {
    id: string
    outputId: string
    canvas: FlywireSize
    background: FlywireBackground
    items: FlywireItem[]
    transition: {
        media: FlywireLayerTransition
        text: FlywireLayerTransition
    }
    unsupported: FlywireUnsupportedContent[]
    source: {
        showId?: string
        layoutId?: string
        slideIndex?: number
        slideId?: string
    }
}

export interface FlywireSceneEnvelope {
    protocol: "flywire"
    version: typeof FLYWIRE_PROTOCOL_VERSION
    type: "scene"
    sequence: number
    sentAt: number
    scene: FlywireScene
}

export interface FlywireLocalAsset {
    assetId: string
    path: string
}

export interface FlywireResolvedScene {
    scene: FlywireScene
    localAssets: FlywireLocalAsset[]
    /** Native text cannot be published until Chromium supplies these layouts. */
    pendingTextLayoutIds: string[]
}
