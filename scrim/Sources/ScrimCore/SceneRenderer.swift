import CoreGraphics
import CoreText
import Foundation

public struct TextLayoutMetrics: Equatable, Sendable {
    public let suggestedSize: CGSize
    public let lineCount: Int
    public let lines: [String]
    public let lineMetrics: [TextLineMetrics]
}

public struct TextRunAdvanceMetrics: Equatable, Sendable {
    public let range: NSRange
    public let advance: Double
    public let glyphAdvances: [TextGlyphAdvanceMetrics]
}

public struct TextGlyphAdvanceMetrics: Equatable, Sendable {
    public let stringIndex: Int
    public let advance: Double
}

public struct TextLineMetrics: Equatable, Sendable {
    public let range: NSRange
    public let typographicWidth: Double
    public let trailingWhitespaceWidth: Double
    public let usedWidth: Double
    public let baselineX: Double
    public let baselineY: Double
    public let runAdvances: [TextRunAdvanceMetrics]
}

private struct ForcedLine {
    let line: CTLine
    let range: NSRange
    let typographicWidth: CGFloat
    let trailingWhitespaceWidth: CGFloat
    let usedWidth: CGFloat
    let baselineX: CGFloat
    let baselineTop: CGFloat
}

private struct ForcedTextLayout {
    let lines: [ForcedLine]
    let blockHeight: CGFloat
    let maximumUsedWidth: CGFloat
}

public final class SceneRenderer: @unchecked Sendable {
    public init() {
        FlywireFontRegistry.registerAvailableFonts()
    }

    public func render(scene: FlywireScene, assets: [String: CGImage] = [:], includeBackground: Bool = true, includeText: Bool = true) -> CGImage? {
        let width = max(1, Int(scene.canvas.width.rounded()))
        let height = max(1, Int(scene.canvas.height.rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        // FreeShow scene coordinates are top-left based.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        if includeBackground {
            context.setFillColor(CGColor.css(scene.background.color))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            if let imageRef = scene.background.image, let image = assets[imageRef.assetId] {
                drawAspectFill(image, in: CGRect(x: 0, y: 0, width: width, height: height), context: context)
            }
        }

        if includeText {
            for item in scene.items where item.kind == "text" {
                draw(textItem: item, context: context)
            }
        }
        return context.makeImage()
    }

    public func measure(textItem: FlywireTextItem) -> TextLayoutMetrics {
        let attributed = attributedString(for: textItem, fontScale: resolvedFontScale(for: textItem))
        if let forced = forcedTextLayout(for: textItem, attributed: attributed as NSAttributedString) {
            let source = textItem.text as NSString
            let lineMetrics = forced.lines.map { forcedLine in
                TextLineMetrics(
                    range: forcedLine.range,
                    typographicWidth: forcedLine.typographicWidth,
                    trailingWhitespaceWidth: forcedLine.trailingWhitespaceWidth,
                    usedWidth: forcedLine.usedWidth,
                    baselineX: forcedLine.baselineX,
                    baselineY: forcedLine.baselineTop,
                    runAdvances: runAdvanceMetrics(for: forcedLine)
                )
            }
            return TextLayoutMetrics(
                suggestedSize: CGSize(width: forced.maximumUsedWidth, height: forced.blockHeight),
                lineCount: forced.lines.count,
                lines: forced.lines.map { source.substring(with: $0.range) },
                lineMetrics: lineMetrics
            )
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let constraint = CGSize(width: textItem.frame.width, height: .greatestFiniteMagnitude)
        let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, constraint, nil)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: textItem.frame.width, height: max(textItem.frame.height, size.height)), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        let source = (attributed as NSAttributedString).string as NSString
        let lineStrings = lines.map { line -> String in
            let range = CTLineGetStringRange(line)
            guard range.location != kCFNotFound, range.location + range.length <= source.length else { return "" }
            return source.substring(with: NSRange(location: range.location, length: range.length)).trimmingCharacters(in: .newlines)
        }
        return TextLayoutMetrics(suggestedSize: size, lineCount: lines.count, lines: lineStrings, lineMetrics: [])
    }

