import AppKit
import Foundation
import ScrimCore

@MainActor
final class FeedRoute: NSObject {
    let outputController: OutputWindowController
    private var flywire: FlywireClient?
    private var activeConnection = UUID()
    private(set) var activeOutput: String
    private var pending: (id: String, token: UUID, client: FlywireClient)?
    private var pendingPlayback: FlywireVideoPlaybackState?
    private var switchDeadline: Task<Void, Never>?
    private var switchError: String?
    private let host: URL
    private let liveSources: LiveSourceManager
    private var waitingForFirstScene: Bool
    private(set) var displayLabel: String?
    private var lastDisplayStatus: String?
    var displayIdentity: String? { outputController.displayIdentity }

    init(host: URL, outputId: String, screenIndex: Int?, displayIdentity: String? = nil,
         displayLabel: String? = nil, windowed: Bool, liveSources: LiveSourceManager) {
        self.host = host
        activeOutput = outputId
        self.liveSources = liveSources
        self.displayLabel = displayLabel
        waitingForFirstScene = displayIdentity != nil
        let controller = OutputWindowController(screenIndex: screenIndex, displayIdentity: displayIdentity, baseURL: host, liveSources: liveSources, windowed: windowed)
        outputController = controller
        super.init()
        controller.onDisplayChange = { [weak self, weak controller] displayName in
            guard let self else { return }
            let status = displayName ?? ""
            guard self.lastDisplayStatus != status else { return }
            self.lastDisplayStatus = status
            if let displayName { self.displayLabel = displayName }
            if let displayName {
                print("[Scrim] running output=\(self.activeOutput) display=\(displayName) mode=\(controller?.windowed == true ? "windowed" : "fullscreen")")
            } else {
                print("[Scrim] fullscreen suspended output=\(self.activeOutput): waiting for external display")
            }
        }
        flywire = makeClient(host: host, outputId: activeOutput, token: activeConnection, previewReady: true)
        controller.outputView.onPreviewFrame = { [weak self] frame in
            self?.flywire?.sendPreviewFrame(frame)
        }
    }

    func start() {
        reconcile()
        flywire?.connect()
    }

    func reconcile() {
        if !waitingForFirstScene { outputController.reconcileDisplays() }
    }

    func stop() {
        cancelFeedSwitch()
        activeConnection = UUID()
        flywire?.disconnect()
        flywire = nil
        outputController.stop()
        outputController.outputView.releaseAllMedia()
    }

    private func makeClient(host: URL, outputId: String, token: UUID, previewReady: Bool) -> FlywireClient {
        let client = FlywireClient(baseURL: host, outputId: outputId, liveSources: liveSources, previewReady: previewReady) { [weak self] revision, scene, assets, leaseId in
            guard let self else { return }
            let view = self.outputController.outputView
            if self.activeConnection == token {
                if view.receive(revision: revision, scene: scene, assets: assets, liveLeaseId: leaseId), self.waitingForFirstScene {
                    self.waitingForFirstScene = false
                    self.reconcile()
                }
            } else if let pending = self.pending, pending.token == token {
                guard view.receive(revision: revision, scene: scene, assets: assets, liveLeaseId: leaseId, forceCut: true) else { return }
                if let playback = self.pendingPlayback, playback.sceneId == scene.id { view.applyPlaybackState(playback) }
                view.setPreviewDemand(.init(enabled: false, maxWidth: 640, framesPerSecond: 12))
                let previous = self.flywire
                self.activeConnection = token
                self.activeOutput = pending.id
                self.flywire = pending.client
                self.pending = nil
                self.pendingPlayback = nil
                self.switchDeadline?.cancel()
                self.switchDeadline = nil
                previous?.disconnect()
                self.flywire?.enablePreview()
                if self.waitingForFirstScene {
                    self.waitingForFirstScene = false
                    self.reconcile()
                }
                print("[Scrim] switched feed output=\(scene.outputId) revision=\(revision)")
            } else if let leaseId {
                self.liveSources.release(sceneId: leaseId)
            }
        }
        client.onDisconnect = { [weak self] in
            guard let self, self.pending?.token == token else { return }
            self.cancelFeedSwitch(reason: "Connection lost; kept current feed")
        }
        client.onSubscriptionError = { [weak self] _ in
            guard self?.pending?.token == token else { return }
            self?.cancelFeedSwitch(reason: "Feed unavailable; kept current feed")
        }
        client.onPreviewDemand = { [weak self] demand in
            guard self?.activeConnection == token else { return }
            self?.outputController.outputView.setPreviewDemand(demand)
        }
        client.onPreviewAcknowledgement = { [weak self] frameId in
            guard self?.activeConnection == token else { return }
            self?.outputController.outputView.acknowledgePreviewFrame(frameId)
        }
        client.onPlaybackState = { [weak self] state in
            if self?.activeConnection == token {
                self?.outputController.outputView.applyPlaybackState(state)
            } else if self?.pending?.token == token {
                self?.pendingPlayback = state
            }
        }
        return client
    }

    @objc private func selectFeed(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if id == pending?.id { return }
        cancelFeedSwitch()
        guard id != activeOutput else { return }
        let token = UUID()
        let client = makeClient(host: host, outputId: id, token: token, previewReady: false)
        pending = (id, token, client)
        print("[Scrim] preparing feed switch from=\(activeOutput) to=\(id)")
        switchDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            guard self?.pending?.token == token else { return }
            self?.cancelFeedSwitch(reason: "No scene ready; kept current feed")
        }
        client.connect()
    }

    @objc private func cancelSelection() { cancelFeedSwitch() }

    private func cancelFeedSwitch(reason: String? = nil) {
        let previous = pending
        pending = nil
        pendingPlayback = nil
        switchDeadline?.cancel()
        switchDeadline = nil
        previous?.client.disconnect()
        switchError = reason
        if let reason { print("[Scrim] feed switch canceled: \(reason)") }
    }

    func populate(_ feedMenu: NSMenu, catalog: [FlywireOutputOption]?) {
        func name(_ id: String) -> String { catalog?.first(where: { $0.id == id })?.name ?? id }
        if waitingForFirstScene {
            feedMenu.addItem(withTitle: "Waiting for \(name(activeOutput))…", action: nil, keyEquivalent: "")
        }
        if let detail = pending.map({ "Preparing \(name($0.id))…" }) ?? switchError {
            feedMenu.addItem(withTitle: detail, action: nil, keyEquivalent: "")
        }
        if pending != nil {
            let cancel = feedMenu.addItem(withTitle: "Cancel Switch", action: #selector(cancelSelection), keyEquivalent: "")
            cancel.target = self
        }
        if let catalog, !catalog.isEmpty {
            for option in catalog {
                let label = catalog.contains { $0.id != option.id && $0.name == option.name } ? "\(option.name) (\(option.id))" : option.name
                let item = feedMenu.addItem(withTitle: label, action: #selector(selectFeed(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = option.id
                item.state = option.id == activeOutput ? .on : .off
            }
        } else {
            let hint = catalog == nil ? "Waiting for FreeShow’s feed list" : "No Flywire feeds published"
            feedMenu.addItem(withTitle: hint, action: nil, keyEquivalent: "")
        }
    }
}
