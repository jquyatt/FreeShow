import AppKit
import AVFoundation
import Foundation
import ScrimCore
import SocketIO

private struct FlywireAssetPreloadMessage: Decodable {
    let outputId: String
    let assets: [FlywireAssetRef]
}

struct FlywireOutputOption: Decodable, Equatable {
    let id: String
    let name: String
}

private enum FlywireAssetLoadError: Error, CustomStringConvertible {
    case invalidURL(assetId: String, value: String)
    case httpStatus(assetId: String, status: Int)
    case network(assetId: String, reason: String)

    var description: String {
        switch self {
        case let .invalidURL(assetId, value):
            return "invalid asset URL asset=\(assetId) url=\(value)"
        case let .httpStatus(assetId, status):
            return "asset HTTP failure asset=\(assetId) status=\(status)"
        case let .network(assetId, reason):
            return "asset network failure asset=\(assetId) reason=\(reason)"
        }
    }
}

@MainActor
final class FlywireClient {
    private static let assetCacheLimit = 8

    private let baseURL: URL
    private let leaseNamespace = UUID().uuidString
    private let outputId: String
    private let liveSources: LiveSourceManager
    private var pendingLiveScenes: Set<String> = []
    private let manager: SocketManager
    private let socket: SocketIOClient
    private let onScene: (Int, FlywireScene, [String: CGImage], String?) -> Void
    var onPreviewDemand: ((ScrimPreviewDemand) -> Void)?
    var onPreviewAcknowledgement: ((Int) -> Void)?
    var onPlaybackState: ((FlywireVideoPlaybackState) -> Void)?
    var onOutputCatalog: (([FlywireOutputOption]) -> Void)?
    var onSubscriptionError: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    private var previewReady: Bool
    private let subscribes: Bool
    private var sceneEpoch = 0
    private var latestReceivedSequence = 0
    private var assetCache: [String: CGImage] = [:]
    private var assetCacheOrder: [String] = []
    private var assetLoads: [String: Task<CGImage, Error>] = [:]
    private var videoFirstFrameCache: [String: CGImage] = [:]
    private var videoFirstFrameCacheOrder: [String] = []
    private var videoFirstFrameLoads: [String: Task<CGImage, Error>] = [:]

    init(baseURL: URL, outputId: String, liveSources: LiveSourceManager, previewReady: Bool = true, subscribes: Bool = true, onScene: @escaping (Int, FlywireScene, [String: CGImage], String?) -> Void) {
        self.baseURL = baseURL
        self.outputId = outputId
        self.liveSources = liveSources
        self.previewReady = previewReady
        self.subscribes = subscribes
        self.onScene = onScene
        manager = SocketManager(socketURL: baseURL, config: [.compress, .reconnects(true), .log(false)])
        socket = manager.defaultSocket
        installHandlers()
    }

    func connect() { socket.connect() }

    func disconnect() {
        beginSceneEpoch()
        socket.removeAllHandlers()
        manager.disconnect()
    }

    func requestOutputCatalog() {
        if socket.status == .connected { socket.emit("SCRIM", ["channel": "LIST_OUTPUTS"]) }
    }

    func enablePreview() {
        previewReady = true
        if socket.status == .connected {
            socket.emit("SCRIM", ["channel": "PREVIEW_READY", "data": ["outputId": outputId]])
        }
    }

    func sendPreviewFrame(_ frame: ScrimPreviewFrame) {
        guard frame.outputId == outputId else { return }
        socket.emit("SCRIM", [
            "channel": "PREVIEW_FRAME",
            "data": [
                "outputId": frame.outputId,
                "revision": frame.revision,
                "frameId": frame.frameId,
                "width": frame.width,
                "height": frame.height,
                "mimeType": "image/jpeg",
                "base64": frame.jpegBase64,
                "sentAt": Date().timeIntervalSince1970 * 1_000
            ]
        ])
    }