    private func draw(textItem: FlywireTextItem, context: CGContext) {
        let frame = CGRect(x: textItem.frame.x, y: textItem.frame.y, width: textItem.frame.width, height: textItem.frame.height)
        if let backgroundColor = textItem.backgroundColor {
            context.setFillColor(CGColor.css(backgroundColor))
            context.fill(frame)
        }

        let attributed = attributedString(for: textItem, fontScale: resolvedFontScale(for: textItem))
        if let forced = forcedTextLayout(for: textItem, attributed: attributed as NSAttributedString) {
            draw(forcedLayout: forced, textItem: textItem, in: frame, context: context)
            return
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: frame.width, height: .greatestFiniteMagnitude), nil)
        let textHeight = min(frame.height, ceil(suggested.height))
        let verticalOffset: CGFloat = switch textItem.verticalAlign {
        case "top": 0
        case "bottom": max(0, frame.height - textHeight)
        default: max(0, (frame.height - textHeight) / 2)
        }

        context.saveGState()
        context.setAlpha(max(0, min(1, textItem.opacity)))
        // Re-enter CoreText's bottom-left coordinate space inside the FreeShow box.
        context.translateBy(x: frame.minX, y: frame.minY + verticalOffset + textHeight)
        context.scaleBy(x: 1, y: -1)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: frame.width, height: textHeight), transform: nil)
        let textFrame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
        applyShadow(textItem.runs.first?.style.textShadows?.first, context: context)
        CTFrameDraw(textFrame, context)
        context.restoreGState()
    }

    private func forcedTextLayout(for item: FlywireTextItem, attributed: NSAttributedString) -> ForcedTextLayout? {
        guard let ranges = item.validatedVisualLineRanges else { return nil }
        let fixedLineHeight = item.runs.first.map { resolvedLineHeight(style: $0.style, scale: resolvedFontScale(for: item)) } ?? 0
        var baselineTop: CGFloat = 0
        var laidOut: [ForcedLine] = []

        for (index, range) in ranges.enumerated() {
            var line = CTLineCreateWithAttributedString(attributedLine(attributed, range: range))
            if item.textAlign == "justified", isSoftWrappedLine(index: index, ranges: ranges, source: item.text as NSString),
               let justified = CTLineCreateJustifiedLine(line, 1, item.frame.width)
            {
                line = justified
            }

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let typographicWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let trailing = CTLineGetTrailingWhitespaceWidth(line)
            let usedWidth = max(0, typographicWidth - trailing)
            let lineBoxHeight = fixedLineHeight > 0 ? fixedLineHeight : ascent + descent + leading
            // CSS centers the font's ascent+descent box inside a fixed line box.
            // CTLine alone exposes the natural ascent; CTFrame applies a similar
            // adjustment, but using it here would reintroduce independent wrapping.
            let baselineOffset = fixedLineHeight > 0
                ? ascent + (fixedLineHeight - ascent - descent) / 2
                : ascent
            baselineTop += baselineOffset
            let flush: CGFloat = switch item.textAlign {
            case "left", "justified": 0
            case "right": 1
            default: 0.5
            }
            let baselineX = CTLineGetPenOffsetForFlush(line, flush, item.frame.width)
            laidOut.append(.init(
                line: line,
                range: range,
                typographicWidth: typographicWidth,
                trailingWhitespaceWidth: trailing,
                usedWidth: usedWidth,
                baselineX: baselineX,
                baselineTop: baselineTop
            ))
            baselineTop += max(0, lineBoxHeight - baselineOffset)
        }

        return ForcedTextLayout(
            lines: laidOut,
            blockHeight: baselineTop,
            maximumUsedWidth: laidOut.map(\.usedWidth).max() ?? 0
        )
    }

    private func attributedLine(_ attributed: NSAttributedString, range: NSRange) -> NSAttributedString {
        if range.length > 0 { return attributed.attributedSubstring(from: range) }
        guard attributed.length > 0 else { return NSAttributedString(string: "\u{200B}") }
        let attributeIndex = min(range.location, attributed.length - 1)
        return NSAttributedString(string: "\u{200B}", attributes: attributed.attributes(at: attributeIndex, effectiveRange: nil))
    }

    private func isSoftWrappedLine(index: Int, ranges: [NSRange], source: NSString) -> Bool {
        guard index + 1 < ranges.count else { return false }
        let end = NSMaxRange(ranges[index])
        let next = ranges[index + 1].location
        guard next >= end else { return false }
        return !source.substring(with: NSRange(location: end, length: next - end)).contains("\n")
    }

    private func runAdvanceMetrics(for forcedLine: ForcedLine) -> [TextRunAdvanceMetrics] {
        (CTLineGetGlyphRuns(forcedLine.line) as? [CTRun] ?? []).map { run in
            let localRange = CTRunGetStringRange(run)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let width = CTRunGetTypographicBounds(run, CFRange(), &ascent, &descent, &leading)
            let glyphCount = CTRunGetGlyphCount(run)
            var advances = Array(repeating: CGSize.zero, count: glyphCount)
            var indices = Array(repeating: 0, count: glyphCount)
            CTRunGetAdvances(run, CFRange(), &advances)
            CTRunGetStringIndices(run, CFRange(), &indices)
            return TextRunAdvanceMetrics(
                range: NSRange(location: forcedLine.range.location + localRange.location, length: localRange.length),
                advance: width,
                glyphAdvances: advances.indices.map {
                    TextGlyphAdvanceMetrics(
                        stringIndex: forcedLine.range.location + indices[$0],
                        advance: advances[$0].width
                    )
                }
            )
        }
    }

    private func draw(forcedLayout: ForcedTextLayout, textItem: FlywireTextItem, in frame: CGRect, context: CGContext) {
        let textHeight = min(frame.height, forcedLayout.blockHeight)
        let verticalOffset: CGFloat = switch textItem.verticalAlign {
        case "top": 0
        case "bottom": max(0, frame.height - textHeight)
        default: max(0, (frame.height - textHeight) / 2)
        }

        context.saveGState()
        context.clip(to: frame)
        context.setAlpha(max(0, min(1, textItem.opacity)))
        context.translateBy(x: frame.minX, y: frame.minY + verticalOffset + textHeight)
        context.scaleBy(x: 1, y: -1)
        for forcedLine in forcedLayout.lines {
            context.textPosition = CGPoint(x: forcedLine.baselineX, y: textHeight - forcedLine.baselineTop)
            applyShadow(textItem.runs.first?.style.textShadows?.first, context: context)
            CTLineDraw(forcedLine.line, context)
        }
        context.restoreGState()
    }

    func attributedString(for item: FlywireTextItem, fontScale: Double) -> CFAttributedString {
        let result = NSMutableAttributedString()
        let alignment: CTTextAlignment = switch item.textAlign {
        case "left": .left
        case "right": .right
        case "justified": .justified
        default: .center
        }
        var alignmentValue = alignment
        let firstFont = item.runs.first.map { makeFont(style: $0.style, scale: fontScale) }
        var fixedLineHeight = item.runs.first.map { resolvedLineHeight(style: $0.style, scale: fontScale) } ?? 0
        var lineSpacingAdjustment = -(firstFont.map { CTFontGetLeading($0).rounded() } ?? 0)
        let hasLineHeight = fixedLineHeight > 0
        let paragraph = withUnsafeBytes(of: &alignmentValue) { alignmentBytes in
            withUnsafeBytes(of: &fixedLineHeight) { lineHeightBytes in
                withUnsafeBytes(of: &lineSpacingAdjustment) { spacingBytes in
                    var settings = [CTParagraphStyleSetting(spec: .alignment, valueSize: alignmentBytes.count, value: alignmentBytes.baseAddress!)]
                    if hasLineHeight {
                        settings.append(CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: lineHeightBytes.count, value: lineHeightBytes.baseAddress!))
                        settings.append(CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: lineHeightBytes.count, value: lineHeightBytes.baseAddress!))
                        // CoreText otherwise adds the font's rounded leading between
                        // fixed-height lines. CSS unitless line-height does not.
                        settings.append(CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: spacingBytes.count, value: spacingBytes.baseAddress!))
                    }
                    return CTParagraphStyleCreate(&settings, settings.count)
                }
            }
        }

        for run in item.runs {
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): makeFont(style: run.style, scale: fontScale),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor.css(run.style.color),
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
            ]
            // kCTKern=0 disables the font's kerning pairs. CSS letter-spacing
            // normal/0px preserves kerning, so omit the attribute at zero.
            if abs(run.style.letterSpacing) > .ulpOfOne {
                attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = run.style.letterSpacing
            }
            if let strokeWidth = run.style.textStrokeWidth, strokeWidth > 0 {
                // CoreText expresses stroke width as a percentage of font size;
                // negative values draw both fill and stroke, matching CSS.
                attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -(strokeWidth / run.style.fontSize * 100)
                attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = CGColor.css(run.style.textStrokeColor ?? run.style.color)
            }
            if run.style.underline {
                attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = CTUnderlineStyle.single.rawValue
            }
            let attributedRun = NSMutableAttributedString(string: run.text, attributes: attributes)
            if abs(run.style.wordSpacing) > .ulpOfOne {
                let source = run.text as NSString
                for index in 0..<source.length {
                    guard let scalar = Unicode.Scalar(source.character(at: index)), CharacterSet.whitespaces.contains(scalar) else { continue }
                    attributedRun.addAttribute(
                        NSAttributedString.Key(kCTKernAttributeName as String),
                        value: run.style.letterSpacing + run.style.wordSpacing,
                        range: NSRange(location: index, length: 1)
                    )
                }
            }
            result.append(attributedRun)
        }
        return result
    }

    func makeFont(style: FlywireTextStyle, scale: Double) -> CTFont {
        let size = style.fontSize * scale
        if let postScriptName = style.fontPostScriptName, !postScriptName.isEmpty {
            let exact = CTFontCreateWithName(postScriptName as CFString, size, nil)
            if CTFontCopyPostScriptName(exact) as String == postScriptName { return exact }
        }
        let base = CTFontCreateWithName(style.fontFamily as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if style.fontWeight >= 600 { traits.insert(.boldTrait) }
        if style.italic || style.fontStyle?.contains("italic") == true || style.fontStyle?.contains("oblique") == true { traits.insert(.italicTrait) }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    private func resolvedLineHeight(style: FlywireTextStyle, scale: Double) -> CGFloat {
        if let pixels = style.lineHeightPx, pixels > 0 { return CGFloat(pixels * scale) }
        return CGFloat((style.lineHeight ?? 0) * style.fontSize * scale)
    }

    private func applyShadow(_ shadow: FlywireTextShadow?, context: CGContext) {
        guard let shadow else {
            context.setShadow(offset: .zero, blur: 0, color: nil)
            return
        }
        context.setShadow(
            offset: CGSize(width: shadow.offsetX, height: -shadow.offsetY),
            blur: max(0, shadow.blurRadius),
            color: CGColor.css(shadow.color)
        )
    }

    func resolvedFontScale(for item: FlywireTextItem) -> Double {
        guard item.chromiumFontSize == nil, item.textFit != "none" else { return 1 }
        var lower = 0.05
        var upper = 1.0
        for _ in 0..<14 {
            let candidate = (lower + upper) / 2
            let attributed = attributedString(for: item, fontScale: candidate)
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: item.frame.width, height: .greatestFiniteMagnitude), nil)
            if size.width <= item.frame.width + 0.5, size.height <= item.frame.height + 0.5 {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return lower
    }

    private func drawAspectFill(_ image: CGImage, in rect: CGRect, context: CGContext) {
        let source = CGSize(width: image.width, height: image.height)
        let scale = max(rect.width / source.width, rect.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        let target = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: target.size))
        context.restoreGState()
    }
}

