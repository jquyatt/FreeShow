import CoreGraphics

public enum LiveSourceDrawing {
    /// The same crop and fit operation is used for program and preview.
    public static func draw(_ image: CGImage, source: FlywireLiveSourceRef, in bounds: CGRect, context: CGContext) {
        var frame = image
        if let crop = source.crop {
            let rect = CGRect(x: crop.x * Double(image.width), y: crop.y * Double(image.height),
                              width: crop.width * Double(image.width), height: crop.height * Double(image.height))
            guard let cropped = image.cropping(to: rect) else { return }
            frame = cropped
        }
        var destination = bounds
        if source.fit != "fill" {
            let x = bounds.width / CGFloat(frame.width)
            let y = bounds.height / CGFloat(frame.height)
            let scale = source.fit == "cover" ? max(x, y) : min(x, y)
            let width = CGFloat(frame.width) * scale
            let height = CGFloat(frame.height) * scale
            destination = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
        }
        context.saveGState()
        context.clip(to: bounds)
        context.draw(frame, in: destination)
        context.restoreGState()
    }
}
