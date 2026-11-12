import { OUTPUT } from "../../../../types/Channels"
import type { FlywireTextItem, FlywireTextLineRange, FlywireTextRun, FlywireTextShadow, FlywireTextStyle } from "../../../../types/Scrim"

export interface ChromiumTextLayoutMeasurement {
    text: string
    visualLines: FlywireTextLineRange[]
    runs: FlywireTextRun[]
    containerWidth: number
    containerHeight: number
    textAlign: FlywireTextItem["textAlign"]
    verticalAlign: FlywireTextItem["verticalAlign"]
}

export type ChromiumTextLayoutOwner = symbol

interface OwnedMeasurement extends ChromiumTextLayoutMeasurement {
    owner: ChromiumTextLayoutOwner
    ipcPublished?: boolean
}

const measurements = new Map<string, OwnedMeasurement>()
const listeners = new Set<() => void>()
const ipcMeasurementOwner = Symbol("flywire-ipc-text-layout")

export interface ChromiumTextLayoutSource {
    showId?: string
    layoutId?: string
    slideIndex?: number
    slideId?: string
}

export function chromiumTextLayoutRevisionKey(item: unknown, outputStyle: unknown, resolution: { width?: number; height?: number }) {
    return JSON.stringify([item, outputStyle || {}, Number(resolution.width) || 0, Number(resolution.height) || 0])
}

export function chromiumTextLayoutSourceKey(source: ChromiumTextLayoutSource, revisionKey = "") {
    return JSON.stringify([source.showId || "", source.layoutId || "", Number.isFinite(source.slideIndex) ? source.slideIndex : -1, source.slideId || "", revisionKey])
}

function measurementKey(outputId: string, itemId: string, sourceKey: string) {
    return `${outputId}\u0000${itemId}\u0000${sourceKey}`
}

export function subscribeChromiumTextLayouts(listener: () => void) {
    listeners.add(listener)
    return () => listeners.delete(listener)
}

export function readChromiumTextLayout(outputId: string, itemId: string, sourceKey: string): ChromiumTextLayoutMeasurement | undefined {
    return measurements.get(measurementKey(outputId, itemId, sourceKey))
}

export function clearChromiumTextLayouts(owner: ChromiumTextLayoutOwner, publishClears = true) {
    let changed = false
    const cleared: { outputId: string; itemId: string; sourceKey: string }[] = []
    for (const [key, measurement] of measurements) {
        if (measurement.owner !== owner) continue
        measurements.delete(key)
        const [outputId, itemId, sourceKey] = key.split("\u0000")
        cleared.push({ outputId, itemId, sourceKey })
        changed = true
    }
    if (changed) {
        if (publishClears) cleared.forEach(({ outputId, itemId, sourceKey }) => publishChromiumTextLayout(outputId, itemId, sourceKey, null))
        listeners.forEach((listener) => listener())
    }
}

/** Receive a measurement forwarded from the isolated output renderer. */
export function receiveChromiumTextLayout(outputId: string, itemId: string, sourceKey: string, measurement: ChromiumTextLayoutMeasurement | null) {
    const key = measurementKey(outputId, itemId, sourceKey)
    const previous = measurements.get(key)
    if (!measurement) {
        // A retiring physical output renderer must not clear a replacement
        // measurement already owned by the main-window Scrim-only host.
        if (!previous || previous.owner !== ipcMeasurementOwner) return
        measurements.delete(key)
        listeners.forEach((listener) => listener())
        return
    }
    if (previous && sameMeasurement(previous, measurement)) return
    measurements.set(key, {
        ...measurement,
        owner: ipcMeasurementOwner,
        ipcPublished: true
    })
    listeners.forEach((listener) => listener())
}

