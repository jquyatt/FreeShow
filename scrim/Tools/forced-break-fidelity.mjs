import fs from "node:fs/promises"
import path from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"
import { _electron as electron, chromium } from "playwright"

const toolsDirectory = path.dirname(fileURLToPath(import.meta.url))
const scrimDirectory = path.resolve(toolsDirectory, "..")
const fixturePath = path.join(scrimDirectory, "Fixtures", "forced-break-fidelity-fixtures.json")
const outputPath = path.resolve(process.argv[2] || path.join(scrimDirectory, "Artifacts", "forced-break-chromium.json"))
const fixtureFile = JSON.parse(await fs.readFile(fixturePath, "utf8"))

const chromiumExecutable = process.env.SCRIM_CHROMIUM_EXECUTABLE
let controller
let page
let runtime

if (chromiumExecutable) {
    controller = await chromium.launch({ executablePath: chromiumExecutable, headless: true })
    const context = await controller.newContext({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: Number(process.env.SCRIM_DEVICE_SCALE_FACTOR || "1") })
    page = await context.newPage()
    runtime = { kind: "standalone-chromium", executable: chromiumExecutable }
} else {
    controller = await electron.launch({
        args: [path.join(toolsDirectory, "electron-fidelity-main.cjs")],
        env: { ...process.env, SCRIM_DEVICE_SCALE_FACTOR: process.env.SCRIM_DEVICE_SCALE_FACTOR || "1" }
    })
    page = await controller.firstWindow()
    await page.waitForLoadState("domcontentloaded")
    runtime = await controller.evaluate(() => ({ kind: "electron", versions: process.versions }))
}

