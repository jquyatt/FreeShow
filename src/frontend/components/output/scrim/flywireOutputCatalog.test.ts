import { expect, it } from "vitest"
import type { Output } from "../../../../types/Output"
import { getFlywireOutputCatalog } from "./flywireOutputCatalog"

it("lists named, published program feeds by their subscription IDs", () => {
    const output: Output = { id: "not-the-store-key", enabled: true, active: true, name: "", color: "", bounds: { x: 0, y: 0, width: 640, height: 360 }, screen: null }
    expect(getFlywireOutputCatalog({
        default: { ...output, name: "Main HDMI", scrim: true },
        backup: { ...output, scrim: true },
        stage: { ...output, scrim: true, stageOutput: "stage" },
        local: { ...output, scrim: false }
    })).toEqual([{ id: "default", name: "Main HDMI" }, { id: "backup", name: "backup" }])
})