/** Capture visual lines and effective typography from the completed FreeShow DOM. */
export function captureChromiumTextLayout(outputId: string, itemId: string, sourceKey: string, itemElement: HTMLElement, owner: ChromiumTextLayoutOwner) {
    const linesElement = itemElement.querySelector<HTMLElement>(":scope > .align > .lines")
    if (!linesElement) return

    const measurement = measureChromiumTextLayout(linesElement, itemElement.clientWidth, itemElement.clientHeight, itemElement)
    if (!measurement) return

    const key = measurementKey(outputId, itemId, sourceKey)
    let removedOwnedMeasurement = false
    for (const [ownedKey, ownedMeasurement] of measurements) {
        if (ownedKey !== key && ownedMeasurement.owner === owner) {
            measurements.delete(ownedKey)
            removedOwnedMeasurement = true
        }
    }
    const previous = measurements.get(key)
    if (previous && sameMeasurement(previous, measurement)) {
        if (!previous.ipcPublished) {
            publishChromiumTextLayout(outputId, itemId, sourceKey, measurement)
            previous.ipcPublished = true
        }
        if (previous.owner !== owner)
            measurements.set(key, {
                ...measurement,
                owner,
                ipcPublished: previous.ipcPublished
            })
        if (removedOwnedMeasurement) listeners.forEach((listener) => listener())
        return
    }
    measurements.set(key, { ...measurement, owner, ipcPublished: true })
    publishChromiumTextLayout(outputId, itemId, sourceKey, measurement)
    listeners.forEach((listener) => listener())
}

function publishChromiumTextLayout(outputId: string, itemId: string, sourceKey: string, measurement: ChromiumTextLayoutMeasurement | null) {
    window.api.send(OUTPUT, {
        channel: "MAIN_SCRIM_TEXT_LAYOUT",
        data: { outputId, itemId, sourceKey, measurement }
    })
}

/** Attach only measurements proven to describe this exact Flywire string and box. */
export function attachChromiumTextLayout(item: FlywireTextItem, measurement: ChromiumTextLayoutMeasurement | undefined) {
    if (!hasMatchingChromiumTextLayout(item, measurement)) return item
    item.visualLines = measurement.visualLines.map((line) => ({ ...line }))
    item.runs = item.runs.map((run, index) => ({
        ...run,
        style: { ...measurement.runs[index].style }
    }))
    item.textAlign = measurement.textAlign
    item.verticalAlign = measurement.verticalAlign
    return item
}

export function hasMatchingChromiumTextLayout(item: FlywireTextItem, measurement: ChromiumTextLayoutMeasurement | undefined): measurement is ChromiumTextLayoutMeasurement {
    if (!measurement || measurement.text !== item.text) return false
    if (Math.abs(measurement.containerWidth - item.frame.width) > 0.5 || Math.abs(measurement.containerHeight - item.frame.height) > 0.5) return false
    if (!validVisualLines(measurement.visualLines, item.text)) return false
    return measurement.runs.map((run) => run.text).join("") === item.text && sameRunBoundaries(measurement.runs, item.runs)
}

export function measureChromiumTextLayout(linesElement: HTMLElement, containerWidth: number, containerHeight: number, itemElement?: HTMLElement): ChromiumTextLayoutMeasurement | null {
    const blocks = [...linesElement.children].filter((element): element is HTMLElement => element instanceof HTMLElement && element.classList.contains("break") && !element.classList.contains("chords"))
    if (!blocks.length) return null

    let text = ""
    const visualLines: FlywireTextLineRange[] = []
    const runs: FlywireTextRun[] = []

    blocks.forEach((block, blockIndex) => {
        const blockStart = text.length
        const tokens: MeasuredToken[] = []
        const hardBreaks: number[] = []
        const spans = [...block.children].filter((element): element is HTMLElement => element instanceof HTMLElement && element.classList.contains("textContainer"))

        for (const span of spans) {
            const runStart = text.length
            walkRenderedText(span, (value, rect) => {
                const location = text.length
                text += value
                if (value === "\n") hardBreaks.push(location)
                else tokens.push({ location, length: value.length, text: value, rect })
            })
            const runText = text.slice(runStart)
            if (runText) runs.push({ text: runText, style: computedTextStyle(span) })
        }

        const blockEnd = text.length
        let segmentStart = blockStart
        for (const hardBreak of hardBreaks) {
            appendSegmentLines(
                visualLines,
                tokens.filter((token) => token.location >= segmentStart && token.location < hardBreak),
                segmentStart,
                hardBreak
            )
            segmentStart = hardBreak + 1
        }
        appendSegmentLines(
            visualLines,
            tokens.filter((token) => token.location >= segmentStart && token.location < blockEnd),
            segmentStart,
            blockEnd
        )

        if (blockIndex < blocks.length - 1) {
            text += "\n"
            const previousStyle = runs[runs.length - 1]?.style
            if (previousStyle) runs.push({ text: "\n", style: { ...previousStyle } })
        }
    })

    if (!validVisualLines(visualLines, text) || runs.map((run) => run.text).join("") !== text) return null
    const alignElement = itemElement?.querySelector<HTMLElement>(":scope > .align")
    const horizontalStyle = getComputedStyle(blocks[0] || linesElement)
    const verticalStyle = getComputedStyle(alignElement || itemElement || linesElement)
    return {
        text,
        visualLines,
        runs,
        containerWidth,
        containerHeight,
        textAlign: normalizeTextAlign(horizontalStyle.textAlign),
        verticalAlign: normalizeVerticalAlign(verticalStyle.alignItems)
    }
}

