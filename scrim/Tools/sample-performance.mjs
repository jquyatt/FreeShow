#!/usr/bin/env node

import { execFileSync } from "node:child_process"
import { mkdirSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const scriptDirectory = dirname(fileURLToPath(import.meta.url))
const defaultOutputDirectory = join(scriptDirectory, "..", "Artifacts", "performance")

const options = parseArguments(process.argv.slice(2))
mkdirSync(options.outputDirectory, { recursive: true })

const startedAt = new Date()
const timestamp = startedAt.toISOString().replaceAll(":", "-").replaceAll(".", "-")
const baseName = `${timestamp}-${safeLabel(options.label)}`
const csvPath = join(options.outputDirectory, `${baseName}.csv`)
const jsonPath = join(options.outputDirectory, `${baseName}.json`)
const markdownPath = join(options.outputDirectory, `${baseName}.md`)
const samples = []
let interrupted = false

process.once("SIGINT", () => {
    interrupted = true
})

console.log(`[performance] sampling '${options.label}' for ${options.durationSeconds}s every ${options.intervalMs}ms`)
console.log(`[performance] keep the intended renderer state and workload unchanged until sampling completes`)

const startMonotonic = performance.now()
while (!interrupted && performance.now() - startMonotonic < options.durationSeconds * 1000) {
    const sample = collectSample(performance.now() - startMonotonic)
    samples.push(sample)

    if (samples.length === 1 && sample.freeShow.processes === 0) {
        throw new Error("Packaged FreeShow process was not found. Start the production benchmark app before sampling.")
    }

    if (samples.length === 1 || samples.length % Math.max(1, Math.round(10000 / options.intervalMs)) === 0) {
        console.log(
            `[performance] ${Math.round(sample.elapsedMs / 1000)}s FreeShow=${sample.freeShow.cpu.toFixed(1)}%/${sample.freeShow.rssMB.toFixed(0)}MB ` +
                `Scrim=${sample.scrim.cpu.toFixed(1)}%/${sample.scrim.rssMB.toFixed(0)}MB WindowServer=${sample.windowServer.cpu.toFixed(1)}%`
        )
    }

    const nextSampleAt = startMonotonic + samples.length * options.intervalMs
    await wait(Math.max(0, nextSampleAt - performance.now()))
}

if (samples.length === 0) throw new Error("No performance samples were collected.")

const summary = buildSummary(samples)
writeFileSync(csvPath, toCSV(samples))
writeFileSync(
    jsonPath,
    JSON.stringify(
        {
            label: options.label,
            startedAt: startedAt.toISOString(),
            completedAt: new Date().toISOString(),
            requestedDurationSeconds: options.durationSeconds,
            intervalMs: options.intervalMs,
            interrupted,
            sampleCount: samples.length,
            summary
        },
        null,
        2
    )
)
writeFileSync(markdownPath, toMarkdown(options, startedAt, samples, summary, interrupted))

console.log(`[performance] complete: ${samples.length} samples`)
console.log(`[performance] summary: ${markdownPath}`)
console.log(`[performance] raw: ${csvPath}`)

function parseArguments(args) {
    const parsed = {
        label: "unlabeled",
        durationSeconds: 60,
        intervalMs: 1000,
        outputDirectory: defaultOutputDirectory
    }

    for (let index = 0; index < args.length; index += 1) {
        const argument = args[index]
        const value = args[index + 1]
        if (argument === "--label" && value) parsed.label = value
        else if (argument === "--duration" && value) parsed.durationSeconds = positiveNumber(value, argument)
        else if (argument === "--interval" && value) parsed.intervalMs = positiveNumber(value, argument)
        else if (argument === "--out" && value) parsed.outputDirectory = value
        else throw new Error(`Unknown or incomplete argument: ${argument}`)
        index += 1
    }

    return parsed
}

function positiveNumber(value, argument) {
    const number = Number(value)
    if (!Number.isFinite(number) || number <= 0) throw new Error(`${argument} must be a positive number.`)
    return number
}

function safeLabel(label) {
    return label.toLowerCase().replaceAll(/[^a-z0-9]+/g, "-").replaceAll(/^-|-$/g, "") || "unlabeled"
}

function collectSample(elapsedMs) {
    const rows = readProcesses()
    const freeShowRoots = new Set(
        rows
            .filter((row) => row.command.includes("/FreeShow.app/Contents/MacOS/FreeShow") && !row.command.includes(" Helper"))
            .map((row) => row.pid)
    )
    const scrimRoots = new Set(rows.filter((row) => /(?:^|\/)ScrimMac(?:\s|$)/.test(row.command)).map((row) => row.pid))
    const freeShowPids = descendantsOf(rows, freeShowRoots)
    const scrimPids = descendantsOf(rows, scrimRoots)
    const windowServerRows = rows.filter((row) => /(?:^|\/)WindowServer(?:\s|$)/.test(row.command))

    return {
        timestamp: new Date().toISOString(),
        elapsedMs: Math.round(elapsedMs),
        freeShow: aggregate(rows.filter((row) => freeShowPids.has(row.pid))),
        scrim: aggregate(rows.filter((row) => scrimPids.has(row.pid))),
        windowServer: aggregate(windowServerRows),
        systemCpu: sum(rows.map((row) => row.cpu))
    }
}

function readProcesses() {
    const output = execFileSync("ps", ["-axo", "pid=,ppid=,pcpu=,rss=,command="], { encoding: "utf8" })
    return output
        .split("\n")
        .map((line) => line.match(/^\s*(\d+)\s+(\d+)\s+([\d.]+)\s+(\d+)\s+(.*)$/))
        .filter(Boolean)
        .map((match) => ({
            pid: Number(match[1]),
            ppid: Number(match[2]),
            cpu: Number(match[3]),
            rssKB: Number(match[4]),
            command: match[5]
        }))
}

function descendantsOf(rows, roots) {
    const descendants = new Set(roots)
    let changed = true
    while (changed) {
        changed = false
        for (const row of rows) {
            if (!descendants.has(row.pid) && descendants.has(row.ppid)) {
                descendants.add(row.pid)
                changed = true
            }
        }
    }
    return descendants
}

function aggregate(rows) {
    return {
        cpu: sum(rows.map((row) => row.cpu)),
        rssMB: sum(rows.map((row) => row.rssKB)) / 1024,
        processes: rows.length
    }
}

function sum(values) {
    return values.reduce((total, value) => total + value, 0)
}

function buildSummary(allSamples) {
    return {
        freeShowCpu: statistics(allSamples.map((sample) => sample.freeShow.cpu)),
        freeShowRssMB: statistics(allSamples.map((sample) => sample.freeShow.rssMB), true),
        freeShowProcesses: statistics(allSamples.map((sample) => sample.freeShow.processes)),
        scrimCpu: statistics(allSamples.map((sample) => sample.scrim.cpu)),
        scrimRssMB: statistics(allSamples.map((sample) => sample.scrim.rssMB), true),
        scrimProcesses: statistics(allSamples.map((sample) => sample.scrim.processes)),
        windowServerCpu: statistics(allSamples.map((sample) => sample.windowServer.cpu)),
        windowServerRssMB: statistics(allSamples.map((sample) => sample.windowServer.rssMB), true),
        systemCpu: statistics(allSamples.map((sample) => sample.systemCpu))
    }
}

function statistics(values, includeDelta = false) {
    const sorted = [...values].sort((left, right) => left - right)
    const result = {
        median: percentile(sorted, 0.5),
        p95: percentile(sorted, 0.95),
        max: sorted.at(-1)
    }
    if (includeDelta) result.delta = values.at(-1) - values[0]
    return result
}

function percentile(sortedValues, percentileValue) {
    const index = Math.max(0, Math.ceil(sortedValues.length * percentileValue) - 1)
    return sortedValues[index]
}

function toCSV(allSamples) {
    const header = [
        "timestamp",
        "elapsed_ms",
        "freeshow_cpu_percent",
        "freeshow_rss_mb",
        "freeshow_processes",
        "scrim_cpu_percent",
        "scrim_rss_mb",
        "scrim_processes",
        "windowserver_cpu_percent",
        "windowserver_rss_mb",
        "system_cpu_percent"
    ]
    const lines = allSamples.map((sample) =>
        [
            sample.timestamp,
            sample.elapsedMs,
            sample.freeShow.cpu,
            sample.freeShow.rssMB,
            sample.freeShow.processes,
            sample.scrim.cpu,
            sample.scrim.rssMB,
            sample.scrim.processes,
            sample.windowServer.cpu,
            sample.windowServer.rssMB,
            sample.systemCpu
        ].join(",")
    )
    return `${header.join(",")}\n${lines.join("\n")}\n`
}

function toMarkdown(currentOptions, currentStartedAt, allSamples, summary, wasInterrupted) {
    const row = (name, stats, unit, delta = false) =>
        `| ${name} | ${format(stats.median)}${unit} | ${format(stats.p95)}${unit} | ${format(stats.max)}${unit} | ${delta ? `${format(stats.delta)}${unit}` : "—"} |`

    return `# Performance sample: ${currentOptions.label}

- Started: ${currentStartedAt.toISOString()}
- Samples: ${allSamples.length} at ${currentOptions.intervalMs} ms
- Duration: ${format(allSamples.at(-1).elapsedMs / 1000)} seconds
- Interrupted: ${wasInterrupted ? "yes" : "no"}

| Metric | Median | P95 | Maximum | End − start |
| --- | ---: | ---: | ---: | ---: |
${row("FreeShow CPU", summary.freeShowCpu, "%")}
${row("FreeShow resident memory", summary.freeShowRssMB, " MB", true)}
${row("FreeShow process count", summary.freeShowProcesses, "")}
${row("Scrim CPU", summary.scrimCpu, "%")}
${row("Scrim resident memory", summary.scrimRssMB, " MB", true)}
${row("Scrim process count", summary.scrimProcesses, "")}
${row("WindowServer CPU", summary.windowServerCpu, "%")}
${row("WindowServer resident memory", summary.windowServerRssMB, " MB", true)}
${row("System aggregate CPU", summary.systemCpu, "%")}
`
}

function format(value) {
    return Number(value.toFixed(1)).toLocaleString("en-US")
}

function wait(milliseconds) {
    return new Promise((resolve) => setTimeout(resolve, milliseconds))
}
