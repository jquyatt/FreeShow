import AppKit
import Foundation
import ScrimCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var routes: [FeedRoute] = []
    private var discovery: FlywireClient?
    private var catalog: [FlywireOutputOption]?
    private var host: URL?
    private var statusItem: NSStatusItem?
    private var displayMenu: NSMenu?
    private var previewMenu: NSMenuItem?
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
        let config = Configuration(arguments: CommandLine.arguments)
        host = config.host
        installStatusItem()
        addRoute(FeedRoute(host: config.host, outputId: config.outputId, screenIndex: config.screenIndex,
                           windowed: config.windowed, liveSources: liveSources))
        let client = FlywireClient(baseURL: config.host, outputId: "", liveSources: liveSources, subscribes: false) { _, _, _, _ in }
        client.onOutputCatalog = { [weak self] options in self?.catalog = options }
        client.onDisconnect = { [weak self] in self?.catalog = nil }
        discovery = client
        client.connect()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !routes.contains { !$0.outputController.windowed }
    }

    func applicationWillTerminate(_ notification: Notification) { liveSources.shutdown() }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        for route in routes { route.reconcile() }
    }

    private func addRoute(_ route: FeedRoute) {
        routes.append(route)
        route.start()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Read the live topology when the menu opens, including connections that
        // changed while the menu was closed. Never use a saved display index here.
        discovery?.requestOutputCatalog()
        if let previewMenu {
            if let route = routes.first(where: { $0.outputController.windowed }) {
                let feeds = NSMenu(title: "Preview Feed")
                route.populate(feeds, catalog: catalog)
                previewMenu.submenu = feeds
                previewMenu.isHidden = false
            } else {
                previewMenu.isHidden = true
            }
        }
        guard let displayMenu else { return }
        displayMenu.removeAllItems()
        let displays = OutputWindowController.eligibleDisplays()
        let assigned = routes.filter { !$0.outputController.windowed }
        let offline = assigned.filter { route in
            !displays.contains { $0.identity == route.displayIdentity }
        }
        for display in displays {
            let route = assigned.first { $0.displayIdentity == display.identity }
            let label = displays.filter { $0.name == display.name }.count > 1
                ? "\(display.name) (\(display.identity.prefix(8)))" : display.name
            addDisplay(label, identity: display.identity, route: route, online: true, to: displayMenu)
        }
        for route in offline {
            addDisplay(route.displayLabel ?? "External display", identity: route.displayIdentity,
                       route: route, online: false, to: displayMenu)
        }
        if displayMenu.items.isEmpty {
            displayMenu.addItem(withTitle: "No eligible external displays", action: nil, keyEquivalent: "")
        }
    }

    private func addDisplay(_ label: String, identity: String?, route: FeedRoute?, online: Bool, to menu: NSMenu) {
        let name = route.map { route in catalog?.first { $0.id == route.activeOutput }?.name ?? route.activeOutput } ?? "Off"
        let item = NSMenuItem(title: "\(label) — \(online ? name : "\(name) (offline)")", action: nil, keyEquivalent: "")
        let feeds = NSMenu(title: label)
        item.submenu = feeds
        menu.addItem(item)
        if let route {
            let off = feeds.addItem(withTitle: "Turn Off This Display", action: #selector(removeDisplay(_:)), keyEquivalent: "")
            off.target = self
            off.representedObject = route
            if online {
                feeds.addItem(.separator())
                route.populate(feeds, catalog: catalog)
            }
        } else if let identity, let catalog, !catalog.isEmpty {
            for option in catalog {
                let name = catalog.filter { $0.name == option.name }.count > 1 ? "\(option.name) (\(option.id))" : option.name
                let assign = feeds.addItem(withTitle: name, action: #selector(assignDisplay(_:)), keyEquivalent: "")
                assign.target = self
                assign.representedObject = [identity, option.id]
            }
        } else {
            feeds.addItem(withTitle: catalog == nil ? "Waiting for FreeShow’s feed list" : "No Flywire feeds published", action: nil, keyEquivalent: "")
        }
    }

    @objc private func assignDisplay(_ item: NSMenuItem) {
        guard let values = item.representedObject as? [String], values.count == 2, let host,
              catalog?.contains(where: { $0.id == values[1] }) == true,
              !routes.contains(where: { $0.displayIdentity == values[0] }),
              let display = OutputWindowController.eligibleDisplays().first(where: { $0.identity == values[0] }) else { return }
        // An unresolved launch target must not later claim a manually assigned display.
        let unbound = routes.filter { !$0.outputController.windowed && $0.displayIdentity == nil }
        routes.removeAll { route in unbound.contains { $0 === route } }
        unbound.forEach { $0.stop() }
        addRoute(FeedRoute(host: host, outputId: values[1], screenIndex: nil, displayIdentity: display.identity,
                           displayLabel: display.name, windowed: false, liveSources: liveSources))
    }

    @objc private func removeDisplay(_ item: NSMenuItem) {
        guard let route = item.representedObject as? FeedRoute, !route.outputController.windowed else { return }
        routes.removeAll { $0 === route }
        route.stop()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = ScrimMenuIcon.makeImage()
        item.button?.toolTip = "Scrim — Display Assignments"
        let menu = NSMenu()
        menu.delegate = self
        let displays = NSMenuItem(title: "Displays", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Displays")
        displayMenu = submenu
        displays.submenu = submenu
        menu.addItem(displays)
        let preview = NSMenuItem(title: "Preview Feed", action: nil, keyEquivalent: "")
        previewMenu = preview
        menu.addItem(preview)
        menu.addItem(.separator())
        for (title, action, key) in [("About Scrim", #selector(showAbout), ""),
                                     ("Allow Screen Capture…", #selector(requestScreenCapture), ""),
                                     ("Quit Scrim", #selector(quitScrim), "q")] {
            let command = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            command.target = self
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func quitScrim() { NSApp.terminate(nil) }

    @objc private func showAbout() { aboutPanel.show() }

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
