import AppKit
import ScrimCore

@MainActor
final class OutputWindowController: NSWindowController, NSWindowDelegate {
    let outputView: SceneOutputView
    let windowed: Bool
    private var target: FullscreenDisplayTarget
    private var reconciling = false
    var onDisplayChange: ((String?) -> Void)?
    var displayIdentity: String? { windowed ? nil : target.identity }

    init(screenIndex: Int?, displayIdentity: String? = nil, baseURL: URL, liveSources: LiveSourceManager, windowed: Bool) {
        self.windowed = windowed
        target = FullscreenDisplayTarget(requestedIndex: screenIndex, identity: displayIdentity)
        outputView = SceneOutputView(frame: .zero, baseURL: baseURL, liveSources: liveSources)
        super.init(window: nil)
    }

    private func makeWindow(on screen: NSScreen) -> NSWindow {
        let contentRect = windowed ? Self.windowedFrame(on: screen) : screen.frame
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: windowed ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.contentView = outputView
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.title = windowed ? "Scrim Test Output" : "Scrim"
        window.level = windowed ? .normal : .screenSaver
        window.collectionBehavior = windowed ? [] : [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        window.acceptsMouseMovedEvents = false
        window.ignoresMouseEvents = !windowed
        if windowed {
            window.contentAspectRatio = NSSize(width: 16, height: 9)
            window.minSize = NSSize(width: 480, height: 270)
            window.center()
        } else {
            window.setFrame(screen.frame, display: true)
        }
        window.delegate = self
        return window
    }

    required init?(coder: NSCoder) { nil }

    func reconcileDisplays() {
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }
        let screens = NSScreen.screens
        if windowed {
            if let window { outputView.setDisplay(window.screen.flatMap(Self.displayID)); return }
            let preferred = target.requestedIndex.flatMap { screens.indices.contains($0) ? screens[$0] : nil }
            guard let screen = preferred ?? screens.dropFirst().first ?? screens.first else { return }
            let window = makeWindow(on: screen)
            self.window = window
            outputView.setDisplay(window.screen.flatMap(Self.displayID))
            window.orderFrontRegardless()
            onDisplayChange?(window.screen?.localizedName ?? screen.localizedName)
            return
        }

        let displays = screens.map(Self.display)
        guard let id = target.resolve(displays), let screen = screens.first(where: { Self.displayID($0) == id }) else {
            suspendFullscreen()
            return
        }
        if let window, window.screen.flatMap(Self.displayID) != id { suspendFullscreen() }
        let newWindow = self.window == nil
        let window = self.window ?? makeWindow(on: screen)
        self.window = window
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        guard Self.isEligible(id), window.screen.flatMap(Self.displayID) == id else {
            suspendFullscreen()
            return
        }
        outputView.setDisplay(id)
        if newWindow {
            window.orderFrontRegardless()
            onDisplayChange?(screen.localizedName)
        }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        // AppKit can relocate a visible window before the application-level display notification.
        reconcileDisplays()
    }

    func stop() { suspendFullscreen() }

    static func eligibleDisplays() -> [(identity: String, name: String)] {
        let screens = NSScreen.screens
        let displays = screens.map(Self.display)
        return zip(screens, displays).compactMap { screen, display in
            guard display.eligible, let identity = display.identity,
                  displays.filter({ $0.identity == identity }).count == 1 else { return nil }
            return (identity, screen.localizedName)
        }
    }

    private static func display(_ screen: NSScreen) -> FullscreenDisplayTarget.Display {
        let id = displayID(screen) ?? 0
        let uuid = id == 0 ? nil : CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
        return .init(id: id, identity: uuid.map { CFUUIDCreateString(nil, $0) as String }, eligible: isEligible(id))
    }

    private func suspendFullscreen() {
        if let window {
            window.orderOut(nil)
            window.delegate = nil
            window.contentView = nil
            self.window = nil
        }
        outputView.setDisplay(nil)
        onDisplayChange?(nil)
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private static func isEligible(_ id: CGDirectDisplayID) -> Bool {
        id != 0 && id != CGMainDisplayID() && CGDisplayIsBuiltin(id) == 0 && CGDisplayIsActive(id) != 0 && CGDisplayIsInMirrorSet(id) == 0
    }

    private static func windowedFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let width = min(960, visible.width * 0.7)
        let height = width * 9 / 16
        return NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
    }
}
