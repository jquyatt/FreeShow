import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import ScrimCore

@Test func decodesVersionedAutosizeFixture() throws {
    let url = try #require(Bundle.module.url(forResource: "autosize-scene", withExtension: "json", subdirectory: "Fixtures"))
    let envelope = try JSONDecoder().decode(FlywireSceneEnvelope.self, from: Data(contentsOf: url))
    try envelope.validate()

    #expect(envelope.scene.items.count == 1)
    #expect(envelope.scene.items[0].chromiumFontSize == 116.21875)
    #expect(envelope.scene.items[0].textFit == "shrinkToFit")
    #expect(envelope.scene.items[0].visualLines == [
        .init(location: 0, length: 26), .init(location: 27, length: 19), .init(location: 46, length: 17)
    ])
}

@Test func decodesComputedTypographyExtension() throws {
    let style = FlywireTextStyle(
        fontFamily: "CMGSans",
        fontPostScriptName: "CMGSans-Medium",
        fontSize: 100,
        fontWeight: 400,
        fontStyle: "normal",
        italic: false,
        color: "rgb(0, 31, 63)",
        underline: false,
        letterSpacing: 0,
        wordSpacing: 0,
        lineHeightPx: 110,
        textShadows: [.init(offsetX: 2, offsetY: 2, blurRadius: 10, color: "rgb(0, 0, 0)")],
        textStrokeWidth: 0,
        textStrokeColor: "rgb(0, 0, 0)",
        textTransform: "none"
    )
    let decoded = try JSONDecoder().decode(FlywireTextStyle.self, from: JSONEncoder().encode(style))

    #expect(decoded == style)
    #expect(CTFontCopyPostScriptName(SceneRenderer().makeFont(style: decoded, scale: 1)) as String == "CMGSans-Medium")
}