try {
    const client = await page.context().newCDPSession(page)
    await client.send("DOM.enable")
    await client.send("CSS.enable")
    const report = {
        generatedAt: new Date().toISOString(),
        fixturePath,
        runtime,
        engine: await page.evaluate(() => ({ userAgent: navigator.userAgent, devicePixelRatio: window.devicePixelRatio })),
        contract: {
            rangeUnit: "UTF-16 code units",
            rangeModel: "half-open location/length into the canonical concatenated run text",
            explicitNewlines: "excluded gaps between visual line ranges",
            shapingOwner: "CoreText; Chromium publishes no glyph IDs or shaped glyph positions"
        },
        fixtures: []
    }

    for (const fixture of fixtureFile.fixtures) {
        const metrics = await page.evaluate(
            async ({ fixture, fontFamily, lineHeight }) => {
                const round = (value) => Math.round(value * 1e6) / 1e6
                document.head.innerHTML = ""
                document.body.innerHTML = ""
                document.body.style.cssText = "margin:0;background:#111;"

                const style = document.createElement("style")
                style.textContent = `
                    .item { overflow:hidden;position:relative; }
                    .align { height:100%;display:flex;align-items:center;justify-content:center; }
                    .lines { width:100%;display:flex;flex-direction:column;justify-content:center; }
                    .break { width:100%;font-size:0;overflow-wrap:break-word;white-space:pre-wrap; }
                    .textContainer { min-height:50px; }
                `
                document.head.append(style)

                const item = document.createElement("div")
                item.id = "fixture"
                item.className = "item"
                item.style.cssText = `width:${fixture.frame.width}px;height:${fixture.frame.height}px;`
                const align = document.createElement("div")
                align.className = "align"
                const lines = document.createElement("div")
                lines.className = "lines"
                lines.style.textAlign = fixture.alignment
                align.append(lines)
                item.append(align)
                document.body.append(item)

                const canonicalText = fixture.runs.map((run) => run.text).join("")
                let breakElement = document.createElement("div")
                breakElement.className = "break"
                breakElement.style.textWrap = fixture.textWrap || "balance"
                lines.append(breakElement)
                let globalLocation = 0
                fixture.runs.forEach((run, runIndex) => {
                    const fragments = run.text.split("\n")
                    fragments.forEach((fragment, fragmentIndex) => {
                        if (fragment.length) {
                            const span = document.createElement("span")
                            span.id = `probe-${runIndex}-${fragmentIndex}`
                            span.className = "textContainer"
                            span.dataset.runIndex = String(runIndex)
                            span.dataset.location = String(globalLocation)
                            span.style.cssText = `font-family:${fontFamily};font-size:${fixture.fontSize}px;font-weight:${run.fontWeight};font-style:${run.italic ? "italic" : "normal"};line-height:${lineHeight};letter-spacing:${run.letterSpacing || 0}px;word-spacing:${run.wordSpacing || 0}px;color:white;`
                            span.textContent = fragment
                            breakElement.append(span)
                        }
                        globalLocation += fragment.length
                        if (fragmentIndex < fragments.length - 1) {
                            globalLocation++
                            breakElement = document.createElement("div")
                            breakElement.className = "break"
                            breakElement.style.textWrap = fixture.textWrap || "balance"
                            lines.append(breakElement)
                        }
                    })
                })

                await document.fonts.ready

                function freeShowAutosize(element, { type, textQuery, defaultFontSize }) {
                    const cloned = element.cloneNode(true)
                    cloned.style.cssText += ";pointer-events:none;position:absolute;opacity:0;"
                    const computed = getComputedStyle(element)
                    cloned.style.width = `${element.clientWidth - parseFloat(computed.paddingRight) - parseFloat(computed.paddingLeft)}px`
                    cloned.style.height = `${element.clientHeight - parseFloat(computed.paddingBottom) - parseFloat(computed.paddingTop)}px`
                    cloned.style.padding = "0"
                    cloned.style.alignItems = "flex-start"
                    element.after(cloned)
                    const children = cloned.querySelectorAll(textQuery)
                    const originalStyles = [...children].map((child) => child.getAttribute("style") || "")
                    let fontSize = defaultFontSize
                    const trace = []
                    const apply = (candidate) => children.forEach((child, index) => child.setAttribute("style", `${originalStyles[index]};overflow:visible;font-size:${candidate}px !important;`))
                    const overflows = (candidate) => {
                        const value = { candidate, scrollWidth: cloned.scrollWidth, scrollHeight: cloned.scrollHeight, boxWidth: cloned.clientWidth, boxHeight: cloned.clientHeight }
                        value.overflows = value.scrollWidth > value.boxWidth || value.scrollHeight > value.boxHeight
                        trace.push(value)
                        return value.overflows
                    }
                    apply(fontSize)
                    if (type === "shrinkToFit" && !overflows(fontSize)) {
                        cloned.remove()
                        return { fontSize: defaultFontSize, trace }
                    }
                    let lower = 10
                    let upper = 800
                    let previous = 0
                    for (;;) {
                        if (overflows(fontSize)) upper = fontSize - 1
                        else lower = fontSize
                        if (upper - lower < 5) break
                        fontSize = (upper + lower) * 0.5
                        if (Math.abs(fontSize - previous) < 1) break
                        previous = fontSize
                        apply(fontSize)
                    }
                    cloned.remove()
                    return { fontSize: Math.min(800, lower), trace }
                }

                const autosize = fixture.textFit === "shrinkToFit" ? freeShowAutosize(align, { type: fixture.textFit, textQuery: ".lines .break span", defaultFontSize: fixture.fontSize }) : { fontSize: fixture.fontSize, trace: [] }
                lines.querySelectorAll("span").forEach((span) => span.style.setProperty("font-size", `${autosize.fontSize}px`, "important"))

                const itemRect = item.getBoundingClientRect()
                const tokens = []
                const segmenter = new Intl.Segmenter("en", { granularity: "grapheme" })
                lines.querySelectorAll("span.textContainer").forEach((span) => {
                    const node = span.firstChild
                    const start = Number(span.dataset.location)
                    const runIndex = Number(span.dataset.runIndex)
                    for (const segment of segmenter.segment(node.data)) {
                        const range = document.createRange()
                        range.setStart(node, segment.index)
                        range.setEnd(node, segment.index + segment.segment.length)
                        const rect = range.getClientRects()[0] || range.getBoundingClientRect()
                        tokens.push({
                            location: start + segment.index,
                            length: segment.segment.length,
                            text: segment.segment,
                            runIndex,
                            node,
                            localStart: segment.index,
                            localEnd: segment.index + segment.segment.length,
                            x: rect.x - itemRect.x,
                            y: rect.y - itemRect.y,
                            width: rect.width,
                            height: rect.height
                        })
                    }
                })

                const visualLines = []
                let segmentStart = 0
                const paragraphEnds = [...canonicalText.matchAll(/\n/g)].map((match) => match.index)
                paragraphEnds.push(canonicalText.length)
                for (const segmentEnd of paragraphEnds) {
                    const segmentTokens = tokens.filter((token) => token.location >= segmentStart && token.location < segmentEnd && (token.width || !/^\s+$/.test(token.text)))
                    const rows = []
                    for (const token of segmentTokens) {
                        const center = token.y + token.height / 2
                        let row = rows.find((candidate) => Math.abs(candidate.center - center) < Math.min(candidate.height, token.height) / 2)
                        if (!row) {
                            row = { y: token.y, center, height: token.height, tokens: [] }
                            rows.push(row)
                        }
                        row.y = Math.min(row.y, token.y)
                        row.tokens.push(token)
                    }
                    rows.sort((left, right) => left.y - right.y)
                    if (!rows.length) rows.push({ y: 0, tokens: [] })
                    const starts = rows.map((row) => row.tokens[0]?.location ?? segmentStart)
                    starts[0] = segmentStart
                    rows.forEach((row, index) => {
                        const location = starts[index]
                        const end = index + 1 < starts.length ? starts[index + 1] : segmentEnd
                        const runAdvances = []
                        for (const runIndex of [...new Set(row.tokens.map((token) => token.runIndex))]) {
                            const runTokens = row.tokens.filter((token) => token.runIndex === runIndex)
                            const runStart = Math.min(...runTokens.map((token) => token.location))
                            const runEnd = Math.max(...runTokens.map((token) => token.location + token.length))
                            const range = document.createRange()
                            range.setStart(runTokens[0].node, runTokens[0].localStart)
                            range.setEnd(runTokens.at(-1).node, runTokens.at(-1).localEnd)
                            const rects = [...range.getClientRects()].filter((rect) => Math.abs(rect.y - itemRect.y + rect.height / 2 - row.center) < Math.min(row.height, rect.height) / 2)
                            const minX = Math.min(...rects.map((rect) => rect.x - itemRect.x))
                            const maxX = Math.max(...rects.map((rect) => rect.right - itemRect.x))
                            runAdvances.push({
                                runIndex,
                                range: { location: runStart, length: runEnd - runStart },
                                x: round(minX),
                                advance: round(maxX - minX)
                            })
                        }
                        const minX = runAdvances.length ? Math.min(...runAdvances.map((run) => run.x)) : 0
                        const maxX = runAdvances.length ? Math.max(...runAdvances.map((run) => run.x + run.advance)) : minX
                        visualLines.push({
                            range: { location, length: end - location },
                            text: canonicalText.slice(location, end),
                            x: round(minX),
                            y: round(row.y),
                            width: round(maxX - minX),
                            height: round(row.tokens[0]?.height || autosize.fontSize * lineHeight),
                            baselineY: 0,
                            runAdvances
                        })
                    })
                    segmentStart = segmentEnd + 1
                }

                for (const line of [...visualLines].reverse()) {
                    const lastToken = tokens.filter((token) => token.location < line.range.location + line.range.length && token.location >= line.range.location).at(-1)
                    if (!lastToken) continue
                    const marker = document.createElement("span")
                    marker.style.cssText = "display:inline-block;width:0;height:0;padding:0;margin:0;vertical-align:baseline;"
                    const range = document.createRange()
                    range.setStart(lastToken.node, Math.min(lastToken.localEnd, lastToken.node.length))
                    range.collapse(true)
                    range.insertNode(marker)
                    line.baselineY = round(marker.getBoundingClientRect().top - itemRect.top)
                    marker.remove()
                }
                lines.querySelectorAll("span.textContainer").forEach((span) => span.normalize())

                const linesRect = lines.getBoundingClientRect()
                return {
                    id: fixture.id,
                    purpose: fixture.purpose,
                    text: canonicalText,
                    authoredRuns: fixture.runs,
                    visualLines,
                    resolvedFontSize: autosize.fontSize,
                    autosizeTrace: autosize.trace,
                    frame: fixture.frame,
                    alignment: fixture.alignment,
                    textFit: fixture.textFit,
                    lineHeight: autosize.fontSize * lineHeight,
                    blockBounds: { x: round(linesRect.x - itemRect.x), y: round(linesRect.y - itemRect.y), width: round(linesRect.width), height: round(linesRect.height) },
                    graphemeAdvances: tokens.map(({ node, localStart, localEnd, ...token }) => ({ ...token, x: round(token.x), y: round(token.y), width: round(token.width), height: round(token.height) }))
                }
            },
            { fixture, fontFamily: fixtureFile.fontFamily, lineHeight: fixtureFile.lineHeight }
        )

        const documentNode = await client.send("DOM.getDocument", { depth: 1 })
        const fonts = []
        for (let runIndex = 0; runIndex < fixture.runs.length; runIndex++) {
            const probe = await client.send("DOM.querySelector", { nodeId: documentNode.root.nodeId, selector: `#probe-${runIndex}-0` })
            if (probe.nodeId) fonts.push(...(await client.send("CSS.getPlatformFontsForNode", { nodeId: probe.nodeId })).fonts)
        }
        metrics.platformFonts = [...new Map(fonts.map((font) => [`${font.familyName}:${font.postScriptName}`, font])).values()]
        report.fixtures.push(metrics)
    }

    await fs.mkdir(path.dirname(outputPath), { recursive: true })
    await fs.writeFile(outputPath, `${JSON.stringify(report, null, 2)}\n`)
    process.stdout.write(`${outputPath}\n`)
} finally {
    await controller.close()
}
