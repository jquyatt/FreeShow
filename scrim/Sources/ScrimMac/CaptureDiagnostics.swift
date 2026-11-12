import AppKit
import ScreenCaptureKit
import ScrimCore

/// Opt-in development probe. Uses a separate disposable window process, never the user's show.
@MainActor
enum CaptureDiagnostics {
    static func run() async -> Int32 {
        guard CGPreflightScreenCaptureAccess() else {
            print("[Capture check] BLOCKED: Screen Recording permission is not granted to this Scrim executable. Use the Scrim menu's Allow Screen Capture action, then restart.")
            return 2
        }
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        fixture.arguments = ["--capture-fixture"]
        defer { if fixture.isRunning { fixture.terminate() } }
        do {
            try fixture.run()
            var target: SCWindow?
            for _ in 0..<40 {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                target = content.windows.first { $0.owningApplication?.processID == fixture.processIdentifier && $0.title == "Scrim Capture Fixture" }
                if target != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let target else { throw ProbeError("fixture window was not enumerated") }
            let reference = FlywireLiveSourceRef(sourceId: "window:\(target.windowID):0", target: "window", nativeId: target.windowID)
            let source = ScreenCaptureSource(reference: reference)
            do {
                try await source.start()
                var signatures: Set<Int> = []
                var sawLandscape = false
                var sawPortrait = false
                for _ in 0..<80 {
                    if let image = source.frame(), let data = image.dataProvider?.data {
                        sawLandscape = sawLandscape || image.width > image.height
                        sawPortrait = sawPortrait || image.height > image.width
                        let length = CFDataGetLength(data)
                        if let bytes = CFDataGetBytePtr(data), length > 4 {
                            let index = min(length - 4, (image.height / 2) * image.bytesPerRow + (image.width / 2) * 4)
                            signatures.insert(Int(bytes[index]) << 16 | Int(bytes[index + 1]) << 8 | Int(bytes[index + 2]))
                        }
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard signatures.count >= 2 else { throw ProbeError("window capture did not update") }
                guard sawLandscape && sawPortrait else { throw ProbeError("resizing the source did not update its captured aspect ratio") }
                fixture.terminate()
                try await Task.sleep(for: .milliseconds(500))
                guard source.frame() != nil else { throw ProbeError("source disappearance discarded the last valid frame") }
                await source.stop()
                print("[Capture check] PASS: window frames updated (\(signatures.count) distinct samples), resize exercised, disappearance retained a frame, capture released")
            } catch {
                await source.stop()
                throw error
            }
            let display = ScreenCaptureSource(reference: .init(sourceId: "screen:probe:0", target: "display", nativeId: CGMainDisplayID()))
            do {
                try await display.start()
                guard let frame = display.frame() else { throw ProbeError("display first frame missing") }
                print("[Capture check] PASS: display first frame \(frame.width)x\(frame.height)")
                await display.stop()
            } catch {
                await display.stop()
                throw error
            }
            let missing = ScreenCaptureSource(reference: .init(sourceId: "window:4294967295:0", target: "window", nativeId: .max))
            var rejected = false
            do { try await missing.start() } catch { rejected = true }
            await missing.stop()
            guard rejected else { throw ProbeError("missing source was accepted") }
            print("[Capture check] PASS: missing source rejected")
            return 0
        } catch {
            print("[Capture check] FAIL: \(error)")
            return 1
        }
    }

    private struct ProbeError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

@MainActor
final class CaptureFixture {
    private let window: NSWindow
    private var timer: Timer?
    private var tick = 0

    init() {
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 360), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Scrim Capture Fixture"
        window.backgroundColor = .red
        window.orderFrontRegardless()
        print("[Capture fixture] windowId=\(window.windowNumber) displayId=\(CGMainDisplayID())")
        fflush(stdout)
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick += 1
                self.window.backgroundColor = self.tick.isMultiple(of: 2) ? .blue : .red
                if self.tick == 10 { self.window.setContentSize(NSSize(width: 360, height: 640)) }
                if self.tick >= 300 { NSApp.terminate(nil) }
            }
        }
    }
}