    private func installHandlers() {
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self else { return }
            self.beginSceneEpoch()
            if self.subscribes {
                self.socket.emit("SCRIM", ["channel": "SUBSCRIBE", "data": ["outputId": self.outputId, "capabilities": ["screenCapture.v1"]]])
                if self.previewReady { self.enablePreview() }
                print("[Flywire] connected host=\(self.baseURL.absoluteString) subscription output=\(self.outputId)")
            }
            self.requestOutputCatalog()
        }
        socket.on(clientEvent: .disconnect) { [weak self] _, _ in
            self?.beginSceneEpoch()
            self?.onDisconnect?()
        }
        socket.on(clientEvent: .error) { data, _ in
            fputs("Flywire socket error: \(data)\n", stderr)
        }
        socket.on("SCRIM") { [weak self] data, _ in
            guard let self,
                  let message = data.first as? [String: Any],
                  let channel = message["channel"] as? String else { return }
            if channel == "ERROR" {
                let details = message["data"] as? [String: Any]
                let code = details?["code"] as? String ?? "UNKNOWN"
                let rejectedOutputId = details?["outputId"] as? String ?? self.outputId
                fputs("[Scrim] subscription rejected output=\(rejectedOutputId) code=\(code)\n", stderr)
                self.onSubscriptionError?(code)
                return
            }
            guard let payload = message["data"] else { return }
            if channel == "OUTPUT_CATALOG" {
                if let data = try? JSONSerialization.data(withJSONObject: payload),
                   let catalog = try? JSONDecoder().decode([FlywireOutputOption].self, from: data) {
                    self.onOutputCatalog?(catalog)
                }
            } else if channel == "SCENE" {
                Task { await self.decodeAndPrepare(payload) }
            } else if channel == "PRELOAD_ASSETS" {
                Task { await self.decodeAndPreload(payload) }
            } else if channel == "PLAYBACK" {
                self.decodePlaybackState(payload)
            } else if channel == "PREVIEW_DEMAND",
                      let details = payload as? [String: Any],
                      (details["outputId"] as? String) == self.outputId {
                let enabled = details["enabled"] as? Bool ?? false
                let maxWidth = (details["maxWidth"] as? NSNumber)?.intValue ?? 640
                let framesPerSecond = (details["framesPerSecond"] as? NSNumber)?.doubleValue ?? 12
                self.onPreviewDemand?(ScrimPreviewDemand(enabled: enabled, maxWidth: maxWidth, framesPerSecond: framesPerSecond))
            } else if channel == "PREVIEW_ACK",
                      let details = payload as? [String: Any],
                      (details["outputId"] as? String) == self.outputId,
                      let frameId = (details["frameId"] as? NSNumber)?.intValue {
                self.onPreviewAcknowledgement?(frameId)
            }
        }
    }

    private func decodePlaybackState(_ payload: Any) {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let state = try JSONDecoder().decode(FlywireVideoPlaybackState.self, from: data)
            guard state.outputId == outputId, state.isValid else {
                throw FlywireProtocolError.invalidVideoPlayback(reason: "invalid playback state")
            }
            onPlaybackState?(state)
        } catch {
            fputs("[Scrim] playback decode failure output=\(outputId): \(error)\n", stderr)
        }
    }

    private func decodeAndPrepare(_ payload: Any) async {
        var receivedRevision = "unknown"
        var receivedOutputId = outputId
        var receivedAssetId = "none"
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let envelope = try JSONDecoder().decode(FlywireSceneEnvelope.self, from: data)
            try envelope.validate()
            guard envelope.scene.outputId == outputId else { return }
            receivedRevision = String(envelope.sequence)
            receivedOutputId = envelope.scene.outputId
            receivedAssetId = envelope.scene.background.image?.assetId ?? envelope.scene.background.video?.assetId ?? "none"
            if envelope.sequence == 1, latestReceivedSequence > 1 {
                beginSceneEpoch()
                print("[Flywire] publisher revision sequence restarted output=\(envelope.scene.outputId)")
            }
            let receivedEpoch = sceneEpoch
            guard envelope.sequence > latestReceivedSequence else { return }
            for sceneId in pendingLiveScenes { liveSources.release(sceneId: sceneId) }
            pendingLiveScenes.removeAll()
            latestReceivedSequence = max(latestReceivedSequence, envelope.sequence)
            let wireMs = max(0, Date().timeIntervalSince1970 * 1_000 - envelope.sentAt)
            let mediaTransition = envelope.scene.transition.media
            let textTransition = envelope.scene.transition.text
            print("[Scrim] received scene output=\(envelope.scene.outputId) revision=\(envelope.sequence) scene=\(envelope.scene.id) wireMs=\(Int(wireMs.rounded())) media=\(mediaTransition.type)/\(Int(mediaTransition.durationMs.rounded()))ms/\(mediaTransition.easing) text=\(textTransition.type)/\(Int(textTransition.durationMs.rounded()))ms/\(textTransition.easing)")
            let assets = try await loadAssets(for: envelope.scene, revision: envelope.sequence)
            guard receivedEpoch == sceneEpoch, envelope.sequence == latestReceivedSequence else { return }
            let leaseId = "\(leaseNamespace):\(receivedEpoch):\(envelope.sequence):\(envelope.scene.id)"
            if let live = envelope.scene.background.live {
                // Native desktop identities only address the same machine as FreeShow.
                guard ["localhost", "127.0.0.1", "::1", "[::1]"].contains(baseURL.host ?? "") else {
                    throw FlywireProtocolError.invalidBackground(reason: "screen capture requires a local Flywire connection")
                }
                let sceneId = leaseId
                pendingLiveScenes.insert(sceneId)
                do {
                    try await liveSources.acquire(live, sceneId: sceneId)
                } catch {
                    pendingLiveScenes.remove(sceneId)
                    throw error
                }
                pendingLiveScenes.remove(sceneId)
            }
            guard receivedEpoch == sceneEpoch, envelope.sequence == latestReceivedSequence else {
                liveSources.release(sceneId: leaseId)
                print("[Scrim] discarded superseded scene output=\(envelope.scene.outputId) revision=\(envelope.sequence) latest=\(latestReceivedSequence)")
                return
            }
            onScene(envelope.sequence, envelope.scene, assets, envelope.scene.background.live != nil ? leaseId : nil)
        } catch {
            fputs("[Scrim] decode/preparation failure output=\(receivedOutputId) revision=\(receivedRevision) asset=\(receivedAssetId) action=retain-current reason=\(error)\n", stderr)
        }
    }

    private func beginSceneEpoch() {
        for sceneId in pendingLiveScenes { liveSources.release(sceneId: sceneId) }
        pendingLiveScenes.removeAll()
        sceneEpoch += 1
        latestReceivedSequence = 0
    }

    private func loadAssets(for scene: FlywireScene, revision: Int) async throws -> [String: CGImage] {
        if let asset = scene.background.image {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let (image, cached) = try await loadAsset(asset)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
            print("[Scrim] prepared asset output=\(scene.outputId) revision=\(revision) asset=\(asset.assetId) cached=\(cached) durationMs=\(Int(elapsedMs.rounded()))")
            return [asset.assetId: image]
        }
        if let asset = scene.background.video {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let (firstFrame, cached) = try await loadVideoFirstFrame(asset)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
            print("[Scrim] prepared video first frame output=\(scene.outputId) revision=\(revision) asset=\(asset.assetId) cached=\(cached) durationMs=\(Int(elapsedMs.rounded()))")
            return [asset.assetId: firstFrame]
        }
        return [:]
    }

    private func decodeAndPreload(_ payload: Any) async {
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let message = try JSONDecoder().decode(FlywireAssetPreloadMessage.self, from: data)
            guard message.outputId == outputId else { return }

            // Start the bounded neighbor window together. Each loader de-duplicates
            // against both its cache and any in-flight preparation for that asset.
            let tasks: [Task<Void, Never>] = message.assets.compactMap { asset in
                guard asset.kind == "image" || asset.kind == "video" else { return nil }
                return Task { @MainActor [weak self] in
                    guard let self else { return }
                    let startedAt = CFAbsoluteTimeGetCurrent()
                    do {
                        let cached: Bool
                        if asset.kind == "video" {
                            (_, cached) = try await self.loadVideoFirstFrame(asset)
                        } else {
                            (_, cached) = try await self.loadAsset(asset)
                        }
                        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1_000
                        if !cached {
                            print("[Scrim] prewarmed \(asset.kind) output=\(message.outputId) asset=\(asset.assetId) durationMs=\(Int(elapsedMs.rounded()))")
                        }
                    } catch {
                        fputs("[Scrim] asset prewarm failure output=\(message.outputId) asset=\(asset.assetId) kind=\(asset.kind) reason=\(error)\n", stderr)
                    }
                }
            }
            for task in tasks {
                await task.value
            }
        } catch {
            fputs("[Scrim] asset prewarm failure output=\(outputId): \(error)\n", stderr)
        }
    }

    private func loadAsset(_ asset: FlywireAssetRef) async throws -> (CGImage, Bool) {
        if let image = assetCache[asset.assetId] {
            touchCachedAsset(asset.assetId)
            return (image, true)
        }

        let task: Task<CGImage, Error>
        if let existing = assetLoads[asset.assetId] {
            task = existing
        } else {
            guard let url = URL(string: asset.url, relativeTo: baseURL)?.absoluteURL else {
                throw FlywireAssetLoadError.invalidURL(assetId: asset.assetId, value: asset.url)
            }
            task = Task.detached(priority: .userInitiated) {
                try await Self.fetchAndDecodeImage(from: url, assetId: asset.assetId)
            }
            assetLoads[asset.assetId] = task
        }

        do {
            let image = try await task.value
            assetLoads.removeValue(forKey: asset.assetId)
            storeCachedAsset(image, assetId: asset.assetId)
            return (image, false)
        } catch {
            assetLoads.removeValue(forKey: asset.assetId)
            throw error
        }
    }

    private func touchCachedAsset(_ assetId: String) {
        assetCacheOrder.removeAll { $0 == assetId }
        assetCacheOrder.append(assetId)
    }

    private func storeCachedAsset(_ image: CGImage, assetId: String) {
        assetCache[assetId] = image
        touchCachedAsset(assetId)
        while assetCacheOrder.count > Self.assetCacheLimit {
            assetCache.removeValue(forKey: assetCacheOrder.removeFirst())
        }
    }

    private func loadVideoFirstFrame(_ asset: FlywireAssetRef) async throws -> (CGImage, Bool) {
        if let image = videoFirstFrameCache[asset.assetId] {
            touchCachedVideoFirstFrame(asset.assetId)
            return (image, true)
        }

        let task: Task<CGImage, Error>
        if let existing = videoFirstFrameLoads[asset.assetId] {
            task = existing
        } else {
            guard let url = URL(string: asset.url, relativeTo: baseURL)?.absoluteURL else {
                throw FlywireAssetLoadError.invalidURL(assetId: asset.assetId, value: asset.url)
            }
            task = Task.detached(priority: .userInitiated) {
                try await MediaAssetPreparer.decodeVideoFirstFrame(url: url, assetId: asset.assetId)
            }
            videoFirstFrameLoads[asset.assetId] = task
        }

        do {
            let image = try await task.value
            videoFirstFrameLoads.removeValue(forKey: asset.assetId)
            storeCachedVideoFirstFrame(image, assetId: asset.assetId)
            return (image, false)
        } catch {
            videoFirstFrameLoads.removeValue(forKey: asset.assetId)
            throw error
        }
    }

    private func touchCachedVideoFirstFrame(_ assetId: String) {
        videoFirstFrameCacheOrder.removeAll { $0 == assetId }
        videoFirstFrameCacheOrder.append(assetId)
    }

    private func storeCachedVideoFirstFrame(_ image: CGImage, assetId: String) {
        videoFirstFrameCache[assetId] = image
        touchCachedVideoFirstFrame(assetId)
        while videoFirstFrameCacheOrder.count > Self.assetCacheLimit {
            videoFirstFrameCache.removeValue(forKey: videoFirstFrameCacheOrder.removeFirst())
        }
    }

    private nonisolated static func fetchAndDecodeImage(from url: URL, assetId: String) async throws -> CGImage {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw FlywireAssetLoadError.httpStatus(assetId: assetId, status: status) }
            return try MediaAssetPreparer.decodeImage(data: data, assetId: assetId)
        } catch let error as FlywireAssetLoadError {
            throw error
        } catch let error as MediaAssetPreparationError {
            throw error
        } catch {
            throw FlywireAssetLoadError.network(assetId: assetId, reason: String(describing: error))
        }
    }
}
