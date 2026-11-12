import type { Styles } from "../../../../types/Settings"
import type { Item, Line, OutSlide } from "../../../../types/Show"
import type { FlywireTextItem, FlywireTextRun, FlywireTextStyle } from "../../../../types/Scrim"
import { getStyles } from "../../helpers/style"

export interface ResolveTextItemOptions {
    outputId: string
    outputResolution: { width: number; height: number }
    outputStyle: Styles
    outSlide: OutSlide
    slideId?: string
    itemIndex: number
    lineWindow: {
        start?: number | null
        end?: number | null
        linesStart?: number | null
        linesEnd?: number | null
        clickRevealed?: boolean
    }
    resolveText: (value: string) => string
}

const DEFAULT_FONT_SIZE = 100
const DEFAULT_WIDTH = 1920
const DEFAULT_HEIGHT = 1080

export function resolveTextItem(item: Item, options: ResolveTextItemOptions): FlywireTextItem | null {
    const itemStyles = getStyles(item.style || "")
    const positionStyles = resolvePositionStyles(itemStyles, options.outputResolution)
    const alignmentStyles = getStyles(item.align || "")
    const lines = selectVisibleLines(item.lines || [], item.lineReveal ? options.lineWindow.linesStart : options.lineWindow.start, item.lineReveal ? options.lineWindow.linesEnd : options.lineWindow.end)

    const runs: FlywireTextRun[] = []
    lines.forEach((line, lineIndex) => {
        ;(line.text || []).forEach((part) => {
            const value = normalizeTextFragment(options.resolveText(part.value || ""))
            if (!value) return
            runs.push({
                text: value,
                style: resolveTextStyle(item, itemStyles, getStyles(part.style || ""))
            })
        })
        if (lineIndex < lines.length - 1) {
            const fallback = runs[runs.length - 1]?.style || resolveTextStyle(item, itemStyles, {})
            runs.push({ text: "\n", style: fallback })
        }
    })
    const text = runs.map((run) => run.text).join("")
    if (!text.length) return null

    const textAlignValue = String(itemStyles["text-align"] || lines[0]?.align || "center")
    const verticalValue = String(alignmentStyles["align-items"] || itemStyles["align-items"] || "center")
    const textFit = item.textFit || (item.auto ? "shrinkToFit" : "none")

    return {
        id: String(item.id || `text-${options.itemIndex}`),
        kind: "text",
        frame: {
            x: finiteNumber(positionStyles.left, 0),
            y: finiteNumber(positionStyles.top, 0),
            width: positiveNumber(positionStyles.width, options.outputResolution.width),
            height: positiveNumber(positionStyles.height, options.outputResolution.height)
        },
        text,
        runs,
        textAlign: textAlignValue.includes("justify") ? "justified" : textAlignValue.includes("left") ? "left" : textAlignValue.includes("right") ? "right" : "center",
        verticalAlign: verticalValue.includes("start") || verticalValue.includes("top") ? "top" : verticalValue.includes("end") || verticalValue.includes("bottom") ? "bottom" : "center",
        opacity: parseOpacity(itemStyles.opacity || getFilterFunction(item.style, "opacity")),
        backgroundColor: itemStyles["background-color"] || undefined,
        textFit,
        chromiumFontSize: item.autoFontSize || undefined
    }
}

function resolvePositionStyles(styles: Record<string, any>, resolution: { width: number; height: number }) {
    return {
        left: (finiteNumber(styles.left, 0) / DEFAULT_WIDTH) * resolution.width,
        top: (finiteNumber(styles.top, 0) / DEFAULT_HEIGHT) * resolution.height,
        width: (finiteNumber(styles.width, DEFAULT_WIDTH) / DEFAULT_WIDTH) * resolution.width,
        height: (finiteNumber(styles.height, DEFAULT_HEIGHT) / DEFAULT_HEIGHT) * resolution.height
    }
}

