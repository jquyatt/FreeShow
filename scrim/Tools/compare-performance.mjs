#!/usr/bin/env node

import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const performanceDirectory = join(scriptDirectory, "..", "Artifacts", "performance")
const run = process.argv[2] || "run1"

const labels = {
    "electron-only": {
        still: `electron-only-still-present-on-${run}`,
        video: `electron-only-looping-video-${run}`,
        takes: `electron-only-active-takes-${run}`
    },
    dual: {
        still: `dual-still-present-on-${run}`,
        video: `dual-looping-video-${run}`,
        takes: `dual-active-takes-${run}`
    },
    "scrim-only": {
        still: `scrim-only-still-${run}`,
        video: `scrim-only-looping-video-${run}`,
        takes: `scrim-only-active-takes-${run}`
    }
}

const jsonFiles = readdirSync(performanceDirectory).filter((name) => name.endsWith(".json"))
const artifacts = jsonFiles.map((name) => ({ name, data: JSON.parse(readFileSync(join(performanceDirectory, name), "utf8")) }))
const results = {}

for (const [mode, workloads] of Object.entries(labels)) {
    results[mode] = {}
    for (const [workload, label] of Object.entries(workloads)) {
        const artifact = artifacts.find((candidate) => candidate.data.label === label)
        if (!artifact) throw new Error(`Missing performance artifact for '${label}'.`)

        const csvPath = join(performanceDirectory, artifact.name.replace(/\.json$/, ".csv"))
        if (!existsSync(csvPath)) throw new Error(`Missing raw CSV for '${label}'.`)
        results[mode][workload] = summarizeCSV(csvPath)
    }
}

const jsonPath = join(performanceDirectory, `comparison-${run}.json`)
const markdownPath = join(performanceDirectory, `comparison-${run}.md`)
writeFileSync(jsonPath, JSON.stringify({ run, generatedAt: new Date().toISOString(), results }, null, 2))
writeFileSync(markdownPath, toMarkdown(run, results))
console.log(markdownPath)

function summarizeCSV(path) {
    const [headerLine, ...lines] = readFileSync(path, "utf8").trim().split("\n")
    const headers = headerLine.split(",")
    const rows = lines.map((line) => Object.fromEntries(line.split(",").map((value, index) => [headers[index], index === 0 ? value : Number(value)])))
    const combinedCpu = rows.map((row) => row.freeshow_cpu_percent + row.scrim_cpu_percent)
    const displayStackCpu = rows.map((row) => row.freeshow_cpu_percent + row.scrim_cpu_percent + row.windowserver_cpu_percent)
    const combinedRss = rows.map((row) => row.freeshow_rss_mb + row.scrim_rss_mb)
    return {
        sampleCount: rows.length,
        combinedCpu: statistics(combinedCpu),
        displayStackCpu: statistics(displayStackCpu),
        combinedRssMB: { ...statistics(combinedRss), delta: combinedRss.at(-1) - combinedRss[0] },
        windowServerCpu: statistics(rows.map((row) => row.windowserver_cpu_percent)),
        freeShowCpu: statistics(rows.map((row) => row.freeshow_cpu_percent)),
        scrimCpu: statistics(rows.map((row) => row.scrim_cpu_percent))
    }
}

function statistics(values) {
    const sorted = [...values].sort((left, right) => left - right)
    return {
        median: percentile(sorted, 0.5),
        p95: percentile(sorted, 0.95),
        max: sorted.at(-1)
    }
}

function percentile(sortedValues, value) {
    return sortedValues[Math.max(0, Math.ceil(sortedValues.length * value) - 1)]
}

function toMarkdown(currentRun, allResults) {
    const workloadNames = { still: "Still image", video: "Looping video", takes: "Active takes" }
    const modeNames = { "electron-only": "Electron-only", dual: "Dual", "scrim-only": "Scrim-only" }
    const rows = []
    for (const workload of ["still", "video", "takes"]) {
        for (const mode of ["electron-only", "dual", "scrim-only"]) {
            const result = allResults[mode][workload]
            rows.push(
                `| ${workloadNames[workload]} | ${modeNames[mode]} | ${format(result.combinedCpu.median)}% | ${format(result.combinedCpu.p95)}% | ${format(result.windowServerCpu.median)}% | ${format(result.displayStackCpu.median)}% | ${format(result.displayStackCpu.p95)}% | ${format(result.combinedRssMB.median)} MB | ${signed(result.combinedRssMB.delta)} MB |`
            )
        }
    }

    return `# Scrim renderer comparison: ${currentRun}

Combined values include the complete FreeShow process tree plus Scrim when it is running.

| Workload | Mode | App CPU median | App CPU P95 | WindowServer median | App + WindowServer median | App + WindowServer P95 | Combined RSS median | RSS end − start |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
${rows.join("\n")}
`
}

function format(value) {
    return Number(value.toFixed(1)).toLocaleString("en-US")
}

function signed(value) {
    return `${value >= 0 ? "+" : ""}${format(value)}`
}