function computedTextStyle(element: HTMLElement): FlywireTextStyle {
    const computed = getComputedStyle(element)
    return flywireTextStyleFromComputed({
        fontFamily: computed.fontFamily,
        fontSize: computed.fontSize,
        fontWeight: computed.fontWeight,
        fontStyle: computed.fontStyle,
        color: computed.color,
        textDecorationLine: computed.textDecorationLine,
        letterSpacing: computed.letterSpacing,
        wordSpacing: computed.wordSpacing,
        lineHeight: computed.lineHeight,
        textShadow: computed.textShadow,
        webkitTextStrokeWidth: computed.webkitTextStrokeWidth,
        webkitTextStrokeColor: computed.webkitTextStrokeColor,
        textTransform: computed.textTransform
    })
}

export interface ChromiumComputedTextStyleValues {
    fontFamily: string
    fontSize: string
    fontWeight: string
    fontStyle: string
    color: string
    textDecorationLine?: string
    letterSpacing: string
    wordSpacing: string
    lineHeight: string
    textShadow: string
    webkitTextStrokeWidth: string
    webkitTextStrokeColor: string
    textTransform: string
}

export function flywireTextStyleFromComputed(computed: ChromiumComputedTextStyleValues): FlywireTextStyle {
    const fontFamily = firstFontFamily(computed.fontFamily)
    const fontWeight = numericFontWeight(computed.fontWeight)
    const fontStyle = computed.fontStyle || "normal"
    const fontSize = cssPixels(computed.fontSize)
    return {
        fontFamily,
        fontPostScriptName: resolvedPostScriptName(fontFamily, fontWeight, fontStyle),
        fontSize,
        fontWeight,
        fontStyle,
        italic: fontStyle.includes("italic") || fontStyle.includes("oblique"),
        color: computed.color,
        underline: (computed.textDecorationLine || "").split(/\s+/).includes("underline"),
        letterSpacing: computed.letterSpacing === "normal" ? 0 : cssPixels(computed.letterSpacing),
        wordSpacing: computed.wordSpacing === "normal" ? 0 : cssPixels(computed.wordSpacing),
        lineHeightPx: computed.lineHeight === "normal" ? undefined : cssPixels(computed.lineHeight),
        textShadows: parseTextShadows(computed.textShadow),
        textStrokeWidth: cssPixels(computed.webkitTextStrokeWidth),
        textStrokeColor: computed.webkitTextStrokeColor,
        textTransform: computed.textTransform || "none"
    }
}

function resolvedPostScriptName(fontFamily: string, fontWeight: number, fontStyle: string) {
    if (fontFamily.toLowerCase() !== "cmgsans") return undefined
    const weight = fontWeight >= 600 ? "Bold" : "Medium"
    const italic = fontStyle.includes("italic") || fontStyle.includes("oblique") ? "Italic" : ""
    return `CMGSans-${weight}${italic}`
}

function parseTextShadows(value: string): FlywireTextShadow[] | undefined {
    if (!value || value === "none") return undefined
    const shadows = splitTopLevelCommas(value).flatMap((shadow) => {
        const lengths = shadow.match(/-?(?:\d+\.?\d*|\.\d+)px/g)?.map(cssPixels) || []
        const color = shadow.match(/rgba?\([^)]*\)|#[\da-f]{3,8}|\b(?:transparent|black|white|red|green|blue)\b/i)?.[0]
        if (lengths.length < 2 || !color) return []
        return [
            {
                offsetX: lengths[0],
                offsetY: lengths[1],
                blurRadius: Math.max(0, lengths[2] || 0),
                color
            }
        ]
    })
    return shadows.length ? shadows : undefined
}

function splitTopLevelCommas(value: string) {
    const result: string[] = []
    let depth = 0
    let start = 0
    for (let index = 0; index < value.length; index++) {
        if (value[index] === "(") depth++
        else if (value[index] === ")") depth--
        else if (value[index] === "," && depth === 0) {
            result.push(value.slice(start, index).trim())
            start = index + 1
        }
    }
    result.push(value.slice(start).trim())
    return result.filter(Boolean)
}

