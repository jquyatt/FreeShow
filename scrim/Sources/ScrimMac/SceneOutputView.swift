import AppKit
import AVFoundation
import CoreImage
import ImageIO
import QuartzCore
import ScrimCore
import UniformTypeIdentifiers

struct ScrimPreviewDemand: Equatable, Sendable {
    let enabled: Bool
    let maxWidth: Int
    let framesPerSecond: Double
}

struct ScrimPreviewFrame: Sendable {
    let outputId: String
    let revision: Int
    let frameId: Int
    let width: Int
    let height: Int
    let jpegBase64: String
}

private struct PreviewSceneLayer: @unchecked Sendable {
    let scene: PreparedScene
    let dynamicFrame: CGImage?
    let mediaAlpha: CGFloat
    let textAlpha: CGFloat
}

private struct PreviewSnapshot: @unchecked Sendable {
    let outputId: String
    let revision: Int
    let frameId: Int
    let width: Int
    let height: Int
    let dynamic: Bool
    let layers: [PreviewSceneLayer]
}

private final class NotificationObserver: @unchecked Sendable {
    let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

@MainActor
private final class NativeVideoPlayback {
    let assetId: String
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var loopObserver: NotificationObserver?
    private var loopEnabled: Bool
    private var clearOnEnd = true
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var lastFrame: CGImage?
    private var loggedFirstFrame = false
    private var lastPlaybackState: FlywireVideoPlaybackState?

    init?(asset: FlywireAssetRef, baseURL: URL, initialFrame: CGImage) {
        guard let url = URL(string: asset.url, relativeTo: baseURL)?.absoluteURL else { return nil }
        assetId = asset.assetId
        lastFrame = initialFrame
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        let item = AVPlayerItem(url: url)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        self.player = player
        loopEnabled = asset.loop ?? false
        loopObserver = NotificationObserver(
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.loopEnabled {
                        print("[Scrim] video ended asset=\(self.assetId) action=loop")
                        self.player.seek(to: .zero)
                        self.player.play()
                    } else if self.clearOnEnd {
                        print("[Scrim] video ended asset=\(self.assetId) action=clear")
                        self.lastFrame = nil
                    } else {
                        print("[Scrim] video ended asset=\(self.assetId) action=hold")
                    }
                }
            }
        )
        // FreeShow owns program audio. Scrim must never create a second audible
        // path, regardless of the media metadata carried for other consumers.
        player.isMuted = true
        player.actionAtItemEnd = .pause
        player.play()
    }

    func frame(at hostTime: CFTimeInterval) -> CGImage? {
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return lastFrame }
        let image = CIImage(cvPixelBuffer: buffer)
        if let frame = imageContext.createCGImage(image, from: image.extent) {
            lastFrame = frame
            if !loggedFirstFrame {
                loggedFirstFrame = true
                print("[Scrim] video ready asset=\(assetId) size=\(frame.width)x\(frame.height)")
            }
        }
        return lastFrame
    }

    func synchronize(to state: FlywireVideoPlaybackState) {
        guard state.assetId == assetId, state.sentAt >= (lastPlaybackState?.sentAt ?? -.greatestFiniteMagnitude) else { return }

        let previous = lastPlaybackState
        let target = state.targetPosition(at: Date().timeIntervalSince1970 * 1_000)
        let current = player.currentTime().seconds
        let drift = current.isFinite ? current - target : .greatestFiniteMagnitude
        let explicitSeek = state.isExplicitSeek(from: previous)
        let pauseChanged = previous?.paused != state.paused
        let seekThreshold = state.paused ? 0.05 : 0.3 * state.playbackRate
        let shouldSeek = explicitSeek || !current.isFinite || abs(drift) > seekThreshold
        lastPlaybackState = state
        loopEnabled = state.loop
        clearOnEnd = state.clearOnEnd

        if state.paused { player.pause() }
        if shouldSeek {
            player.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }

        if !state.paused {
            let baseRate = min(16, max(0.1, state.playbackRate))
            let correction = shouldSeek || abs(drift) <= 0.02 ? 0 : min(0.1 * baseRate, max(-0.1 * baseRate, -drift * 2 * baseRate))
            player.playImmediately(atRate: Float(min(16, max(0.1, baseRate + correction))))
        }

        if explicitSeek || pauseChanged {
            let driftMs = current.isFinite ? Int((drift * 1_000).rounded()) : 0
            let formattedTime = String(format: "%.3f", target)
            print("[Scrim] playback sync asset=\(assetId) time=\(formattedTime) paused=\(state.paused) loop=\(state.loop) clearOnEnd=\(state.clearOnEnd) driftMs=\(driftMs)")
        }
    }

    var currentFrame: CGImage? { lastFrame }
}

