import CoreGraphics
import Foundation
import Testing
@testable import ScrimCore

private func reference(id: UInt32 = 42, fit: String = "contain", crop: FlywireRect? = nil) -> FlywireLiveSourceRef {
    .init(kind: "screenCapture", sourceId: "screen:0:0", target: "display", nativeId: id, fit: fit, crop: crop, showsCursor: true, muted: true)
}

@MainActor
private final class FakeCapture: LiveFrameSource {
    var starts = 0
    var stops = 0
    var ready = true
    var fail = false
    func start() async throws {
        starts += 1
        while !ready { try await Task.sleep(for: .milliseconds(1)) }
        if fail { throw CancellationError() }
    }
    func frame() -> CGImage? { nil }
    func stop() async { stops += 1 }
}

@MainActor
private func eventually(_ predicate: () -> Bool) async throws {
    for _ in 0..<1000 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for source lifecycle")
}

@Test @MainActor func retainedScenesShareCaptureUntilLastRelease() async throws {
    let source = FakeCapture()
    var creates = 0
    let manager = LiveSourceManager { _ in creates += 1; return source }
    try await manager.acquire(reference(), sceneId: "outgoing")
    try await manager.acquire(reference(fit: "cover"), sceneId: "incoming")
    #expect(creates == 1)
    #expect(source.starts == 1)
    manager.release(sceneId: "outgoing")
    await Task.yield()
    #expect(source.stops == 0)
    manager.release(sceneId: "incoming")
    try await eventually { source.stops == 1 }
}

@Test @MainActor func supersededPreparationCannotAcquireReleasedCapture() async throws {
    let source = FakeCapture()
    source.ready = false
    let manager = LiveSourceManager { _ in source }
    let take = Task { try await manager.acquire(reference(), sceneId: "stale") }
    try await eventually { source.starts == 1 }
    manager.release(sceneId: "stale")
    let result = await take.result
    if case .success = result { Issue.record("Superseded preparation became ready") }
    try await eventually { source.stops == 1 }
}

@Test @MainActor func failedIncomingSourceLeavesOutgoingCaptureRunning() async throws {
    let outgoing = FakeCapture()
    let incoming = FakeCapture()
    incoming.fail = true
    let manager = LiveSourceManager { $0.nativeId == 42 ? outgoing : incoming }
    try await manager.acquire(reference(), sceneId: "program")
    do {
        try await manager.acquire(reference(id: 43), sceneId: "failed")
        Issue.record("Expected preparation failure")
    } catch {}
    try await eventually { incoming.stops == 1 }
    #expect(outgoing.stops == 0)
    manager.shutdown()
    try await eventually { outgoing.stops == 1 }
}

@Test func liveSourceRoundTripAndValidation() throws {
    let source = reference(crop: .init(x: 0.25, y: 0, width: 0.5, height: 1))
    let decoded = try JSONDecoder().decode(FlywireLiveSourceRef.self, from: JSONEncoder().encode(source))
    try decoded.validate()
    #expect(decoded == source)
    #expect(throws: FlywireProtocolError.self) { try reference(id: 0).validate() }
    #expect(throws: FlywireProtocolError.self) { try reference(fit: "unknown").validate() }
    #expect(throws: FlywireProtocolError.self) { try reference(crop: .init(x: 0.8, y: 0, width: 0.5, height: 1)).validate() }
}

@Test func liveBackgroundDecodesAndRejectsConflictingFileMedia() throws {
    let url = try #require(Bundle.module.url(forResource: "autosize-scene", withExtension: "json", subdirectory: "Fixtures"))
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var scene = try #require(object["scene"] as? [String: Any])
    let live = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reference()))
    scene["background"] = ["color": "black", "live": live]
    object["scene"] = scene
    let decoder = JSONDecoder()
    let envelope = try decoder.decode(FlywireSceneEnvelope.self, from: JSONSerialization.data(withJSONObject: object))
    try envelope.validate()
    #expect(envelope.scene.background.live?.nativeId == 42)
    scene["background"] = ["color": "black", "live": live, "image": ["assetId": "a", "kind": "image", "url": "/a"]]
    object["scene"] = scene
    let conflicting = try decoder.decode(FlywireSceneEnvelope.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: FlywireProtocolError.self) { try conflicting.validate() }
}

@Test func liveCropAndFitProduceExpectedPixels() throws {
    func bitmap(_ width: Int, _ height: Int) throws -> CGContext {
        try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }
    let source = try bitmap(20, 10)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    source.setFillColor(CGColor(colorSpace: space, components: [1, 0, 0, 1])!)
    source.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
    source.setFillColor(CGColor(colorSpace: space, components: [0, 0, 1, 1])!)
    source.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
    let image = try #require(source.makeImage())
    let bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
    for fit in ["contain", "cover", "fill"] {
        let output = try bitmap(20, 20)
        LiveSourceDrawing.draw(image, source: reference(fit: fit), in: bounds, context: output)
        let bytes = try #require(output.data).assumingMemoryBound(to: UInt8.self)
        #expect(bytes[3] == (fit == "contain" ? 0 : 255))
        #expect(bytes[(10 * 20 + 10) * 4 + 3] == 255)
    }
    let cropped = try bitmap(20, 20)
    LiveSourceDrawing.draw(image, source: reference(fit: "fill", crop: .init(x: 0.5, y: 0, width: 0.5, height: 1)), in: bounds, context: cropped)
    let pixel = try #require(cropped.data).assumingMemoryBound(to: UInt8.self)
    // Sample inside the crop; the resampling kernel may blend the outermost edge.
    let index = (10 * 20 + 5) * 4
    #expect(pixel[index] == 0)
    #expect(pixel[index + 2] == 255)
}

@Test func identicalDynamicMediaDoesNotDimDuringFade() throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func bitmap() throws -> CGContext {
        try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }
    let background = try bitmap()
    background.setFillColor(CGColor(gray: 0, alpha: 1))
    background.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    let foreground = try bitmap()
    foreground.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
    foreground.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    let base = try #require(background.makeImage())
    let frame = try #require(foreground.makeImage())
    let bounds = CGRect(x: 0, y: 0, width: 20, height: 20)
    // Both video and live capture use this exact program/preview drawing function.
    for live: FlywireLiveSourceRef? in [nil, reference(fit: "fill")] {
        for alpha: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            let output = try bitmap()
            SceneMediaDrawing.draw(background: base, frame: frame, live: live, in: bounds, alpha: 1, context: output)
            SceneMediaDrawing.draw(background: base, frame: frame, live: live, in: bounds, alpha: alpha, context: output)
            let bytes = try #require(output.data).assumingMemoryBound(to: UInt8.self)
            #expect(bytes[0] == 255)
            #expect(bytes[1] == 255)
            #expect(bytes[2] == 255)
            #expect(bytes[3] == 255)
        }
    }
}

@Test @MainActor func oldAcquisitionCannotReleaseReplacementLease() async throws {
    let old = FakeCapture()
    old.ready = false
    let replacement = FakeCapture()
    var creates = 0
    let manager = LiveSourceManager { _ in
        creates += 1
        return creates == 1 ? old : replacement
    }
    let stale = Task { try await manager.acquire(reference(), sceneId: "reused") }
    try await eventually { old.starts == 1 }
    manager.release(sceneId: "reused")
    try await manager.acquire(reference(), sceneId: "reused")
    if case .success = await stale.result { Issue.record("Stale acquisition succeeded") }
    try await eventually { old.stops == 1 }
    #expect(replacement.starts == 1)
    #expect(replacement.stops == 0)
    manager.shutdown()
    try await eventually { replacement.stops == 1 }
}