@Test func rejectsMalformedVisualLineRanges() throws {
    let url = try #require(Bundle.module.url(forResource: "autosize-scene", withExtension: "json", subdirectory: "Fixtures"))
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var scene = try #require(object["scene"] as? [String: Any])
    var items = try #require(scene["items"] as? [[String: Any]])
    items[0]["visualLines"] = [["location": 0, "length": 10], ["location": 5, "length": 10]]
    scene["items"] = items
    object["scene"] = scene
    let envelope = try JSONDecoder().decode(FlywireSceneEnvelope.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(throws: FlywireProtocolError.self) {
        try envelope.validate()
    }
}

@Test func decodesAndValidatesNativeVideoBackground() throws {
    let url = try #require(Bundle.module.url(forResource: "autosize-scene", withExtension: "json", subdirectory: "Fixtures"))
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var scene = try #require(object["scene"] as? [String: Any])
    scene["background"] = [
        "color": "black",
        "video": [
            "assetId": "asset-video",
            "kind": "video",
            "url": "/assets/asset-video",
            "muted": true,
            "loop": true,
        ],
    ]
    object["scene"] = scene

    let envelope = try JSONDecoder().decode(FlywireSceneEnvelope.self, from: JSONSerialization.data(withJSONObject: object))
    try envelope.validate()

    #expect(envelope.scene.background.image == nil)
    #expect(envelope.scene.background.video?.assetId == "asset-video")
    #expect(envelope.scene.background.video?.muted == true)
    #expect(envelope.scene.background.video?.loop == true)
}

@Test func videoPlaybackStateExtrapolatesPlayingClockAndDetectsScrubs() {
    let first = FlywireVideoPlaybackState(
        outputId: "default",
        sceneId: "default:1",
        assetId: "asset-video",
        positionSeconds: 2,
        durationSeconds: 8,
        paused: false,
        loop: false,
        clearOnEnd: true,
        playbackRate: 1,
        sentAt: 1_000
    )
    let continuous = FlywireVideoPlaybackState(
        outputId: "default",
        sceneId: "default:1",
        assetId: "asset-video",
        positionSeconds: 2.1,
        durationSeconds: 8,
        paused: false,
        loop: false,
        clearOnEnd: true,
        playbackRate: 1,
        sentAt: 1_100
    )
    let scrubbed = FlywireVideoPlaybackState(
        outputId: "default",
        sceneId: "default:1",
        assetId: "asset-video",
        positionSeconds: 7.5,
        durationSeconds: 8,
        paused: true,
        loop: false,
        clearOnEnd: true,
        playbackRate: 1,
        sentAt: 1_200
    )

    #expect(first.isValid)
    #expect(abs(first.targetPosition(at: 1_250) - 2.25) < 0.0001)
    #expect(continuous.isExplicitSeek(from: first) == false)
    #expect(scrubbed.isExplicitSeek(from: continuous))
    #expect(scrubbed.targetPosition(at: 9_000) == 7.5)
}

@Test func rejectsImageAssetInVideoBackgroundSlot() throws {
    let url = try #require(Bundle.module.url(forResource: "autosize-scene", withExtension: "json", subdirectory: "Fixtures"))
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var scene = try #require(object["scene"] as? [String: Any])
    scene["background"] = [
        "color": "black",
        "video": ["assetId": "asset-image", "kind": "image", "url": "/assets/asset-image"],
    ]
    object["scene"] = scene
    let envelope = try JSONDecoder().decode(FlywireSceneEnvelope.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(throws: FlywireProtocolError.self) {
        try envelope.validate()
    }
}

@Test func rejectsVideoAssetInImageBackgroundSlot() throws {
    let url = try #require(Bundle.module.url(forResource: "autosize-scene", withExtension: "json", subdirectory: "Fixtures"))
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var scene = try #require(object["scene"] as? [String: Any])
    scene["background"] = [
        "color": "black",
        "image": ["assetId": "asset-video", "kind": "video", "url": "/assets/asset-video"],
    ]
    object["scene"] = scene
    let envelope = try JSONDecoder().decode(FlywireSceneEnvelope.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(throws: FlywireProtocolError.self) {
        try envelope.validate()
    }
}

@Test func corruptImageCannotBePreparedForPresentation() {
    #expect(throws: MediaAssetPreparationError.self) {
        try MediaAssetPreparer.decodeImage(
            data: Data("not an image".utf8),
            assetId: "asset-corrupt-image"
        )
    }
}

@Test func missingVideoCannotBePreparedForPresentation() async {
    let url = URL(fileURLWithPath: "/private/tmp/scrim-missing-video-\(UUID().uuidString).mp4")
    do {
        _ = try await MediaAssetPreparer.decodeVideoFirstFrame(
            url: url,
            assetId: "asset-missing-video"
        )
        Issue.record("A missing video unexpectedly produced a decoded first frame")
    } catch let error as MediaAssetPreparationError {
        #expect(error.description.contains("asset-missing-video"))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test func compositorRetainsWholeOutgoingAndIncomingScenes() throws {
    let url = try #require(Bundle.module.url(forResource: "autosize-scene", withExtension: "json", subdirectory: "Fixtures"))
    var envelope = try JSONDecoder().decode(FlywireSceneEnvelope.self, from: Data(contentsOf: url))
    let renderer = SceneRenderer()
    let firstImage = try #require(renderer.render(scene: envelope.scene))
    let compositor = SceneCompositor()
    compositor.prepare(PreparedScene(scene: envelope.scene, image: firstImage), at: 10)

    let secondData = try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: Data(contentsOf: url)))
    envelope = try JSONDecoder().decode(FlywireSceneEnvelope.self, from: secondData)
    let secondImage = try #require(renderer.render(scene: envelope.scene))
    compositor.prepare(PreparedScene(scene: envelope.scene, image: secondImage), at: 20)

    #expect(compositor.outgoing?.scene.id == "comparison:1")
    #expect(compositor.incoming?.scene.id == "comparison:1")
    #expect(abs(compositor.progress(at: 20.25) - 0.5) < 0.0001)
}

@Test func compositorUsesIndependentLayerTimingAndFreeShowEasing() throws {
    let url = try #require(Bundle.module.url(forResource: "autosize-scene", withExtension: "json", subdirectory: "Fixtures"))
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var scene = try #require(object["scene"] as? [String: Any])
    scene["transition"] = [
        "media": ["type": "cut", "durationMs": 0, "easing": "linear"],
        "text": ["type": "fade", "durationMs": 1_000, "easing": "sine"],
    ]
    object["scene"] = scene
    let envelope = try JSONDecoder().decode(FlywireSceneEnvelope.self, from: JSONSerialization.data(withJSONObject: object))
    let image = try #require(SceneRenderer().render(scene: envelope.scene))
    let compositor = SceneCompositor()
    let prepared = PreparedScene(scene: envelope.scene, image: image)

    compositor.prepare(prepared, at: 10)
    compositor.prepare(prepared, at: 20)
    let progress = compositor.layerProgress(at: 20.25)

    #expect(progress.media == 1)
    #expect(abs(progress.text - 0.1464466094) < 0.000001)
    #expect(compositor.isTransitionActive(at: 20.25))
}

@Test func identicalTextRemainsPersistentDuringMediaFade() throws {
    let url = try #require(Bundle.module.url(forResource: "autosize-scene", withExtension: "json", subdirectory: "Fixtures"))
    let envelope = try JSONDecoder().decode(FlywireSceneEnvelope.self, from: Data(contentsOf: url))
    let image = try #require(SceneRenderer().render(scene: envelope.scene))
    let compositor = SceneCompositor()
    let prepared = PreparedScene(scene: envelope.scene, image: image)
    compositor.prepare(prepared, at: 10)
    compositor.prepare(prepared, at: 20)

    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    var textAlphas: [CGFloat] = []
    compositor.draw(in: context, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), at: 20.25) { _, _, _, _, textAlpha in
        if textAlpha > 0 { textAlphas.append(textAlpha) }
    }

    #expect(textAlphas == [1])
}