final class SceneOutputView: NSView, @unchecked Sendable {
    var onPreviewFrame: ((ScrimPreviewFrame) -> Void)?

    private let renderer = SceneRenderer()
    private let compositor = SceneCompositor()
    private let previewQueue = DispatchQueue(label: "app.freeshow.scrim.preview", qos: .utility)
    private var displayID: CGDirectDisplayID?
    private let baseURL: URL
    private let liveSources: LiveSourceManager
    private var presentedLiveScenes: [String: String] = [:]
    private var pendingRevision: Int?
    private var presentedRevision = 0
    private var videoPlaybacks: [String: NativeVideoPlayback] = [:]
    private var playbackStates: [String: FlywireVideoPlaybackState] = [:]
    private var previewDemand = ScrimPreviewDemand(enabled: false, maxWidth: 640, framesPerSecond: 12)
    private var previewEncoding = false
    private var previewAwaitingFrameId: Int?
    private var previewFrameId = 0
    private var lastPreviewRevision = 0
    private var lastPreviewWasDynamic = false
    private var lastPreviewStartedAt: CFTimeInterval = 0
    private var previewAckDeadline: CFTimeInterval = 0
    private var displayLink: DisplayLinkDriver?

    override var isFlipped: Bool { true }

    init(frame frameRect: NSRect, baseURL: URL, liveSources: LiveSourceManager) {
        self.baseURL = baseURL
        self.liveSources = liveSources
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    func setDisplay(_ displayID: CGDirectDisplayID?) {
        guard self.displayID != displayID else { return }
        displayLink?.stop()
        self.displayID = displayID
        displayLink = displayID.map { id in
            DisplayLinkDriver(displayID: id) { [weak self] in
                DispatchQueue.main.async { self?.needsDisplay = true }
            }
        }
        displayLink?.start()
        if displayID != nil { needsDisplay = true }
    }

    required init?(coder: NSCoder) { nil }

    func setPreviewDemand(_ demand: ScrimPreviewDemand) {
        let normalized = ScrimPreviewDemand(
            enabled: demand.enabled,
            maxWidth: min(1280, max(160, demand.maxWidth)),
            framesPerSecond: min(15, max(1, demand.framesPerSecond))
        )
        guard normalized != previewDemand else { return }
        previewDemand = normalized
        previewAwaitingFrameId = nil
        lastPreviewRevision = 0
        lastPreviewWasDynamic = false
        if normalized.enabled { needsDisplay = true }
        print("[Scrim] preview output=\(compositor.incoming?.scene.outputId ?? "pending") enabled=\(normalized.enabled) maxWidth=\(normalized.maxWidth) fps=\(Int(normalized.framesPerSecond))")
    }

    func acknowledgePreviewFrame(_ frameId: Int) {
        guard previewAwaitingFrameId == frameId else { return }
        previewAwaitingFrameId = nil
        if previewDemand.enabled { needsDisplay = true }
    }

    func applyPlaybackState(_ state: FlywireVideoPlaybackState) {
        playbackStates[state.sceneId] = state
        guard let playback = videoPlaybacks[state.sceneId], playback.assetId == state.assetId else { return }
        playback.synchronize(to: state)
        needsDisplay = true
    }

    func receive(revision: Int, scene: FlywireScene, assets: [String: CGImage], liveLeaseId: String? = nil) {
        guard let mediaImage = renderer.render(scene: scene, assets: assets, includeBackground: true, includeText: false),
              let textImage = renderer.render(scene: scene, includeBackground: false, includeText: true)
        else {
            if let liveLeaseId { liveSources.release(sceneId: liveLeaseId) }
            fputs("[Scrim] decode/preparation failure output=\(scene.outputId) revision=\(revision) scene=\(scene.id): renderer returned no layer image\n", stderr)
            return
        }
        if scene.background.live != nil {
            guard let liveLeaseId, liveSources.frame(sceneId: liveLeaseId) != nil else {
                if let liveLeaseId { liveSources.release(sceneId: liveLeaseId) }
                print("[Scrim] preparation failure output=\(scene.outputId) revision=\(revision) action=retain-current reason=missing live first frame")
                return
            }
            if let previous = presentedLiveScenes[scene.id], previous != liveLeaseId { liveSources.release(sceneId: previous) }
            presentedLiveScenes[scene.id] = liveLeaseId
        }
        if let video = scene.background.video {
            guard let initialFrame = assets[video.assetId] else {
                fputs("[Scrim] decode/preparation failure output=\(scene.outputId) revision=\(revision) scene=\(scene.id) asset=\(video.assetId) action=retain-current reason=missing prepared video frame\n", stderr)
                return
            }
            guard let playback = NativeVideoPlayback(asset: video, baseURL: baseURL, initialFrame: initialFrame) else {
                fputs("[Scrim] decode/preparation failure output=\(scene.outputId) revision=\(revision) scene=\(scene.id) asset=\(video.assetId) action=retain-current reason=invalid video URL \(video.url)\n", stderr)
                return
            }
            videoPlaybacks[scene.id] = playback
            if let state = playbackStates[scene.id], state.assetId == video.assetId {
                playback.synchronize(to: state)
            }
            print("[Scrim] prepared video output=\(scene.outputId) revision=\(revision) asset=\(video.assetId) muted=true loop=\(video.loop ?? true)")
        }
        compositor.prepare(PreparedScene(scene: scene, mediaImage: mediaImage, textImage: textImage), at: CACurrentMediaTime())
        let retainedSceneIds = Set([compositor.outgoing?.scene.id, compositor.incoming?.scene.id].compactMap { $0 })
        videoPlaybacks = videoPlaybacks.filter { retainedSceneIds.contains($0.key) }
        releaseRetiredCaptures(retaining: retainedSceneIds)
        playbackStates = playbackStates.filter { retainedSceneIds.contains($0.key) }
        pendingRevision = revision
        needsDisplay = true
        if !scene.unsupported.isEmpty {
            let details = scene.unsupported.map(\.reason).joined(separator: " | ")
            fputs("Scrim unsupported content: \(details)\n", stderr)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // Scene images have a top-left content convention; compensate for AppKit's flipped view.
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let frameTime = CACurrentMediaTime()
        compositor.draw(in: context, bounds: bounds, at: frameTime) { [weak self] scene, context, bounds, mediaAlpha, textAlpha in
            self?.draw(scene: scene, in: context, bounds: bounds, mediaAlpha: mediaAlpha, textAlpha: textAlpha, at: frameTime)
        }
        let retainedSceneIds = Set([compositor.outgoing?.scene.id, compositor.incoming?.scene.id].compactMap { $0 })
        videoPlaybacks = videoPlaybacks.filter { retainedSceneIds.contains($0.key) }
        releaseRetiredCaptures(retaining: retainedSceneIds)
        context.restoreGState()
        if let revision = pendingRevision, let scene = compositor.incoming?.scene {
            print("[Scrim] presented revision=\(revision) output=\(scene.outputId) scene=\(scene.id)")
            presentedRevision = revision
            pendingRevision = nil
        }
        schedulePreview(at: frameTime)
    }

    private func draw(scene: PreparedScene, in context: CGContext, bounds: CGRect, mediaAlpha: CGFloat, textAlpha: CGFloat, at time: CFTimeInterval) {
        if mediaAlpha > 0 {
            let frame = scene.scene.background.live != nil ? dynamicFrame(for: scene) : videoPlaybacks[scene.scene.id]?.frame(at: time)
            SceneMediaDrawing.draw(background: scene.mediaImage, frame: frame, live: scene.scene.background.live,
                                   in: bounds, alpha: mediaAlpha, context: context)
        }
        if textAlpha > 0, let textImage = scene.textImage {
            context.saveGState()
            context.setAlpha(textAlpha)
            context.draw(textImage, in: bounds)
            context.restoreGState()
        }
    }

    private func releaseRetiredCaptures(retaining sceneIds: Set<String>) {
        for (sceneId, leaseId) in presentedLiveScenes where !sceneIds.contains(sceneId) { liveSources.release(sceneId: leaseId) }
        presentedLiveScenes = presentedLiveScenes.filter { sceneIds.contains($0.key) }
    }

    private func dynamicFrame(for scene: PreparedScene) -> CGImage? {
        scene.scene.background.live != nil ? presentedLiveScenes[scene.scene.id].flatMap { liveSources.frame(sceneId: $0) } : videoPlaybacks[scene.scene.id]?.currentFrame
    }

    private func schedulePreview(at time: CFTimeInterval) {
        guard previewDemand.enabled, presentedRevision > 0, let incoming = compositor.incoming else { return }
        guard !previewEncoding else { return }
        if previewAwaitingFrameId != nil {
            guard time >= previewAckDeadline else { return }
            previewAwaitingFrameId = nil
        }

        let transitionActive = compositor.isTransitionActive(at: time)
        let videoActive = videoPlaybacks[incoming.scene.id] != nil || compositor.outgoing.map { videoPlaybacks[$0.scene.id] != nil } ?? false
        let dynamic = transitionActive || videoActive || !presentedLiveScenes.isEmpty
        let revisionChanged = presentedRevision != lastPreviewRevision
        let dynamicEnded = lastPreviewWasDynamic && !dynamic
        let minimumInterval = 1 / previewDemand.framesPerSecond
        guard revisionChanged || dynamicEnded || (dynamic && time - lastPreviewStartedAt >= minimumInterval) else { return }

        let canvas = incoming.scene.canvas
        guard canvas.width > 0, canvas.height > 0 else { return }
        let width = min(previewDemand.maxWidth, max(1, Int(canvas.width.rounded())))
        let height = max(1, Int((Double(width) * canvas.height / canvas.width).rounded()))
        let progress = compositor.layerProgress(at: time)
        var layers: [PreviewSceneLayer] = []
        if let outgoing = compositor.outgoing, !progress.isComplete {
            let textIsPersistent = outgoing.scene.items == incoming.scene.items
            layers.append(PreviewSceneLayer(
                scene: outgoing,
                dynamicFrame: dynamicFrame(for: outgoing),
                mediaAlpha: incoming.scene.transition.media.type == "fade" ? 1 : 0,
                textAlpha: textIsPersistent ? 1 : incoming.scene.transition.text.type == "fade" ? CGFloat(1 - progress.text) : 0
            ))
            layers.append(PreviewSceneLayer(
                scene: incoming,
                dynamicFrame: dynamicFrame(for: incoming),
                mediaAlpha: CGFloat(progress.media),
                textAlpha: textIsPersistent ? 0 : CGFloat(progress.text)
            ))
        } else {
            layers.append(PreviewSceneLayer(
                scene: incoming,
                dynamicFrame: dynamicFrame(for: incoming),
                mediaAlpha: 1,
                textAlpha: 1
            ))
        }

        previewFrameId += 1
        let snapshot = PreviewSnapshot(
            outputId: incoming.scene.outputId,
            revision: presentedRevision,
            frameId: previewFrameId,
            width: width,
            height: height,
            dynamic: dynamic,
            layers: layers
        )
        previewEncoding = true
        lastPreviewStartedAt = time

        previewQueue.async { [weak self] in
            let frame = Self.encodePreview(snapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                self.previewEncoding = false
                guard self.previewDemand.enabled, let frame, frame.revision == self.presentedRevision else {
                    self.needsDisplay = true
                    return
                }
                self.lastPreviewRevision = frame.revision
                self.lastPreviewWasDynamic = snapshot.dynamic
                self.previewAwaitingFrameId = frame.frameId
                self.previewAckDeadline = CACurrentMediaTime() + 2
                self.onPreviewFrame?(frame)
            }
        }
    }

    private nonisolated static func encodePreview(_ snapshot: PreviewSnapshot) -> ScrimPreviewFrame? {
        guard let context = CGContext(
            data: nil,
            width: snapshot.width,
            height: snapshot.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(bounds)
        // Prepared scene images are already encoded in display orientation. Unlike
        // the flipped AppKit output view, this offscreen bitmap needs no Y transform.
        for layer in snapshot.layers where layer.mediaAlpha > 0 { drawPreviewMedia(layer, in: context, bounds: bounds) }
        for layer in snapshot.layers where layer.textAlpha > 0 { drawPreviewText(layer, in: context, bounds: bounds) }
        guard let image = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return ScrimPreviewFrame(
            outputId: snapshot.outputId,
            revision: snapshot.revision,
            frameId: snapshot.frameId,
            width: snapshot.width,
            height: snapshot.height,
            jpegBase64: (data as Data).base64EncodedString()
        )
    }

    private nonisolated static func drawPreviewMedia(_ layer: PreviewSceneLayer, in context: CGContext, bounds: CGRect) {
        SceneMediaDrawing.draw(background: layer.scene.mediaImage, frame: layer.dynamicFrame,
                               live: layer.scene.scene.background.live, in: bounds,
                               alpha: layer.mediaAlpha, context: context)
    }

    private nonisolated static func drawPreviewText(_ layer: PreviewSceneLayer, in context: CGContext, bounds: CGRect) {
        guard let textImage = layer.scene.textImage else { return }
        context.saveGState()
        context.setAlpha(layer.textAlpha)
        context.draw(textImage, in: bounds)
        context.restoreGState()
    }

}
