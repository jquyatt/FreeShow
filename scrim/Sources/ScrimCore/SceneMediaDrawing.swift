import CoreGraphics

/// Compose a dynamic frame over its background before applying transition opacity.
/// Program and preview must fade this complete media layer only once.
public enum SceneMediaDrawing {
    public static func draw(background: CGImage, frame: CGImage?, live: FlywireLiveSourceRef?,
                            in bounds: CGRect, alpha: CGFloat, context: CGContext) {
        guard alpha > 0 else { return }
        context.saveGState()
        context.setAlpha(alpha)
        let grouped = frame != nil && alpha < 1
        if grouped { context.beginTransparencyLayer(auxiliaryInfo: nil) }
        context.draw(background, in: bounds)
        if let frame {
            if let live {
                LiveSourceDrawing.draw(frame, source: live, in: bounds, context: context)
            } else {
                let scale = min(bounds.width / CGFloat(frame.width), bounds.height / CGFloat(frame.height))
                let size = CGSize(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale)
                let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                  width: size.width, height: size.height)
                context.saveGState()
                context.clip(to: bounds)
                context.draw(frame, in: rect)
                context.restoreGState()
            }
        }
        if grouped { context.endTransparencyLayer() }
        context.restoreGState()
    }
}