function cssPixels(value: string) {
    const parsed = Number.parseFloat(value)
    return Number.isFinite(parsed) ? parsed : 0
}

function numericFontWeight(value: string) {
    if (value === "bold" || value === "bolder") return 700
    if (value === "lighter") return 300
    return Math.min(1000, Math.max(1, cssPixels(value) || 400))
}

function firstFontFamily(value: string) {
    return (
        value
            .split(",")[0]
            ?.trim()
            .replace(/^['"]|['"]$/g, "") || "sans-serif"
    )
}

function normalizeTextAlign(value: string): FlywireTextItem["textAlign"] {
    if (value.includes("justify")) return "justified"
    if (value.includes("left") || value === "start") return "left"
    if (value.includes("right") || value === "end") return "right"
    return "center"
}

function normalizeVerticalAlign(value: string): FlywireTextItem["verticalAlign"] {
    if (value.includes("start") || value.includes("top")) return "top"
    if (value.includes("end") || value.includes("bottom")) return "bottom"
    return "center"
}

function sameRunBoundaries(left: FlywireTextRun[], right: FlywireTextRun[]) {
    return left.length === right.length && left.every((run, index) => run.text === right[index].text)
}

interface MeasuredToken {
    location: number
    length: number
    text: string
    rect: DOMRect
}

function walkRenderedText(element: HTMLElement, emit: (value: string, rect: DOMRect) => void) {
    const visit = (node: Node) => {
        if (node instanceof HTMLBRElement) {
            emit("\n", new DOMRect())
            return
        }
        if (node instanceof Text) {
            const segmenter = new Intl.Segmenter(undefined, {
                granularity: "grapheme"
            })
            for (const segment of segmenter.segment(node.data)) {
                const range = document.createRange()
                range.setStart(node, segment.index)
                range.setEnd(node, segment.index + segment.segment.length)
                emit(segment.segment, range.getClientRects()[0] || range.getBoundingClientRect())
            }
            return
        }
        node.childNodes.forEach(visit)
    }
    element.childNodes.forEach(visit)
}

function appendSegmentLines(target: FlywireTextLineRange[], tokens: MeasuredToken[], segmentStart: number, segmentEnd: number) {
    const visibleTokens = tokens.filter((token) => token.rect.width || !/^\s+$/.test(token.text))
    if (!visibleTokens.length) {
        target.push({ location: segmentStart, length: 0 })
        return
    }

    const rows: { top: number; center: number; height: number; first: number }[] = []
    for (const token of visibleTokens) {
        const center = token.rect.top + token.rect.height / 2
        let row = rows.find((candidate) => Math.abs(candidate.center - center) < Math.min(candidate.height, token.rect.height) / 2)
        if (!row) {
            row = {
                top: token.rect.top,
                center,
                height: token.rect.height,
                first: token.location
            }
            rows.push(row)
        } else {
            row.top = Math.min(row.top, token.rect.top)
            row.first = Math.min(row.first, token.location)
        }
    }
    rows.sort((left, right) => left.top - right.top || left.first - right.first)

    const starts = rows.map((row) => row.first)
    starts[0] = segmentStart
    starts.forEach((location, index) => {
        const end = index + 1 < starts.length ? starts[index + 1] : segmentEnd
        target.push({ location, length: Math.max(0, end - location) })
    })
}

export function validVisualLines(lines: FlywireTextLineRange[], text: string) {
    if (!lines.length) return false
    let previousEnd = 0
    for (const line of lines) {
        if (!Number.isInteger(line.location) || !Number.isInteger(line.length) || line.location < previousEnd || line.length < 0 || line.location + line.length > text.length) return false
        if (text.slice(line.location, line.location + line.length).includes("\n")) return false
        if (/[^\n]/.test(text.slice(previousEnd, line.location))) return false
        previousEnd = line.location + line.length
    }
    return !/[^\n]/.test(text.slice(previousEnd))
}

function sameMeasurement(left: ChromiumTextLayoutMeasurement, right: ChromiumTextLayoutMeasurement) {
    return left.text === right.text && left.containerWidth === right.containerWidth && left.containerHeight === right.containerHeight && left.textAlign === right.textAlign && left.verticalAlign === right.verticalAlign && JSON.stringify(left.visualLines) === JSON.stringify(right.visualLines) && JSON.stringify(left.runs) === JSON.stringify(right.runs)
}
