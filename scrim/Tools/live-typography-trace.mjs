import fs from "node:fs/promises"
import path from "node:path"
import process from "node:process"
import { pathToFileURL } from "node:url"
import { _electron as electron } from "playwright"

const root = path.resolve(import.meta.dirname, "../..")
const showPath = process.env.SCRIM_TRACE_SHOW
if (!showPath) throw new Error("Set SCRIM_TRACE_SHOW to the path of the FreeShow .show file to trace")
const outputPath = process.env.SCRIM_TRACE_CHROMIUM_OUTPUT || path.join(root, "scrim/Artifacts/live-typography-chromium.json")
const [, show] = JSON.parse(await fs.readFile(showPath, "utf8"))
const wanted = new Set(["HELLO", "hi"])
const items = []

for (const [slideId, slide] of Object.entries(show.slides || {})) {
    for (const [itemIndex, item] of (slide.items || []).entries()) {
        for (const line of item.lines || []) {
            for (const run of line.text || []) {
                if (!wanted.has(run.value)) continue
                items.push({
                    text: run.value,
                    slideId,
                    itemIndex,
                    itemId: String(item.id || `text-${itemIndex}`),
                    itemStyle: item.style || "",
                    runStyle: run.style || ""
                })
            }
        }
    }
}

const uniqueItems = [...new Map(items.map((item) => [item.text, item])).values()]
const app = await electron.launch({
    args: [path.join(root, "scrim/Tools/electron-fidelity-main.cjs")],
    env: { ...process.env, SCRIM_DEVICE_SCALE_FACTOR: "1" }
})

try {
    const page = await app.firstWindow()
    await page.goto(pathToFileURL(path.join(root, "public/index.html")).href)
    const browser = await page.evaluate(
        async ({ items }) => {
            document.head.innerHTML = `
            <style>
                @font-face { font-family: "CMGSans"; src: url("./fonts/CMGSans-Medium.woff2") format("woff2"); }
                @font-face { font-family: "CMGSans"; src: url("./fonts/CMGSans-Bold.woff2") format("woff2"); font-weight: bold; }
                * { box-sizing: border-box; margin: 0; padding: 0; }
                body { width: 1920px; height: 1080px; }
                .slide { position: relative; width: 1920px; height: 1080px; }
                .slide .item { position: absolute; font-family: "CMGSans"; text-shadow: 2px 2px 10px #000000; color: white; font-size: 100px; line-height: 1.1; -webkit-text-stroke-color: #000000; paint-order: stroke fill; }
                .align { height: 100%; display: flex; text-align: center; align-items: center; justify-content: center; overflow: hidden; }
                .lines { width: 100%; display: flex; flex-direction: column; text-align: center; justify-content: center; }
                .break { width: 100%; font-size: 0; overflow-wrap: break-word; text-wrap: balance; white-space: pre-wrap; }
                .textContainer { min-height: 50px; }
                .baselineMarker { display: inline-block; width: 0; height: 0; vertical-align: baseline; }
            </style>`
            document.body.innerHTML = '<div class="slide"></div>'
            const slide = document.querySelector(".slide")
            for (const item of items) {
                const element = document.createElement("div")
                element.className = "item"
                element.dataset.traceText = item.text
                element.style.cssText += item.itemStyle
                element.innerHTML = `<div class="align"><div class="lines"><div class="break"><span class="textContainer"></span></div></div></div>`
                const span = element.querySelector("span")
                span.style.cssText = item.runStyle
                span.textContent = item.text
                const marker = document.createElement("span")
                marker.className = "baselineMarker"
                span.append(marker)
                slide.append(element)
            }
            await document.fonts.ready

            const round = (value) => Math.round(value * 1000) / 1000
            return items.map((item) => {
                const element = document.querySelector(`[data-trace-text="${item.text}"]`)
                const span = element.querySelector("span")
                const computed = getComputedStyle(span)
                const alignComputed = getComputedStyle(element.querySelector(".align"))
                const canvas = document.createElement("canvas").getContext("2d")
                canvas.font = `${computed.fontStyle} ${computed.fontWeight} ${computed.fontSize} ${computed.fontFamily}`
                const metrics = canvas.measureText(item.text)
                const fontAscent = metrics.fontBoundingBoxAscent ?? metrics.actualBoundingBoxAscent
                const fontDescent = metrics.fontBoundingBoxDescent ?? metrics.actualBoundingBoxDescent
                const itemRect = element.getBoundingClientRect()
                const baseline = span.querySelector(".baselineMarker").getBoundingClientRect().top
                const rect = span.getBoundingClientRect()
                return {
                    ...item,
                    computed: {
                        fontFamily: computed.fontFamily,
                        fontSize: computed.fontSize,
                        fontWeight: computed.fontWeight,
                        fontStyle: computed.fontStyle,
                        fontStretch: computed.fontStretch,
                        fontVariationSettings: computed.fontVariationSettings,
                        fontFeatureSettings: computed.fontFeatureSettings,
                        letterSpacing: computed.letterSpacing,
                        wordSpacing: computed.wordSpacing,
                        lineHeight: computed.lineHeight,
                        textDecorationLine: computed.textDecorationLine,
                        textTransform: computed.textTransform,
                        webkitTextStrokeWidth: computed.webkitTextStrokeWidth,
                        webkitTextStrokeColor: computed.webkitTextStrokeColor,
                        textShadow: computed.textShadow,
                        color: computed.color,
                        textAlign: computed.textAlign,
                        alignItems: alignComputed.alignItems
                    },
                    geometry: {
                        item: { x: round(itemRect.x), y: round(itemRect.y), width: round(itemRect.width), height: round(itemRect.height) },
                        span: { x: round(rect.x), y: round(rect.y), width: round(rect.width), height: round(rect.height) },
                        baselineY: round(baseline)
                    },
                    canvas: {
                        font: canvas.font,
                        advance: round(metrics.width),
                        actualBoundingBoxAscent: round(metrics.actualBoundingBoxAscent),
                        actualBoundingBoxDescent: round(metrics.actualBoundingBoxDescent),
                        fontBoundingBoxAscent: round(fontAscent),
                        fontBoundingBoxDescent: round(fontDescent)
                    }
                }
            })
        },
        { items: uniqueItems }
    )

    const client = await page.context().newCDPSession(page)
    await client.send("DOM.enable")
    await client.send("CSS.enable")
    const documentNode = await client.send("DOM.getDocument", { depth: 1 })
    for (const item of browser) {
        const node = await client.send("DOM.querySelector", { nodeId: documentNode.root.nodeId, selector: `[data-trace-text="${item.text}"] .textContainer` })
        item.platformFonts = node.nodeId ? (await client.send("CSS.getPlatformFontsForNode", { nodeId: node.nodeId })).fonts : []
    }

    const report = {
        generatedAt: new Date().toISOString(),
        showPath,
        engine: await page.evaluate(() => ({ userAgent: navigator.userAgent, devicePixelRatio: window.devicePixelRatio })),
        items: browser
    }
    await fs.mkdir(path.dirname(outputPath), { recursive: true })
    await fs.writeFile(outputPath, `${JSON.stringify(report, null, 2)}\n`)
    process.stdout.write(`${outputPath}\n`)
} finally {
    await app.close()
}
