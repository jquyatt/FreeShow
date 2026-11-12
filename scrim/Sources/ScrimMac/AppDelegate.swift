import AppKit
import Foundation
import ScrimCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var outputController: OutputWindowController?
    private var flywire: FlywireClient?
    private var statusItem: NSStatusItem?
    private let aboutPanel = ScrimAboutPanel()
    private let liveSources = LiveSourceManager { ScreenCaptureSource(reference: $0) }
    private var captureFixture: CaptureFixture?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--capture-fixture") {
            captureFixture = CaptureFixture()
            return
        }
        if CommandLine.arguments.contains("--capture-check") {
            Task { exit(await CaptureDiagnostics.run()) }
            return
        }
        let configuration = Configuration(arguments: CommandLine.arguments)
        let controller = OutputWindowController(screenIndex: configuration.screenIndex, baseURL: configuration.host, liveSources: liveSources, windowed: configuration.windowed)
        outputController = controller
        let status = installStatusItem(outputId: configuration.outputId)
        controller.onDisplayChange = { [weak status] displayName in
            let title = "Output: \(configuration.outputId) — \(displayName ?? "Waiting for external display")"
            guard status?.title != title else { return }
            status?.title = title
            if let displayName {
                print("[Scrim] running output=\(configuration.outputId) display=\(displayName) mode=\(configuration.windowed ? "windowed" : "fullscreen")")
            } else {
                print("[Scrim] fullscreen suspended output=\(configuration.outputId): waiting for external display")
            }
        }
        controller.reconcileDisplays()

        flywire = FlywireClient(baseURL: configuration.host, outputId: configuration.outputId, liveSources: liveSources) { [weak controller] revision, scene, assets, leaseId in
            controller?.outputView.receive(revision: revision, scene: scene, assets: assets, liveLeaseId: leaseId)
        }
        controller.outputView.onPreviewFrame = { [weak self] frame in
            self?.flywire?.sendPreviewFrame(frame)
        }
        flywire?.onPreviewDemand = { [weak controller] demand in
            controller?.outputView.setPreviewDemand(demand)
        }
        flywire?.onPreviewAcknowledgement = { [weak controller] frameId in
            controller?.outputView.acknowledgePreviewFrame(frameId)
        }
        flywire?.onPlaybackState = { [weak controller] state in
            controller?.outputView.applyPlaybackState(state)
        }
        flywire?.connect()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Fullscreen deliberately has no window while its display is disconnected.
        outputController?.windowed ?? true
    }

    func applicationWillTerminate(_ notification: Notification) { liveSources.shutdown() }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        outputController?.reconcileDisplays()
    }

    private func installStatusItem(outputId: String) -> NSMenuItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = ScrimMenuIcon.makeImage()
            button.toolTip = "Scrim — \(outputId)"
        }

        let menu = NSMenu()
        let identity = NSMenuItem(title: "Output: \(outputId)", action: nil, keyEquivalent: "")
        identity.isEnabled = false
        menu.addItem(identity)
        menu.addItem(.separator())
        let about = NSMenuItem(title: "About Scrim", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let permission = NSMenuItem(title: "Allow Screen Capture…", action: #selector(requestScreenCapture), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)
        let quit = NSMenuItem(title: "Quit Scrim", action: #selector(quitScrim), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        return identity
    }

    @objc private func quitScrim() {
        NSApp.terminate(nil)
    }

    @objc private func showAbout() {
        aboutPanel.show()
    }

    @objc private func requestScreenCapture() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        print("[Scrim] screen capture permission requested; restart Scrim after granting access")
    }
}

private struct Configuration {
    var host = URL(string: "http://127.0.0.1:5514")!
    var outputId = ProcessInfo.processInfo.environment["SCRIM_OUTPUT_ID"] ?? "default"
    var screenIndex: Int?
    var windowed = Bundle.main.bundleURL.pathExtension == "app"

    init(arguments: [String]) {
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--host" where index + 1 < arguments.count:
                host = URL(string: arguments[index + 1]) ?? host
                index += 1
            case "--output" where index + 1 < arguments.count:
                outputId = arguments[index + 1]
                index += 1
            case "--screen":
                screenIndex = -1
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    screenIndex = Int(arguments[index + 1]) ?? -1
                    index += 1
                }
            case "--windowed":
                windowed = true
            case "--fullscreen":
                windowed = false
            default:
                break
            }
            index += 1
        }
    }
}
