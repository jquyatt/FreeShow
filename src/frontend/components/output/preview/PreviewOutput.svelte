<script lang="ts">
    import { onDestroy, onMount } from "svelte"
    import { connections, livePrepare, outputs, styles } from "../../../stores"
    import Icon from "../../helpers/Icon.svelte"
    //import { currentWindow, outputs, styles } from "../../../stores"
    import { getResolution } from "../../helpers/output"
    import { getStyleResolution } from "../../slide/getStyleResolution"
    import StageLayout from "../../stage/StageLayout.svelte"
    import Output from "../Output.svelte"
    import { acknowledgeScrimPreviewFrame, initScrimPreviewReceiver, scrimPreviewFrames, setScrimPreviewDemand } from "../scrim/scrimPreview"

    export let fullscreen = false
    export let disableTransitions = false
    export let disabled = false
    export let outputId = ""
    export let style = ""

    $: sceneStyleId = $outputs[outputId]?.out?.scene?.style

    $: resolution = getResolution(null, [$outputs, $styles], false, outputId, sceneStyleId)
    let width = 0
    let height = 0

    $: stageOutput = $outputs[outputId]?.stageOutput
    $: scrimEnabled = !!$outputs[outputId]?.scrim && !stageOutput
    $: scrimOnly = scrimEnabled && !!$outputs[outputId]?.scrimOnly
    $: scrimConnected = Object.values($connections.SCRIM || {}).some((connection) => connection.active === outputId)
    $: nativeFrame = $scrimPreviewFrames[outputId]
    $: useNativePreview = scrimEnabled && scrimConnected && !!nativeFrame
    $: nativeFrameUrl = nativeFrame ? `data:${nativeFrame.mimeType};base64,${nativeFrame.base64}` : ""

    let mounted = false
    let subscribedOutputId = ""

    onMount(() => {
        mounted = true
        initScrimPreviewReceiver()
        syncNativePreviewSubscription()
    })

    onDestroy(() => {
        if (subscribedOutputId) setScrimPreviewDemand(subscribedOutputId, false)
    })

    $: if (mounted) syncNativePreviewSubscription()

    function syncNativePreviewSubscription() {
        const nextOutputId = scrimEnabled ? outputId : ""
        if (nextOutputId === subscribedOutputId) return
        if (subscribedOutputId) setScrimPreviewDemand(subscribedOutputId, false)
        subscribedOutputId = nextOutputId
        if (subscribedOutputId) setScrimPreviewDemand(subscribedOutputId, true)
    }

    function acknowledgeNativeFrame() {
        if (nativeFrame) acknowledgeScrimPreviewFrame(outputId, nativeFrame.frameId, nativeFrame.socketId)
    }
</script>

<!-- class:fullscreen={fullscreen && !stageOutput} -->
<div class="center previewOutput" id={outputId} class:disabled style={style + ("; aspect-ratio: " + resolution.width + "/" + resolution.height + ";")} bind:offsetWidth={width} bind:offsetHeight={height}>
    {#if stageOutput}
        <StageLayout {outputId} stageId={stageOutput} preview={!disableTransitions} edit={false} />
    {:else if useNativePreview}
        {#if nativeFrameUrl}
            <img class="nativePreview" src={nativeFrameUrl} alt="" on:load={acknowledgeNativeFrame} on:error={acknowledgeNativeFrame} />
        {/if}
    {:else}
        <Output {outputId} style={getStyleResolution(resolution, fullscreen ? width : resolution.width, fullscreen ? height : resolution.height, "fit")} mirror preview={!disableTransitions} />
    {/if}

    {#if scrimOnly}
        <div class="scrimMeasurementHost" aria-hidden="true" style="width: {resolution.width}px; height: {resolution.height}px;">
            <Output {outputId} style={getStyleResolution(resolution, resolution.width, resolution.height, "fit")} measurementOnly />
        </div>
    {/if}

    {#if !fullscreen && $livePrepare[outputId]}
        <div class="blackOverlay">
            <Icon id="hide" size={2.5} white />
        </div>
    {/if}
</div>

<style>
    .center {
        display: flex;
        align-items: center;
        justify-content: center;

        height: 100%;
        width: 100%;

        /* max-height: 50vh; */
    }
    /* .center.fullscreen {
        width: 100%;
        height: 100%;
    } */

    .center.disabled {
        opacity: 0.4;
    }

    .previewOutput :global(.main) {
        width: 100%;

        /* disable e.g. YouTube video controls on hover */
        pointer-events: none;
    }

    .nativePreview {
        display: block;
        width: 100%;
        height: 100%;
        object-fit: contain;
        background: black;
        pointer-events: none;
    }

    .scrimMeasurementHost {
        position: fixed;
        top: -100000px;
        left: -100000px;
        overflow: hidden;
        visibility: hidden;
        pointer-events: none;
        contain: strict;
    }

    .blackOverlay {
        position: absolute;
        width: 100%;
        height: 100%;

        display: flex;
        align-items: center;
        justify-content: center;

        background-color: black;
        opacity: 0.3;
    }
</style>