function resolveTextStyle(item: Item, itemStyles: Record<string, any>, runStyles: Record<string, any>): FlywireTextStyle {
    const computedFontSize = item.autoFontSize || finiteNumber(runStyles["font-size"] || itemStyles["font-size"], DEFAULT_FONT_SIZE)
    const fontSize = positiveNumber(computedFontSize, DEFAULT_FONT_SIZE)
    const weightValue = String(runStyles["font-weight"] || itemStyles["font-weight"] || "400")
    const numericWeight = weightValue === "bold" ? 700 : Math.min(900, Math.max(100, finiteNumber(weightValue, 400)))
    const fontStyle = String(runStyles["font-style"] || itemStyles["font-style"] || "normal")
    const fontFamily = normalizeFontFamily(String(runStyles["font-family"] || itemStyles["font-family"] || "Helvetica"))
    const lineHeightValue = runStyles["line-height"] || itemStyles["line-height"]
    return {
        fontFamily,
        fontPostScriptName: resolvedPostScriptName(fontFamily, numericWeight, fontStyle),
        fontSize,
        fontWeight: numericWeight,
        fontStyle,
        italic: fontStyle.includes("italic") || fontStyle.includes("oblique"),
        color: String(runStyles.color || itemStyles.color || "white"),
        underline: String(runStyles["text-decoration"] || itemStyles["text-decoration"] || "").includes("underline"),
        letterSpacing: finiteNumber(runStyles["letter-spacing"] || itemStyles["letter-spacing"], 0),
        wordSpacing: finiteNumber(runStyles["word-spacing"] || itemStyles["word-spacing"], 0),
        lineHeight: parseLineHeight(lineHeightValue, fontSize),
        lineHeightPx: String(lineHeightValue || "")
            .trim()
            .endsWith("px")
            ? positiveNumber(lineHeightValue, fontSize)
            : undefined,
        textShadows: parseTextShadows(String(runStyles["text-shadow"] || itemStyles["text-shadow"] || "none")),
        textStrokeWidth: finiteNumber(runStyles["-webkit-text-stroke-width"] || itemStyles["-webkit-text-stroke-width"], 0),
        textStrokeColor: String(runStyles["-webkit-text-stroke-color"] || itemStyles["-webkit-text-stroke-color"] || "black"),
        textTransform: String(runStyles["text-transform"] || itemStyles["text-transform"] || "none")
    }
}

function resolvedPostScriptName(fontFamily: string, fontWeight: number, fontStyle: string) {
    if (fontFamily.toLowerCase() !== "cmgsans") return undefined
    return `CMGSans-${fontWeight >= 600 ? "Bold" : "Medium"}${fontStyle.includes("italic") || fontStyle.includes("oblique") ? "Italic" : ""}`
}

function parseTextShadows(value: string) {
    if (!value || value === "none") return undefined
    const color = value.match(/rgba?\([^)]*\)|#[\da-f]{3,8}|\b(?:transparent|black|white|red|green|blue)\b/i)?.[0]
    const lengths = value.match(/-?(?:\d+\.?\d*|\.\d+)px/g)?.map((length) => finiteNumber(length, 0)) || []
    if (!color || lengths.length < 2) return undefined
    return [
        {
            offsetX: lengths[0],
            offsetY: lengths[1],
            blurRadius: Math.max(0, lengths[2] || 0),
            color
        }
    ]
}

function selectVisibleLines(lines: Line[], start: number | null | undefined, end: number | null | undefined) {
    if (start === null || start === undefined || end === null || end === undefined) return lines
    if (!lines[start]) {
        const count = Math.max(1, end - start)
        const lastStart = Math.max(0, lines.length - (lines.length % count || count))
        return lines.slice(lastStart, lastStart + count)
    }
    return lines.slice(start, end)
}

export function normalizeTextFragment(value: string): string {
    return value
        .replace(/<br\s*\/?\s*>/gi, "\n")
        .replace(/<[^>]*>/g, "")
        .replace(/&nbsp;/gi, " ")
        .replace(/&amp;/gi, "&")
        .replace(/&lt;/gi, "<")
        .replace(/&gt;/gi, ">")
        .replace(/&quot;/gi, '"')
        .replace(/&#39;/gi, "'")
}

export function createAssetId(path: string): string {
    let hash = 0x811c9dc5
    for (let i = 0; i < path.length; i++) {
        hash ^= path.charCodeAt(i)
        hash = Math.imul(hash, 0x01000193)
    }
    return `asset-${(hash >>> 0).toString(16).padStart(8, "0")}`
}

function normalizeFontFamily(value: string) {
    return (
        value
            .split(",")[0]
            .trim()
            .replace(/^['"]|['"]$/g, "") || "Helvetica"
    )
}

function getFilterFunction(style: string | undefined, name: string) {
    const match = style?.match(new RegExp(`${name}\\(([^)]+)\\)`))
    return match?.[1]
}

function parseOpacity(value: any) {
    if (typeof value === "string" && value.trim().endsWith("%")) return Math.min(1, Math.max(0, finiteNumber(value, 100) / 100))
    return Math.min(1, Math.max(0, finiteNumber(value, 1)))
}

function parseLineHeight(value: any, fontSize: number) {
    if (value === undefined || value === null || value === "") return undefined
    const stringValue = String(value).trim()
    const number = Number.parseFloat(String(value))
    if (!Number.isFinite(number)) return undefined
    if (stringValue.endsWith("%")) return number / 100
    if (stringValue.endsWith("px")) return number / fontSize
    return number
}

function finiteNumber(value: any, fallback: number) {
    const number = Number.parseFloat(String(value ?? ""))
    return Number.isFinite(number) ? number : fallback
}

function positiveNumber(value: any, fallback: number) {
    const number = finiteNumber(value, fallback)
    return number > 0 ? number : fallback
}
