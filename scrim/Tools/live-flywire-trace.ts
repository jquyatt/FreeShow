import fs from "node:fs/promises"
import path from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"
import type { OutSlide } from "../../src/types/Show"
import { resolveTextItem } from "../../src/frontend/components/output/scrim/scenePrimitives"
import { attachChromiumTextLayout, flywireTextStyleFromComputed } from "../../src/frontend/components/output/scrim/chromiumTextLayout"

const toolsDirectory = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(toolsDirectory, "../..")
const showPath = process.env.SCRIM_TRACE_SHOW
if (!showPath) throw new Error("Set SCRIM_TRACE_SHOW to the path of the FreeShow .show file to trace")
const outputPath = process.env.SCRIM_TRACE_FLYWIRE_OUTPUT || path.join(root, "scrim/Artifacts/live-typography-flywire.json")
const chromiumPath = process.env.SCRIM_TRACE_CHROMIUM_OUTPUT || path.join(root, "scrim/Artifacts/live-typography-chromium.json")
const [, show] = JSON.parse(await fs.readFile(showPath, "utf8"))
const chromium = JSON.parse(await fs.readFile(chromiumPath, "utf8"))
const chromiumByText = new Map(chromium.items.map((item: any) => [item.text, item]))
const wanted = new Set(["HELLO", "hi"])
const traces: unknown[] = []

for (const [slideId, slide] of Object.entries<any>(show.slides || {})) {
    for (const [itemIndex, item] of (slide.items || []).entries()) {
        const sourceText = (item.lines || [])
            .flatMap((line: any) => line.text || [])
            .map((run: any) => run.value || "")
            .join("\n")
        if (!wanted.has(sourceText)) continue
        let flywire = resolveTextItem(item, {
            outputId: "default",
            outputResolution: { width: 1920, height: 1080 },
            outputStyle: {} as any,
            outSlide: { id: showPath, layout: show.settings?.activeLayout, index: 0 } as OutSlide,
            slideId,
            itemIndex,
            lineWindow: {},
            resolveText: (value) => value
        })
        const browser = chromiumByText.get(sourceText) as any
        if (flywire && browser) {
            const style = flywireTextStyleFromComputed(browser.computed)
            flywire = attachChromiumTextLayout(flywire, {
                text: sourceText,
                visualLines: [{ location: 0, length: sourceText.length }],
                runs: [{ text: sourceText, style }],
                containerWidth: browser.geometry.item.width,
                containerHeight: browser.geometry.item.height,
                textAlign: browser.computed.textAlign.includes("left") ? "left" : browser.computed.textAlign.includes("right") ? "right" : "center",
                verticalAlign: browser.computed.alignItems.includes("start") ? "top" : browser.computed.alignItems.includes("end") ? "bottom" : "center"
            })
        }
        traces.push({
            text: sourceText,
            slideId,
            itemIndex,
            source: {
                itemId: item.id ?? null,
                itemStyle: item.style || "",
                align: item.align || "",
                runStyles: (item.lines || []).flatMap((line: any) => line.text || []).map((run: any) => run.style || "")
            },
            flywire
        })
    }
}

const unique = [...new Map((traces as any[]).map((trace) => [trace.text, trace])).values()]
await fs.mkdir(path.dirname(outputPath), { recursive: true })
await fs.writeFile(outputPath, `${JSON.stringify({ generatedAt: new Date().toISOString(), showPath, items: unique }, null, 2)}\n`)
process.stdout.write(`${outputPath}\n`)
