import CoreGraphics
import Foundation

public struct PreparedScene: @unchecked Sendable {
    public let scene: FlywireScene
    public let mediaImage: CGImage
    public let textImage: CGImage?

    /** Compatibility initializer for callers that already hold a composed image. */
    public init(scene: FlywireScene, image: CGImage) {
        self.scene = scene
        mediaImage = image
        textImage = nil
    }

    public init(scene: FlywireScene, mediaImage: CGImage, textImage: CGImage?) {
        self.scene = scene
        self.mediaImage = mediaImage
        self.textImage = textImage
    }

    public var image: CGImage { mediaImage }
}

public struct SceneLayerProgress: Equatable, Sendable {
    public let media: Double
    public let text: Double

    public var isComplete: Bool { media >= 1 && text >= 1 }
}

/// Retains two prepared scenes and animates media and text independently.
public final class SceneCompositor: @unchecked Sendable {
    public private(set) var outgoing: PreparedScene?
    public private(set) var incoming: PreparedScene?
    public private(set) var transitionStartedAt: TimeInterval = 0

    public init() {}

    public func prepare(_ scene: PreparedScene, at time: TimeInterval) {
        outgoing = incoming
        incoming = scene
        transitionStartedAt = time
        if scene.scene.transition.media.type == "cut", scene.scene.transition.text.type == "cut" {
            outgoing = nil
        }
    }

    /** Legacy media progress accessor retained for existing diagnostics/tests. */
    public func progress(at time: TimeInterval) -> Double {
        layerProgress(at: time).media
    }

    public func layerProgress(at time: TimeInterval) -> SceneLayerProgress {
        guard outgoing != nil, let incoming else { return .init(media: 1, text: 1) }
        return .init(
            media: Self.progress(for: incoming.scene.transition.media, elapsed: time - transitionStartedAt),
            text: Self.progress(for: incoming.scene.transition.text, elapsed: time - transitionStartedAt)
        )
    }

    public func isTransitionActive(at time: TimeInterval) -> Bool {
        outgoing != nil && !layerProgress(at: time).isComplete
    }

    public func draw(in context: CGContext, bounds: CGRect, at time: TimeInterval) {
        draw(in: context, bounds: bounds, at: time) { scene, context, bounds, mediaAlpha, textAlpha in
            if mediaAlpha > 0 {
                context.saveGState()
                context.setAlpha(mediaAlpha)
                context.draw(scene.mediaImage, in: bounds)
                context.restoreGState()
            }
            if textAlpha > 0, let textImage = scene.textImage {
                context.saveGState()
                context.setAlpha(textAlpha)
                context.draw(textImage, in: bounds)
                context.restoreGState()
            }
        }
    }

    public func draw(
        in context: CGContext,
        bounds: CGRect,
        at time: TimeInterval,
        renderer: (PreparedScene, CGContext, CGRect, CGFloat, CGFloat) -> Void
    ) {
        guard let incoming else { return }
        let value = layerProgress(at: time)
        if let outgoing, !value.isComplete {
            let outgoingMediaAlpha: CGFloat = incoming.scene.transition.media.type == "fade" ? 1 : 0
            let textIsPersistent = outgoing.scene.items == incoming.scene.items
            let outgoingTextAlpha: CGFloat = textIsPersistent ? 1 : incoming.scene.transition.text.type == "fade" ? CGFloat(1 - value.text) : 0
            let incomingTextAlpha: CGFloat = textIsPersistent ? 0 : CGFloat(value.text)
            // Media transitions below the complete text layer, matching the
            // Chromium output stacking order rather than fading whole scenes.
            renderer(outgoing, context, bounds, outgoingMediaAlpha, 0)
            renderer(incoming, context, bounds, CGFloat(value.media), 0)
            renderer(outgoing, context, bounds, 0, outgoingTextAlpha)
            renderer(incoming, context, bounds, 0, incomingTextAlpha)
        } else if value.isComplete {
            outgoing = nil
            renderer(incoming, context, bounds, 1, 1)
        } else {
            renderer(incoming, context, bounds, 1, 1)
        }
    }

    private static func progress(for transition: FlywireTransition, elapsed: TimeInterval) -> Double {
        guard transition.type == "fade", transition.durationMs > 0 else { return 1 }
        let linear = max(0, min(1, elapsed / (transition.durationMs / 1_000)))
        return max(0, min(1, ease(linear, name: transition.easing)))
    }

    /// Mirrors the easing functions used by FreeShow's Svelte transition helper.
    private static func ease(_ t: Double, name: String) -> Double {
        switch name {
        case "back":
            let s = 1.70158 * 1.525
            var value = t * 2
            if value < 1 { return 0.5 * (value * value * ((s + 1) * value - s)) }
            value -= 2
            return 0.5 * (value * value * ((s + 1) * value + s) + 2)
        case "sine":
            return -0.5 * (cos(.pi * t) - 1)
        case "circ":
            var value = t * 2
            if value < 1 { return -0.5 * (sqrt(max(0, 1 - value * value)) - 1) }
            value -= 2
            return 0.5 * (sqrt(max(0, 1 - value * value)) + 1)
        case "cubic":
            return t < 0.5 ? 4 * t * t * t : 0.5 * pow(2 * t - 2, 3) + 1
        case "elastic":
            if t < 0.5 {
                return 0.5 * sin((13 * .pi / 2) * 2 * t) * pow(2, 10 * (2 * t - 1))
            }
            return 0.5 * sin((-13 * .pi / 2) * (2 * t)) * pow(2, -10 * (2 * t - 1)) + 1
        case "bounce":
            if t < 0.5 { return 0.5 * (1 - bounceOut(1 - t * 2)) }
            return 0.5 * bounceOut(t * 2 - 1) + 0.5
        default:
            return t
        }
    }

    private static func bounceOut(_ t: Double) -> Double {
        let a = 4.0 / 11.0
        let b = 8.0 / 11.0
        let c = 9.0 / 10.0
        let t2 = t * t
        if t < a { return 7.5625 * t2 }
        if t < b { return 9.075 * t2 - 9.9 * t + 3.4 }
        if t < c { return (4356.0 / 361.0) * t2 - (35442.0 / 1805.0) * t + (16061.0 / 1805.0) }
        return 10.8 * t2 - 20.52 * t + 10.72
    }
}