@Test func identicalCrossDissolveDoesNotDipAtMidpoint() throws {
    let url = try #require(Bundle.module.url(forResource: "autosize-scene", withExtension: "json", subdirectory: "Fixtures"))
    let envelope = try JSONDecoder().decode(FlywireSceneEnvelope.self, from: Data(contentsOf: url))
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let imageContext = try #require(CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    imageContext.setFillColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1)
    imageContext.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    let image = try #require(imageContext.makeImage())

    let compositor = SceneCompositor()
    let prepared = PreparedScene(scene: envelope.scene, image: image)
    compositor.prepare(prepared, at: 10)
    compositor.prepare(prepared, at: 20)

    let output = try #require(CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    compositor.draw(in: output, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), at: 20.25)
    let pixel = try #require(output.data?.assumingMemoryBound(to: UInt8.self))

    #expect(pixel[0] >= 202)
    #expect(pixel[1] >= 100)
    #expect(pixel[2] >= 49)
    #expect(pixel[3] == 255)
}

@Test func coreTextMetricsAreObservableForChromiumComparison() throws {
    let url = try #require(Bundle.module.url(forResource: "autosize-scene", withExtension: "json", subdirectory: "Fixtures"))
    let envelope = try JSONDecoder().decode(FlywireSceneEnvelope.self, from: Data(contentsOf: url))
    let metrics = SceneRenderer().measure(textItem: try #require(envelope.scene.items.first))
    print("CoreText fixture metrics: lines=\(metrics.lineCount) breaks=\(metrics.lines) size=\(metrics.suggestedSize.width)x\(metrics.suggestedSize.height)")

    #expect(metrics.lineCount == 3)
    #expect(metrics.lines == ["Great is Your faithfulness", "Morning by morning ", "new mercies I see"])
    #expect(metrics.lineMetrics.count == 3)
    #expect(metrics.suggestedSize.width <= envelope.scene.items[0].frame.width + 1)
    #expect(metrics.suggestedSize.height <= 384)
}
