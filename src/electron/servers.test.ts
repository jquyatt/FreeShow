import { existsSync, mkdtempSync, writeFileSync } from "fs"
import { networkInterfaces, tmpdir } from "os"
import { join } from "path"
import { afterAll, beforeAll, describe, expect, it, vi } from "vitest"

const ipcHandlers: Record<string, (e: unknown, msg: unknown) => void> = {}
vi.mock("electron", () => ({ ipcMain: { on: (id: string, fn: (e: unknown, msg: unknown) => void) => (ipcHandlers[id] = fn) } }))
vi.mock("./audio/nowPlaying", () => ({ getNowPlayingMediaPath: vi.fn() }))
vi.mock("./utils/files", () => ({ doesPathExist: existsSync }))
vi.mock("./capture/CaptureHelper", () => ({ CaptureHelper: {} }))
vi.mock("./data/bonjour", () => ({ publishPort: vi.fn(), unpublishPorts: vi.fn() }))
vi.mock("./index", () => ({ toApp: vi.fn() }))
vi.mock("./output/OutputHelper", () => ({ OutputHelper: {} }))

const PORT = 15514
const dir = mkdtempSync(join(tmpdir(), "flywire-"))
const png = join(dir, "a.png")
const txt = join(dir, "secret.txt")
writeFileSync(png, "png")
writeFileSync(txt, "secret")

let closeServers: () => void
beforeAll(async () => {
    const servers = await import("./servers")
    closeServers = servers.closeServers
    // only servers explicitly enabled (disabled === false) are started
    servers.startServers({ ports: { scrim: PORT }, max: 10, disabled: { scrim: false }, data: {} } as never)
    await new Promise((r) => setTimeout(r, 300))
})
afterAll(() => closeServers?.())

const get = (path: string, host = "127.0.0.1") => fetch(`http://${host}:${PORT}${path}`)

describe("SCRIM server", () => {
    it("identifies itself as Flywire", async () => {
        expect(await (await get("/")).json()).toEqual({ name: "Flywire", protocolVersion: 1 })
    })

    it("serves a registered media asset", async () => {
        ipcHandlers.SCRIM({}, { channel: "REGISTER_ASSET", data: { assetId: "asset-00000001", path: png } })
        const res = await get("/assets/asset-00000001")
        expect(res.status).toBe(200)
        expect(await res.text()).toBe("png")
    })

    it("refuses unregistered ids, non-media extensions and relative paths", async () => {
        ipcHandlers.SCRIM({}, { channel: "REGISTER_ASSET", data: { assetId: "asset-00000002", path: txt } })
        ipcHandlers.SCRIM({}, { channel: "REGISTER_ASSET", data: { assetId: "asset-00000003", path: "relative/a.png" } })
        expect((await get("/assets/asset-ffffffff")).status).toBe(404)
        expect((await get("/assets/asset-00000002")).status).toBe(404)
        expect((await get("/assets/asset-00000003")).status).toBe(404)
    })

    it("listens on loopback only", async () => {
        const lan = Object.values(networkInterfaces())
            .flat()
            .find((i) => i && i.family === "IPv4" && !i.internal)
        if (!lan) return // no LAN interface on this machine
        await expect(get("/", lan.address)).rejects.toThrow()
    })
})
