import { describe, expect, it } from "vitest"
import type { Item } from "../../../../types/Show"
import { createAssetId, normalizeTextFragment, resolveTextItem } from "./scenePrimitives"
import { resolveFlywireLayerTransition } from "./transitionState"
import { attachChromiumTextLayout, chromiumTextLayoutRevisionKey, chromiumTextLayoutSourceKey, readChromiumTextLayout, receiveChromiumTextLayout, validVisualLines } from "./chromiumTextLayout"

describe("Flywire scene resolution", () => {
    it("publishes independent None/Fade layer transitions with duration and easing", () => {
        expect(resolveFlywireLayerTransition({ type: "none", duration: 800, easing: "sine" }, "media")).toEqual({
            type: "cut",
            durationMs: 0,
            easing: "sine"
        })
        expect(resolveFlywireLayerTransition({ type: "fade", duration: 650, easing: "cubic" }, "text")).toEqual({
            type: "fade",
            durationMs: 650,
            easing: "cubic"
        })
    })

    it("uses the correct FreeShow layer override and hard-cuts unsupported effects", () => {
        expect(
            resolveFlywireLayerTransition(
                {
                    type: "fade",
                    duration: 500,
                    easing: "sine",
                    between: { type: "none", duration: 900, easing: "bounce" }
                },
                "text"
            )
        ).toEqual({ type: "cut", durationMs: 0, easing: "bounce" })

        const unsupported = []
        expect(resolveFlywireLayerTransition({ type: "slide", duration: 700, easing: "sine" }, "media", unsupported)).toEqual({
            type: "cut",
            durationMs: 0,
            easing: "sine"
        })
        expect(unsupported).toHaveLength(1)
    })

    it("flattens visible styled text and carries Chromium autosize", () => {
        const item: Item = {
            id: "lyrics",
            style: "top: 100px;left: 200px;width: 1200px;height: 400px;opacity: 80%;background-color: #101010;",
            align: "display: flex;align-items: center;",
            textFit: "shrinkToFit",
            autoFontSize: 84,
            lines: [
                {
                    align: "text-align: center;",
                    text: [
                        {
                            value: "Hello {name}<br>Again",
                            style: "font-family: Helvetica Neue;font-size: 150px;font-weight: bold;color: #fff;"
                        }
                    ]
                },
                {
                    align: "text-align: center;",
                    text: [
                        {
                            value: "Second line",
                            style: "font-family: Helvetica Neue;font-size: 150px;color: #fff;"
                        }
                    ]
                }
            ]
        }

        const resolved = resolveTextItem(item, {
            outputId: "output-1",
            outputResolution: { width: 1920, height: 1080 },
            outputStyle: { name: "" },
            outSlide: { id: "show-1", layout: "default", index: 0 },
            slideId: "slide-1",
            itemIndex: 0,
            lineWindow: { start: 0, end: 1, clickRevealed: true },
            resolveText: (value) => value.replace("{name}", "World")
        })

        expect(resolved).not.toBeNull()
        expect(resolved?.text).toBe("Hello World\nAgain")
        expect(resolved?.chromiumFontSize).toBe(84)
        expect(resolved?.runs[0].style.fontSize).toBe(84)
        expect(resolved?.opacity).toBe(0.8)
        expect(resolved?.frame).toEqual({
            x: 200,
            y: 100,
            width: 1200,
            height: 400
        })
    })

    it("uses stable opaque asset IDs without embedding paths", () => {
        const path = "/Users/operator/Media/background.png"
        const assetId = createAssetId(path)
        expect(assetId).toMatch(/^asset-[0-9a-f]{8}$/)
        expect(assetId).not.toContain("operator")
        expect(createAssetId(path)).toBe(assetId)
    })

    it("normalizes the small HTML subset FreeShow text runs use", () => {
        expect(normalizeTextFragment("A<br/>B &amp; C <strong>D</strong>")).toBe("A\nB & C D")
    })

    it("attaches only exact, covering Chromium UTF-16 line ranges", () => {
        const text = "Morning by morning new mercies I see"
        const resolved = resolveTextItem(
            {
                id: "lyrics",
                style: "width: 900px;height: 360px;",
                lines: [
                    {
                        text: [
                            {
                                value: text,
                                style: "font-family: Helvetica Neue;font-size: 86px;"
                            }
                        ]
                    }
                ]
            },
            {
                outputId: "output-1",
                outputResolution: { width: 1920, height: 1080 },
                outputStyle: { name: "" },
                outSlide: { id: "show-1", layout: "default", index: 0 },
                itemIndex: 0,
                lineWindow: {},
                resolveText: (value) => value
            }
        )!
        const visualLines = [
            { location: 0, length: 19 },
            { location: 19, length: 17 }
        ]

        expect(validVisualLines(visualLines, text)).toBe(true)
        const computedStyle = {
            ...resolved.runs[0].style,
            fontFamily: "CMGSans",
            fontPostScriptName: "CMGSans-Medium",
            lineHeightPx: 94.6,
            textShadows: [{ offsetX: 2, offsetY: 2, blurRadius: 10, color: "rgb(0, 0, 0)" }]
        }
        const attached = attachChromiumTextLayout(resolved, {
            text,
            visualLines,
            runs: [{ text, style: computedStyle }],
            containerWidth: 900,
            containerHeight: 360,
            textAlign: "center",
            verticalAlign: "center"
        })
        expect(attached.visualLines).toEqual(visualLines)
        expect(attached.runs[0].style).toEqual(computedStyle)
        expect(validVisualLines([{ location: 0, length: 10 }], text)).toBe(false)
    })

    it("overlays computed styles without flattening rich-text run boundaries", () => {
        const resolved = resolveTextItem(
            {
                id: "rich",
                style: "width: 900px;height: 360px;",
                lines: [
                    {
                        text: [
                            { value: "Rich ", style: "font-weight: 400;" },
                            { value: "text", style: "font-weight: 700;" }
                        ]
                    }
                ]
            },
            {
                outputId: "output-1",
                outputResolution: { width: 1920, height: 1080 },
                outputStyle: { name: "" },
                outSlide: { id: "show-1", layout: "default", index: 0 },
                itemIndex: 0,
                lineWindow: {},
                resolveText: (value) => value
            }
        )!
        const measuredRuns = resolved.runs.map((run) => ({
            text: run.text,
            style: {
                ...run.style,
                fontFamily: "CMGSans",
                fontPostScriptName: run.style.fontWeight >= 600 ? "CMGSans-Bold" : "CMGSans-Medium",
                lineHeightPx: 110
            }
        }))
        const attached = attachChromiumTextLayout(resolved, {
            text: "Rich text",
            visualLines: [{ location: 0, length: 9 }],
            runs: measuredRuns,
            containerWidth: 900,
            containerHeight: 360,
            textAlign: "center",
            verticalAlign: "center"
        })

        expect(attached.runs.map((run) => run.text)).toEqual(["Rich ", "text"])
        expect(attached.runs.map((run) => run.style.fontPostScriptName)).toEqual(["CMGSans-Medium", "CMGSans-Bold"])
    })

    it("accepts completed measurements forwarded from the output renderer", () => {
        const sourceKey = chromiumTextLayoutSourceKey({
            showId: "show-1",
            layoutId: "default",
            slideIndex: 6,
            slideId: "slide-7"
        })
        const measurement = {
            text: "HELLO",
            visualLines: [{ location: 0, length: 5 }],
            runs: [
                {
                    text: "HELLO",
                    style: {
                        fontFamily: "CMGSans",
                        fontPostScriptName: "CMGSans-Medium",
                        fontSize: 100,
                        fontWeight: 400,
                        fontStyle: "normal",
                        italic: false,
                        color: "rgb(0, 31, 63)",
                        underline: false,
                        letterSpacing: 0,
                        wordSpacing: 0,
                        lineHeightPx: 110,
                        textShadows: [{ offsetX: 2, offsetY: 2, blurRadius: 10, color: "rgb(0, 0, 0)" }],
                        textStrokeWidth: 0,
                        textStrokeColor: "rgb(0, 0, 0)",
                        textTransform: "none"
                    }
                }
            ],
            containerWidth: 1820,
            containerHeight: 301.94,
            textAlign: "center" as const,
            verticalAlign: "center" as const
        }

        receiveChromiumTextLayout("default", "text-1", sourceKey, measurement)
        expect(readChromiumTextLayout("default", "text-1", sourceKey)).toMatchObject(measurement)
        receiveChromiumTextLayout("default", "text-1", sourceKey, null)
        expect(readChromiumTextLayout("default", "text-1", sourceKey)).toBeUndefined()
    })

    it("does not reuse a text slot measurement across authored slides", () => {
        const firstSlide = chromiumTextLayoutSourceKey({
            showId: "show-1",
            layoutId: "default",
            slideIndex: 0,
            slideId: "slide-1"
        })
        const secondSlide = chromiumTextLayoutSourceKey({
            showId: "show-1",
            layoutId: "default",
            slideIndex: 1,
            slideId: "slide-2"
        })
        const measurement = {
            text: "Same text",
            visualLines: [{ location: 0, length: 9 }],
            runs: [
                {
                    text: "Same text",
                    style: {
                        fontFamily: "CMGSans",
                        fontPostScriptName: "CMGSans-Medium",
                        fontSize: 100,
                        fontWeight: 400,
                        italic: false,
                        color: "white",
                        underline: false,
                        letterSpacing: 0,
                        wordSpacing: 0
                    }
                }
            ],
            containerWidth: 900,
            containerHeight: 360,
            textAlign: "center" as const,
            verticalAlign: "center" as const
        }

        receiveChromiumTextLayout("default", "text-0", firstSlide, measurement)
        expect(readChromiumTextLayout("default", "text-0", firstSlide)).toMatchObject(measurement)
        expect(readChromiumTextLayout("default", "text-0", secondSlide)).toBeUndefined()
        receiveChromiumTextLayout("default", "text-0", firstSlide, null)
    })

    it("invalidates precomputed typography when item, inherited style, or output resolution changes", () => {
        const item = { id: "text-0", lines: [{ text: [{ value: "HELLO" }] }] }
        const style = { name: "Program", template: "template-1" }
        const resolution = { width: 1920, height: 1080 }
        const key = chromiumTextLayoutRevisionKey(item, style, resolution)

        expect(chromiumTextLayoutRevisionKey(item, style, resolution)).toBe(key)
        expect(chromiumTextLayoutRevisionKey({ ...item, style: "font-size: 101px;" }, style, resolution)).not.toBe(key)
        expect(chromiumTextLayoutRevisionKey(item, { ...style, template: "template-2" }, resolution)).not.toBe(key)
        expect(chromiumTextLayoutRevisionKey(item, style, { width: 1280, height: 720 })).not.toBe(key)
    })
})
