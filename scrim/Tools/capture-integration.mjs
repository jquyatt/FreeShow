// Run from the repository: node scrim/Tools/capture-integration.mjs
// Uses an ephemeral loopback Flywire server and disposable windows, not the user's show.
import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { readFile } from "node:fs/promises"
import { createServer } from "node:http"
import { fileURLToPath } from "node:url"
import { Server } from "socket.io"

const executable = fileURLToPath(new URL("../.build/debug/ScrimMac", import.meta.url))
const template = JSON.parse(await readFile(new URL("../Tests/ScrimCoreTests/Fixtures/autosize-scene.json", import.meta.url), "utf8"))
const children = []
const frames = []
let socket
let subscription
let logs = ""
const server = createServer()
const io = new Server(server)
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
async function until(predicate, description, timeout = 10000) {
    const deadline = Date.now() + timeout
    while (!predicate()) {
        if (Date.now() > deadline) throw new Error(`Timed out: ${description}\n${logs.slice(-6000)}`)
        await sleep(25)
    }
}
function child(args) {
    const process = spawn(executable, args, { stdio: ["ignore", "pipe", "pipe"] })
    children.push(process)
    process.on("error", (error) => { logs += `${error}\n` })
    process.stderr.on("data", (data) => { logs += data })
    return process
}
let revision = 0
function publish(background, transition = "cut", outputId = "capture-test") {
    const message = structuredClone(template)
    message.sequence = ++revision
    message.sentAt = Date.now()
    Object.assign(message.scene, {
        id: `capture-test:${revision}`, outputId, canvas: { width: 640, height: 360 }, items: [],
        background, transition: {
            media: { type: transition, durationMs: transition === "fade" ? 300 : 0, easing: "sine" },
            text: { type: "cut", durationMs: 0, easing: "linear" }
        }
    })
    socket.emit("SCRIM", { channel: "SCENE", data: message })
    return revision
}
const saw = (revision) => frames.some((frame) => frame.revision === revision)
const waitRevision = (revision) => until(() => saw(revision), `preview revision ${revision}`)
function live(target, nativeId, overrides = {}) {
    return { color: "#000000", live: {
        kind: "screenCapture", target, sourceId: `${target === "display" ? "screen" : "window"}:${nativeId}:0`,
        nativeId, fit: "contain", showsCursor: false, muted: true, ...overrides
    } }
}
try {
    io.on("connection", (client) => {
        socket = client
        client.on("SCRIM", (message) => {
            if (message.channel === "SUBSCRIBE") subscription = message.data
            if (message.channel === "PREVIEW_READY") {
                client.emit("SCRIM", { channel: "PREVIEW_DEMAND", data: { outputId: "capture-test", enabled: true, maxWidth: 320, framesPerSecond: 12 } })
            }
            if (message.channel === "PREVIEW_FRAME") {
                frames.push(message.data)
                client.emit("SCRIM", { channel: "PREVIEW_ACK", data: { outputId: "capture-test", frameId: message.data.frameId } })
            }
        })
    })
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve))
    let fixtureOutput = ""
    const fixture = child(["--capture-fixture"])
    fixture.stdout.on("data", (data) => { fixtureOutput += data })
    await until(() => /windowId=(\d+) displayId=(\d+)/.test(fixtureOutput), "fixture identity")
    const [, windowId, displayId] = /windowId=(\d+) displayId=(\d+)/.exec(fixtureOutput).map(Number)
    const scrim = child(["--windowed", "--screen", "0", "--host", `http://127.0.0.1:${server.address().port}`, "--output", "capture-test"])
    scrim.stdout.on("data", (data) => { logs += data })
    await until(() => subscription, "native subscription")
    assert(subscription.capabilities.includes("screenCapture.v1"))
    console.log("PASS capability advertised on subscription")

    const solid = publish({ color: "#00ff00" })
    await waitRevision(solid)
    const capture = publish(live("window", windowId), "fade")
    await waitRevision(capture)
    await until(() => new Set(frames.filter((f) => f.revision === capture).map((f) => f.base64)).size >= 3, "changing native capture preview")
    assert(frames.filter((f) => f.revision === capture).every((f) => f.width === 320 && f.height === 180 && f.mimeType === "image/jpeg"))
    console.log("PASS native window capture → program → changing, acknowledged preview")

    const repeat = publish(live("window", windowId, { fit: "cover", crop: { x: 0.1, y: 0.1, width: 0.8, height: 0.8 } }), "fade")
    await waitRevision(repeat)
    await sleep(350)
    const missing = publish(live("window", 4294967295))
    await until(() => logs.includes(`revision=${missing}`) && logs.includes("unavailable"), "missing capture rejected")
    assert(!saw(missing))
    assert.equal(frames.at(-1).revision, repeat)
    console.log("PASS missing source retains previous live program/preview revision")

    fixture.kill("SIGTERM")
    const countBeforeClose = frames.length
    await until(() => frames.length >= countBeforeClose + 3, "preview continues after source closes")
    assert.equal(frames.at(-1).revision, repeat)
    console.log("PASS source closure retains last frame through preview")

    const display = publish(live("display", displayId), "fade")
    await waitRevision(display)
    await sleep(350)
    const ignored = publish({ color: "#ff0000" }, "cut", "another-output")
    await sleep(150)
    assert(!saw(ignored))
    console.log("PASS display capture and output-ID isolation")

    // Supersede an asynchronous new capture immediately, before it can present.
    const stale = publish(live("window", windowId))
    const cut = publish({ color: "#0000ff" })
    await waitRevision(cut)
    await sleep(500)
    assert(!saw(stale))
    assert.equal(frames.at(-1).revision, cut)
    console.log("PASS stale preparation cannot replace a newer hard cut")
    console.log(`PASS integration (${frames.length} preview frames, ${revision} revisions); no user show was changed`)
} finally {
    for (const process of children) {
        if (process.exitCode === null && process.signalCode === null) process.kill("SIGTERM")
    }
    await new Promise((resolve) => io.close(resolve))
    if (server.listening) await new Promise((resolve) => server.close(resolve))
}
