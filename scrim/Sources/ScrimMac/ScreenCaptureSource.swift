import AppKit
import CoreImage
import ScreenCaptureKit
import ScrimCore

private struct CaptureFailure: Error, CustomStringConvertible {
    let description: String
}

/// Holds only the newest complete frame; the capture queue can never build a backlog.
private final class CaptureFrames: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: CVPixelBuffer?
    private var generation = 0
    private var failure: String?
    private var contentPixels: CGRect?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let image = sampleBuffer.imageBuffer else { return }
        lock.lock()
        buffer = image
        if let rect = attachments.first?[.contentRect] as? NSDictionary,
           let content = CGRect(dictionaryRepresentation: rect),
           let scale = attachments.first?[.scaleFactor] as? CGFloat {
            contentPixels = CGRect(x: content.minX * scale, y: content.minY * scale,
                                   width: content.width * scale, height: content.height * scale)
        } else {
            contentPixels = nil
        }
        generation += 1
        lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock()
        failure = error.localizedDescription
        lock.unlock()
    }

    func snapshot() -> (CVPixelBuffer?, Int, String?, CGRect?) {
        lock.lock()
        defer { lock.unlock() }
        return (buffer, generation, failure, contentPixels)
    }
}

@MainActor
final class ScreenCaptureSource: LiveFrameSource {
    private let reference: FlywireLiveSourceRef
    private let frames = CaptureFrames()
    private let queue = DispatchQueue(label: "app.freeshow.scrim.capture", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?
    private var lastImage: CGImage?
    private var lastGeneration = -1
    private var loggedFailure = false

    init(reference: FlywireLiveSourceRef) { self.reference = reference }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureFailure(description: "Screen Recording permission required for Scrim; grant access in System Settings and restart Scrim")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        let filter: SCContentFilter
        var size: CGSize
        if reference.target == "display" {
            guard let display = content.displays.first(where: { $0.displayID == reference.nativeId }) else {
                throw CaptureFailure(description: "Capture display \(reference.nativeId) is unavailable")
            }
            // Exclude Scrim itself to prevent feedback if its output is on the captured display.
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            size = CGSize(width: mode?.pixelWidth ?? CGDisplayPixelsWide(display.displayID),
                          height: mode?.pixelHeight ?? CGDisplayPixelsHigh(display.displayID))
        } else {
            guard let window = content.windows.first(where: { $0.windowID == reference.nativeId }),
                  window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier else {
                throw CaptureFailure(description: "Capture window \(reference.nativeId) is unavailable or belongs to Scrim")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = NSScreen.screens.first(where: {
                let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                return CGDisplayBounds(id).intersects(window.frame)
            })?.backingScaleFactor ?? 1
            size = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
            if #available(macOS 14.0, *) {
                size = CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                              height: filter.contentRect.height * CGFloat(filter.pointPixelScale))
            }
        }
        let configuration = SCStreamConfiguration()
        let scale = min(1, min(3840 / max(1, size.width), 2160 / max(1, size.height)))
        configuration.width = max(1, Int((size.width * scale).rounded()))
        configuration.height = max(1, Int((size.height * scale).rounded()))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.showsCursor = reference.showsCursor
        configuration.capturesAudio = false
        configuration.scalesToFit = true
        if #available(macOS 14.0, *) {
            configuration.ignoreShadowsSingleWindow = true
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: frames)
        self.stream = stream
        try stream.addStreamOutput(frames, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        let deadline = ContinuousClock.now + .seconds(5)
        while frame() == nil {
            try Task.checkCancellation()
            if let failure = frames.snapshot().2 { throw CaptureFailure(description: failure) }
            guard ContinuousClock.now < deadline else { throw CaptureFailure(description: "Capture timed out waiting for a complete first frame") }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("[Scrim] capture ready source=\(reference.sourceId) native=\(reference.nativeId) size=\(configuration.width)x\(configuration.height) muted=true")
    }

    func frame() -> CGImage? {
        let (buffer, generation, failure, contentPixels) = frames.snapshot()
        if let failure, !loggedFailure {
            loggedFailure = true
            print("[Scrim] capture failed source=\(reference.sourceId) action=hold-last-frame reason=\(failure)")
        }
        if generation != lastGeneration, let buffer {
            let image = CIImage(cvPixelBuffer: buffer)
            if let converted = context.createCGImage(image, from: image.extent) {
                if reference.target == "window", let contentPixels {
                    let content = contentPixels.intersection(CGRect(x: 0, y: 0, width: converted.width, height: converted.height))
                    if content.width > 0, content.height > 0 {
                        lastImage = converted.cropping(to: content) ?? converted
                    }
                } else {
                    lastImage = converted
                }
                lastGeneration = generation
            }
        }
        return lastImage
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        print("[Scrim] capture released source=\(reference.sourceId)")
    }
}
