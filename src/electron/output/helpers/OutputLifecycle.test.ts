import { beforeEach, describe, expect, it, vi } from "vitest"

const mocks = vi.hoisted(() => ({
    getOutput: vi.fn(),
    toApp: vi.fn(),
    toggleOutput: vi.fn()
}))

vi.mock("electron", () => ({ BrowserWindow: vi.fn(), screen: { on: vi.fn() } }))
vi.mock("../..", () => ({ OUTPUT_CONSOLE: false, getMainWindow: vi.fn(), isMac: false, loadWindowContent: vi.fn(), toApp: mocks.toApp }))
vi.mock("../../blackmagic/BlackmagicSender", () => ({ BlackmagicSender: { stop: vi.fn() } }))
vi.mock("../../blackmagic/bmdTalk", () => ({ initializeSender: vi.fn() }))
vi.mock("../../capture/CaptureHelper", () => ({ CaptureHelper: { Lifecycle: { startCapture: vi.fn(), stopCapture: vi.fn() } } }))
vi.mock("../../ndi/NdiSender", () => ({ NdiSender: { createSenderNDI: vi.fn(), initNameNDI: vi.fn(), stopSenderNDI: vi.fn() } }))
vi.mock("../../ndi/talk", () => ({ setDataNDI: vi.fn() }))
vi.mock("../../omt/OmtSender", () => ({ OmtSender: { OMT: {}, stopSenderOMT: vi.fn() } }))
vi.mock("../../omt/talk", () => ({ setDataOMT: vi.fn() }))
vi.mock("../../utils/gpu", () => ({ gpuStateSettled: Promise.resolve(), gpuCompositingAvailable: vi.fn() }))
vi.mock("../../utils/helpers", () => ({ wait: vi.fn() }))
vi.mock("../../utils/windowOptions", () => ({ outputOptions: {} }))
vi.mock("../OutputHelper", () => ({
    OutputHelper: {
        getOutput: mocks.getOutput,
        Bounds: {},
        setOutput: vi.fn(),
        deleteOutput: vi.fn()
    }
}))
vi.mock("./OutputAlwaysOnTop", () => ({ setOutputAlwaysOnTop: vi.fn() }))
vi.mock("./OutputVisibility", () => ({ OutputVisibility: { toggleOutput: mocks.toggleOutput } }))

import { OutputLifecycle } from "./OutputLifecycle"

describe("OutputLifecycle.setRenderMode", () => {
    beforeEach(() => {
        vi.restoreAllMocks()
        mocks.getOutput.mockReset()
        mocks.toApp.mockReset()
        mocks.toggleOutput.mockReset()
    })

    it("removes the Chromium window without resetting Present when entering Scrim-only", async () => {
        mocks.getOutput.mockReturnValue({ window: {} })
        const removeOutput = vi.spyOn(OutputLifecycle, "removeOutput").mockResolvedValue()

        await OutputLifecycle.setRenderMode({ id: "default", enabled: true, active: true, name: "Output", color: "#fff", bounds: { x: 0, y: 0, width: 1920, height: 1080 }, screen: null, scrim: true, scrimOnly: true, presenting: true })

        expect(removeOutput).toHaveBeenCalledWith("default")
        expect(mocks.toApp).not.toHaveBeenCalled()
    })

    it("recreates and presents Chromium when leaving Scrim-only while Present is on", async () => {
        mocks.getOutput.mockReturnValue(undefined)
        const createOutput = vi.spyOn(OutputLifecycle, "createOutput").mockResolvedValue()
        mocks.toggleOutput.mockReturnValue(true)
        const output = { id: "default", enabled: true, active: true, name: "Output", color: "#fff", bounds: { x: 0, y: 0, width: 1920, height: 1080 }, screen: null, scrim: true, scrimOnly: false, presenting: true }

        await OutputLifecycle.setRenderMode(output)

        expect(createOutput).toHaveBeenCalledWith(output)
        expect(mocks.toggleOutput).toHaveBeenCalledWith(output, true, false)
        expect(mocks.toApp).toHaveBeenCalledWith("OUTPUT", { channel: "OUTPUT_STATE", data: [{ id: "default", active: true }] })
    })
})