public extension CGColor {
    static func css(_ value: String) -> CGColor {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let named: [String: (Double, Double, Double, Double)] = [
            "black": (0, 0, 0, 1), "white": (1, 1, 1, 1), "red": (1, 0, 0, 1),
            "green": (0, 0.5, 0, 1), "blue": (0, 0, 1, 1), "transparent": (0, 0, 0, 0)
        ]
        if let components = named[normalized] {
            return CGColor(red: components.0, green: components.1, blue: components.2, alpha: components.3)
        }
        if normalized.hasPrefix("#") {
            let hex = String(normalized.dropFirst())
            let expanded = hex.count == 3 ? hex.map { "\($0)\($0)" }.joined() : hex
            if let raw = UInt64(expanded, radix: 16), expanded.count == 6 || expanded.count == 8 {
                let alpha = expanded.count == 8 ? Double(raw & 0xff) / 255 : 1
                let color = expanded.count == 8 ? raw >> 8 : raw
                return CGColor(red: Double((color >> 16) & 0xff) / 255, green: Double((color >> 8) & 0xff) / 255, blue: Double(color & 0xff) / 255, alpha: alpha)
            }
        }
        let rgbaPattern = #"rgba?\(([^)]+)\)"#
        if let regex = try? NSRegularExpression(pattern: rgbaPattern),
           let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
           let range = Range(match.range(at: 1), in: normalized) {
            let values = normalized[range].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if values.count >= 3 {
                return CGColor(red: values[0] / 255, green: values[1] / 255, blue: values[2] / 255, alpha: values.count > 3 ? values[3] : 1)
            }
        }
        return CGColor(gray: 0, alpha: 1)
    }
}
