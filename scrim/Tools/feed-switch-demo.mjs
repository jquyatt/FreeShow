// Disposable loopback-only fixture. Does not open or modify any FreeShow show.
import { readFile } from "node:fs/promises"
import { createServer } from "node:http"
import { Server } from "socket.io"

const template = JSON.parse(await readFile(new URL("../Tests/ScrimCoreTests/Fixtures/autosize-scene.json", import.meta.url), "utf8"))
const outputs = [
    { id: "default", name: "Demo A · Blue", color: "#1846C9", delay: 0 },
    { id: "demo-b", name: "Demo B · Orange (2 s delay)", color: "#ED6418", delay: 2000 },
    { id: "demo-timeout", name: "Demo C · No scene" }
]
const http = createServer()
const io = new Server(http)
let sequence = 0
io.on("connection", (socket) => {
    let timer
    socket.on("SCRIM", ({ channel, data }) => {
        if (channel === "LIST_OUTPUTS") {
            socket.emit("SCRIM", { channel: "OUTPUT_CATALOG", data: outputs.map(({ id, name }) => ({ id, name })) })
        } else if (channel === "SUBSCRIBE") {
            clearTimeout(timer)
            const output = outputs.find(({ id }) => id === data.outputId)
            if (!output) {
                socket.emit("SCRIM", { channel: "ERROR", data: { code: "OUTPUT_NOT_AVAILABLE", outputId: data.outputId } })
                return
            }
            console.log(`Subscribed: ${output.name}`)
            if (!output.color) return
            timer = setTimeout(() => {
                const message = structuredClone(template)
                message.sequence = ++sequence
                message.sentAt = Date.now()
                Object.assign(message.scene, {
                    id: `${output.id}:${sequence}`, outputId: output.id, canvas: { width: 640, height: 360 },
                    items: [], background: { color: output.color }
                })
                socket.emit("SCRIM", { channel: "SCENE", data: message })
                console.log(`Sent: ${output.name} revision ${sequence}`)
            }, output.delay)
        }
    })
    socket.on("disconnect", () => clearTimeout(timer))
})
http.listen(0, "127.0.0.1", () => {
    console.log(`Demo is ready: --host http://127.0.0.1:${http.address().port} --fullscreen --output default`)
})
