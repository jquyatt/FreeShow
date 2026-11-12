import type { Output, Outputs } from "../../../../types/Output"

export function isPublishedFlywireOutput(output: Output | undefined) {
    return output?.scrim === true && !output.stageOutput
}

export function getFlywireOutputCatalog(outputs: Outputs) {
    return Object.entries(outputs)
        .filter(([, output]) => isPublishedFlywireOutput(output))
        .map(([id, output]) => ({ id, name: output.name || id }))
}
