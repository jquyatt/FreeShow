import AppKit

enum ScrimMenuIcon {
    @MainActor
    static func makeImage() -> NSImage {
        // A small, transparent adaptation of ScrimIcon.svg: rail, curtain hem,
        // and projected mark. The template alpha lets AppKit supply the tint.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 2, width: 16, height: 2), xRadius: 1, yRadius: 1).fill()

            let curtain = NSBezierPath()
            curtain.move(to: NSPoint(x: 3.5, y: 5))
            curtain.line(to: NSPoint(x: 2.5, y: 15))
            curtain.curve(to: NSPoint(x: 9, y: 15.5), controlPoint1: NSPoint(x: 5, y: 16.5), controlPoint2: NSPoint(x: 7, y: 16.5))
            curtain.curve(to: NSPoint(x: 15.5, y: 15), controlPoint1: NSPoint(x: 11, y: 16.5), controlPoint2: NSPoint(x: 13, y: 16.5))
            curtain.line(to: NSPoint(x: 14.5, y: 5))
            curtain.lineWidth = 1.5
            curtain.lineCapStyle = .round
            curtain.lineJoinStyle = .round
            curtain.stroke()

            let projection = NSBezierPath(roundedRect: NSRect(x: 5.25, y: 7, width: 7.5, height: 5.5), xRadius: 1.5, yRadius: 1.5)
            projection.append(NSBezierPath(roundedRect: NSRect(x: 6.75, y: 8.5, width: 4.5, height: 2.5), xRadius: 0.5, yRadius: 0.5))
            projection.windingRule = .evenOdd
            projection.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Scrim"
        return image
    }
}
