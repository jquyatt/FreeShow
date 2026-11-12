import { describe, expect, it } from "vitest"
import { usesScrimOnlyRenderer } from "../../../../types/Output"

describe("Scrim output mode", () => {
    it("suppresses only a normal output explicitly configured for Scrim-only rendering", () => {
        expect(usesScrimOnlyRenderer({ scrim: true, scrimOnly: true })).toBe(true)
        expect(usesScrimOnlyRenderer({ scrim: true, scrimOnly: false })).toBe(false)
        expect(usesScrimOnlyRenderer({ scrim: false, scrimOnly: true })).toBe(false)
        expect(usesScrimOnlyRenderer({ scrim: true, scrimOnly: true, stageOutput: "confidence" })).toBe(false)
    })
})
