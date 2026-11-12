@preconcurrency import CoreVideo
import CoreGraphics
import Foundation

final class DisplayLinkDriver: @unchecked Sendable {
    private var displayLink: CVDisplayLink?
    private let displayID: CGDirectDisplayID
    private let onFrame: @Sendable () -> Void

    init(displayID: CGDirectDisplayID, onFrame: @escaping @Sendable () -> Void) {
        self.displayID = displayID
        self.onFrame = onFrame
    }

    func start() {
        guard displayLink == nil else { return }
        var link: CVDisplayLink?
        guard CVDisplayLinkCreateWithCGDisplay(displayID, &link) == kCVReturnSuccess, let link else { return }
        displayLink = link
        CVDisplayLinkSetOutputCallback(
            link,
            { _, _, _, _, _, context in
                guard let context else { return kCVReturnError }
                let driver = Unmanaged<DisplayLinkDriver>.fromOpaque(context).takeUnretainedValue()
                driver.onFrame()
                return kCVReturnSuccess
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
        CVDisplayLinkStart(link)
    }

    func stop() {
        guard let displayLink else { return }
        CVDisplayLinkStop(displayLink)
        self.displayLink = nil
    }

    deinit { stop() }
}
