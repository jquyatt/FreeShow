import fs from "node:fs/promises"
import path from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"
import { _electron as electron, chromium } from "playwright"

const toolsDirectory = path.dirname(fileURLToPath(import.meta.url))
const scrimDirectory = path.resolve(toolsDirectory, "..")
const fixturePath = path.join(scrimDirectory, "Fixtures", "text-fidelity-fixtures.json")
const outputPath = path.resolve(process.argv[2] || path.join(scrimDirectory, "Artifacts", "chromium-fidelity.json"))
const fixtures = JSON.parse(await fs.readFile(fixturePath, "utf8"))

const chromiumExecutable = process.env.SCRIM_CHROMIUM_EXECUTABLE
let controller
let page
let runtime

if (chromiumExecutable) {
    controller = await chromium.launch({ executablePath: chromiumExecutable, headless: true })
    const context = await controller.newContext({
        viewport: { width: 1920, height: 1080 },
        deviceScaleFactor: Number(process.env.SCRIM_DEVICE_SCALE_FACTOR || "1")
    })
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
        engine: await page.evaluate(() => ({
            userAgent: navigator.userAgent,
            devicePixelRatio: window.devicePixelRatio,
            viewport: { width: window.innerWidth, height: window.innerHeight }
        })),
        sourceSemantics: {
            item: "Textbox.svelte .item with overflow:hidden and the FreeShow frame dimensions",
            autosizeTarget: "Textbox.svelte .align cloned by autosize.ts",
            textQuery: ".lines .break span",
            align: "height:100%;display:flex;align-items:center;justify-content:center",
            lines: "width:100%;display:flex;flex-direction:column;justify-content:center",
            break: "width:100%;font-size:0;overflow-wrap:break-word;text-wrap:balance;white-space:pre-wrap",
            padding: 0
        },
        fixtures: []
    }

    for (const fixture of fixtures.fixtures) {
        const browserMetrics = await page.evaluate(
            ({ fixture, fontFamily, lineHeight }) => {
                document.head.innerHTML = ""
                document.body.innerHTML = ""
                document.body.style.cssText = "margin:0;background:#111;"

                const style = document.createElement("style")
                style.textContent = `
                    .item { overflow: hidden; position: relative; }
                    .align { height: 100%; display: flex; text-align: center; align-items: center; justify-content: center; }
                    .lines { width: 100%; display: flex; flex-direction: column; text-align: center; justify-content: center; }
                    .break { width: 100%; font-size: 0; overflow-wrap: break-word; text-wrap: balance; white-space: pre-wrap; }
                    .textContainer { min-height: 50px; }
                    .measureProbe { position: absolute; visibility: hidden; white-space: pre; width: max-content; }
                `
                document.head.append(style)

                const item = document.createElement("div")
                item.id = "fixture"
                item.className = "item"
                item.style.width = `${fixture.frame.width}px`
                item.style.height = `${fixture.frame.height}px`
                const align = document.createElement("div")
                align.className = "align"
                const lines = document.createElement("div")
                lines.className = "lines"
                align.append(lines)
                item.append(align)
                document.body.append(item)

                for (const [index, paragraph] of fixture.paragraphs.entries()) {
                    const line = document.createElement("div")
                    line.className = "break"
                    const span = document.createElement("span")
                    span.id = `probe-${index}`
                    span.className = "textContainer"
                    span.style.cssText = `font-family:${fontFamily};font-size:${fixture.fontSize}px;font-weight:${fixture.fontWeight};line-height:${lineHeight};color:white;`
                    span.textContent = paragraph
                    line.append(span)
                    lines.append(line)
                }

                function freeShowAutosize(element, { type, textQuery, defaultFontSize, maxFontSize, minFontSize } = {}) {
                    const DEF_FONT_SIZE = 100
                    const MAX_FONT_SIZE = 800
                    const MIN_FONT_SIZE = 10
                    const PRECISION = 5
                    minFontSize ||= MIN_FONT_SIZE
                    maxFontSize ||= MAX_FONT_SIZE
                    defaultFontSize ||= Math.max(minFontSize, Math.min(maxFontSize, DEF_FONT_SIZE))

                    const cloned = element.cloneNode(true)
                    cloned.id = "autosize-clone"
                    cloned.style.pointerEvents = "none"
                    cloned.style.position = "absolute"
                    cloned.style.opacity = "0"
                    const computedStyle = getComputedStyle(element)
                    const newWidth = element.clientWidth - parseFloat(computedStyle.paddingRight) - parseFloat(computedStyle.paddingLeft)
                    const newHeight = element.clientHeight - parseFloat(computedStyle.paddingBottom) - parseFloat(computedStyle.paddingTop)
                    cloned.style.width = `${newWidth}px`
                    cloned.style.height = `${newHeight}px`
                    cloned.style.padding = "0"
                    cloned.style.alignItems = "flex-start"
                    element.after(cloned)

                    const boxWidth = cloned.clientWidth
                    const boxHeight = cloned.clientHeight
                    let textChildren = textQuery ? cloned.querySelectorAll(textQuery) : []
                    if (!textChildren.length) textChildren = cloned.children.length ? cloned.children : [cloned]
                    const originalStyles = []
                    let fontSize = defaultFontSize
                    const trace = []

                    function applyFontSize(currentFontSize) {
                        let index = 0
                        for (const textElement of textChildren) {
                            if (!originalStyles[index]) originalStyles[index] = textElement.getAttribute("style") || ""
                            textElement.setAttribute("style", `${originalStyles[index]};overflow:visible;font-size:${currentFontSize}px !important;`)
                            index++
                        }
                    }

                    function measure(candidate) {
                        const result = {
                            candidate,
                            scrollWidth: cloned.scrollWidth,
                            scrollHeight: cloned.scrollHeight,
                            boxWidth,
                            boxHeight
                        }
                        result.overflows = result.scrollWidth > boxWidth || result.scrollHeight > boxHeight
                        trace.push(result)
                        return result.overflows
                    }

                    applyFontSize(fontSize)
                    if (type === "shrinkToFit" && !measure(fontSize)) {
                        cloned.remove()
                        return { fontSize: defaultFontSize, trace }
                    }

                    let lowestValue = minFontSize
                    let highestValue = maxFontSize
                    let previousSize = 0
                    for (;;) {
                        if (measure(fontSize)) highestValue = fontSize - 1
                        else lowestValue = fontSize
                        if (highestValue - lowestValue < PRECISION) break
                        fontSize = (highestValue + lowestValue) * 0.5
                        if (Math.abs(fontSize - previousSize) < 1) break
                        previousSize = fontSize
                        applyFontSize(fontSize)
                    }
                    cloned.remove()
                    return { fontSize: Math.min(maxFontSize, lowestValue), trace }
                }

                const autosize =
                    fixture.textFit === "shrinkToFit"
                        ? freeShowAutosize(align, {
                              type: fixture.textFit,
                              textQuery: ".lines .break span",
                              defaultFontSize: fixture.fontSize
                          })
                        : { fontSize: fixture.fontSize, trace: [] }

                for (const span of lines.querySelectorAll("span")) span.style.setProperty("font-size", `${autosize.fontSize}px`, "important")

                const rect = (element) => {
                    const value = element.getBoundingClientRect()
                    const computed = getComputedStyle(element)
                    return {
                        x: value.x,
                        y: value.y,
                        width: value.width,
                        height: value.height,
                        clientWidth: element.clientWidth,
                        clientHeight: element.clientHeight,
                        scrollWidth: element.scrollWidth,
                        scrollHeight: element.scrollHeight,
                        padding: {
                            top: computed.paddingTop,
                            right: computed.paddingRight,
                            bottom: computed.paddingBottom,
                            left: computed.paddingLeft
                        }
                    }
                }

                const round = (value) => Math.round(value * 1e6) / 1e6
                const fragmentRows = []
                const wordRows = []
                for (const [paragraphIndex, span] of [...lines.querySelectorAll("span")].entries()) {
                    const node = span.firstChild
                    const text = node?.textContent || ""
                    const segmenter = new Intl.Segmenter("en", { granularity: "grapheme" })
                    for (const segment of segmenter.segment(text)) {
                        const range = document.createRange()
                        range.setStart(node, segment.index)
                        range.setEnd(node, segment.index + segment.segment.length)
                        const value = range.getBoundingClientRect()
                        fragmentRows.push({
                            paragraphIndex,
                            index: segment.index,
                            text: segment.segment,
                            x: round(value.x),
                            y: round(value.y),
                            width: round(value.width),
                            height: round(value.height)
                        })
                    }
                    for (const match of text.matchAll(/\S+|\s+/g)) {
                        const range = document.createRange()
                        range.setStart(node, match.index)
                        range.setEnd(node, match.index + match[0].length)
                        const value = range.getBoundingClientRect()
                        wordRows.push({
                            paragraphIndex,
                            range: { location: match.index, length: match[0].length },
                            text: match[0],
                            x: round(value.x),
                            y: round(value.y),
                            width: round(value.width),
                            height: round(value.height)
                        })
                    }
                }

                const visibleLineRows = []
                for (const row of fragmentRows) {
                    if (!row.width && /^\s+$/.test(row.text)) continue
                    let visualLine = visibleLineRows.find((line) => line.paragraphIndex === row.paragraphIndex && Math.abs(line.y - row.y) < 0.5)
                    if (!visualLine) {
                        visualLine = { paragraphIndex: row.paragraphIndex, y: row.y, height: row.height, text: "", minX: row.x, maxX: row.x + row.width, endIndex: 0 }
                        visibleLineRows.push(visualLine)
                    }
                    visualLine.text += row.text
                    visualLine.minX = Math.min(visualLine.minX, row.x)
                    visualLine.maxX = Math.max(visualLine.maxX, row.x + row.width)
                    visualLine.endIndex = Math.max(visualLine.endIndex, row.index + row.text.length)
                }
                visibleLineRows.sort((left, right) => left.y - right.y || left.paragraphIndex - right.paragraphIndex)
                for (const line of visibleLineRows) {
                    line.text = line.text.trimEnd()
                    line.width = round(line.maxX - line.minX)
                    const span = lines.querySelectorAll("span")[line.paragraphIndex]
                    const node = span.firstChild
                    const marker = document.createElement("span")
                    marker.style.cssText = "display:inline-block;width:0;height:0;padding:0;margin:0;vertical-align:baseline;"
                    const range = document.createRange()
                    range.setStart(node, Math.min(line.endIndex, node.length))
                    range.collapse(true)
                    range.insertNode(marker)
                    line.baselineY = round(marker.getBoundingClientRect().top)
                    marker.remove()
                    span.normalize()
                    delete line.minX
                    delete line.maxX
                    delete line.endIndex
                }

                function widthProbe(text, fontKerning, letterSpacing) {
                    const probe = document.createElement("span")
                    probe.className = "measureProbe"
                    probe.style.cssText = `font-family:${fontFamily};font-size:${autosize.fontSize}px;font-weight:${fixture.fontWeight};line-height:${lineHeight};font-kerning:${fontKerning};letter-spacing:${letterSpacing};`
                    probe.textContent = text
                    document.body.append(probe)
                    const width = round(probe.getBoundingClientRect().width)
                    probe.remove()
                    return width
                }

                const firstSpan = lines.querySelector("span")
                const computed = getComputedStyle(firstSpan)
                const computedStyle = {
                    fontFamily: computed.fontFamily,
                    fontSize: computed.fontSize,
                    fontWeight: computed.fontWeight,
                    fontStyle: computed.fontStyle,
                    fontStretch: computed.fontStretch,
                    fontKerning: computed.fontKerning,
                    fontFeatureSettings: computed.fontFeatureSettings,
                    fontVariationSettings: computed.fontVariationSettings,
                    lineHeight: computed.lineHeight,
                    letterSpacing: computed.letterSpacing,
                    wordSpacing: computed.wordSpacing,
                    whiteSpace: getComputedStyle(lines.querySelector(".break")).whiteSpace,
                    overflowWrap: getComputedStyle(lines.querySelector(".break")).overflowWrap,
                    textWrap: getComputedStyle(lines.querySelector(".break")).textWrap,
                    textAlign: computed.textAlign
                }
                const canvas = document.createElement("canvas")
                const canvasContext = canvas.getContext("2d")
                canvasContext.font = `${computed.fontStyle} ${computed.fontWeight} ${computed.fontSize} ${computed.fontFamily}`
                canvasContext.fontKerning = computed.fontKerning
                const canvasMetrics = canvasContext.measureText("Hg")
                const canvasTextMetrics = {
                    font: canvasContext.font,
                    actualBoundingBoxAscent: canvasMetrics.actualBoundingBoxAscent,
                    actualBoundingBoxDescent: canvasMetrics.actualBoundingBoxDescent,
                    fontBoundingBoxAscent: canvasMetrics.fontBoundingBoxAscent,
                    fontBoundingBoxDescent: canvasMetrics.fontBoundingBoxDescent,
                    emHeightAscent: canvasMetrics.emHeightAscent,
                    emHeightDescent: canvasMetrics.emHeightDescent,
                    alphabeticBaseline: canvasMetrics.alphabeticBaseline
                }
                function currentWordLines() {
                    const rows = []
                    for (const [paragraphIndex, span] of [...lines.querySelectorAll("span")].entries()) {
                        const node = span.firstChild
                        const text = node?.textContent || ""
                        for (const match of text.matchAll(/\S+/g)) {
                            const range = document.createRange()
                            range.setStart(node, match.index)
                            range.setEnd(node, match.index + match[0].length)
                            const value = range.getBoundingClientRect()
                            let row = rows.find((candidate) => candidate.paragraphIndex === paragraphIndex && Math.abs(candidate.y - value.y) < 0.5)
                            if (!row) {
                                row = { paragraphIndex, y: value.y, words: [] }
                                rows.push(row)
                            }
                            row.words.push(match[0])
                        }
                    }
                    return rows.sort((left, right) => left.y - right.y || left.paragraphIndex - right.paragraphIndex).map((row) => row.words.join(" "))
                }
                const balancedLines = currentWordLines()
                for (const line of lines.querySelectorAll(".break")) line.style.textWrap = "wrap"
                const unbalancedLines = currentWordLines()
                for (const line of lines.querySelectorAll(".break")) line.style.textWrap = "balance"
                const lineTops = [...new Set(visibleLineRows.map((line) => line.y))].sort((left, right) => left - right)
                return {
                    id: fixture.id,
                    purpose: fixture.purpose,
                    authoredFontSize: fixture.fontSize,
                    resolvedFontSize: autosize.fontSize,
                    fontWeight: fixture.fontWeight,
                    textFit: fixture.textFit,
                    paragraphs: fixture.paragraphs,
                    autosizeTrace: autosize.trace,
                    computedStyle,
                    canvasTextMetrics,
                    boxes: { item: rect(item), align: rect(align), lines: rect(lines), breaks: [...lines.querySelectorAll(".break")].map(rect) },
                    visibleLines: visibleLineRows,
                    content: {
                        top: visibleLineRows.length ? visibleLineRows[0].y : 0,
                        bottom: visibleLineRows.length ? Math.max(...visibleLineRows.map((line) => line.y + line.height)) : 0,
                        height: visibleLineRows.length ? round(Math.max(...visibleLineRows.map((line) => line.y + line.height)) - visibleLineRows[0].y) : 0,
                        baselineStepApproximation: lineTops.length > 1 ? round(lineTops[1] - lineTops[0]) : null,
                        baselineYs: visibleLineRows.map((line) => line.baselineY)
                    },
                    graphemes: fragmentRows,
                    words: wordRows,
                    lineBreakHypotheses: { balanced: balancedLines, unbalanced: unbalancedLines },
                    widthHypotheses: fixture.paragraphs.map((paragraph) => ({
                        text: paragraph,
                        kerningAutoLetterSpacingNormal: widthProbe(paragraph, "auto", "normal"),
                        kerningAutoLetterSpacingZero: widthProbe(paragraph, "auto", "0px"),
                        kerningNoneLetterSpacingZero: widthProbe(paragraph, "none", "0px")
                    }))
                }
            },
            { fixture, fontFamily: fixtures.fontFamily, lineHeight: fixtures.lineHeight }
        )

        const documentNode = await client.send("DOM.getDocument", { depth: 1 })
        const probeNode = await client.send("DOM.querySelector", { nodeId: documentNode.root.nodeId, selector: "#probe-0" })
        browserMetrics.platformFonts = probeNode.nodeId ? (await client.send("CSS.getPlatformFontsForNode", { nodeId: probeNode.nodeId })).fonts : []
        report.fixtures.push(browserMetrics)
    }

    await fs.mkdir(path.dirname(outputPath), { recursive: true })
    await fs.writeFile(outputPath, `${JSON.stringify(report, null, 2)}\n`)
    process.stdout.write(`${outputPath}\n`)
} finally {
    await controller.close()
}
