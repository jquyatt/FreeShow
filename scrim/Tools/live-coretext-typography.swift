import CoreGraphics
import CoreText
import Foundation

struct TraceRoot: Decodable { let items: [TraceEntry] }
struct TraceEntry: Decodable { let text: String; let flywire: TextItem? }
struct TextItem: Decodable { let id: String; let frame: Rect; let runs: [TextRun] }
struct Rect: Decodable { let x: Double; let y: Double; let width: Double; let height: Double }
struct TextRun: Decodable { let text: String; let style: TextStyle }
struct TextShadow: Decodable { let offsetX: Double; let offsetY: Double; let blurRadius: Double; let color: String }
struct TextStyle: Decodable {
    let fontFamily: String
    let fontPostScriptName: String?
    let fontSize: Double
    let fontWeight: Int
    let fontStyle: String?
    let italic: Bool
    let color: String
    let letterSpacing: Double
    let wordSpacing: Double
    let lineHeight: Double?
    let lineHeightPx: Double?
    let textShadows: [TextShadow]?
    let textStrokeWidth: Double?
    let textStrokeColor: String?
    let textTransform: String?
}

func cssColor(_ value: String) -> CGColor {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized.hasPrefix("#") {
        let raw = UInt64(normalized.dropFirst(), radix: 16) ?? 0
        return CGColor(red: CGFloat((raw >> 16) & 0xff) / 255, green: CGFloat((raw >> 8) & 0xff) / 255, blue: CGFloat(raw & 0xff) / 255, alpha: 1)
    }
    let values = normalized.replacingOccurrences(of: "rgba(", with: "").replacingOccurrences(of: "rgb(", with: "").replacingOccurrences(of: ")", with: "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    if values.count >= 3 {
        return CGColor(red: values[0] / 255, green: values[1] / 255, blue: values[2] / 255, alpha: values.count > 3 ? values[3] : 1)
    }
    return CGColor(gray: normalized == "white" ? 1 : 0, alpha: 1)
}

func registerAuthoringFonts() {
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let directories = [current.appendingPathComponent("../public/fonts").standardizedFileURL, current.appendingPathComponent("public/fonts").standardizedFileURL]
    for directory in directories {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
        for file in files where ["woff2", "otf", "ttf"].contains(file.pathExtension.lowercased()) {
            var error: Unmanaged<CFError>?
            _ = CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error)
        }
    }
}

func round3(_ value: CGFloat) -> Double { Double((value * 1000).rounded() / 1000) }

registerAuthoringFonts()
let inputURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCRIM_TRACE_FLYWIRE_OUTPUT"] ?? "Artifacts/live-typography-flywire.json")
let entries = try JSONDecoder().decode(TraceRoot.self, from: Data(contentsOf: inputURL)).items
var reports: [[String: Any]] = []

for entry in entries {
    guard let item = entry.flywire, let firstRun = item.runs.first else { continue }
    let style = firstRun.style
    let requestedName = style.fontPostScriptName ?? style.fontFamily
    let base = CTFontCreateWithName(requestedName as CFString, style.fontSize, nil)
    var requestedTraits: CTFontSymbolicTraits = []
    if style.fontPostScriptName == nil, style.fontWeight >= 600 { requestedTraits.insert(.boldTrait) }
    if style.fontPostScriptName == nil, style.italic || style.fontStyle?.contains("italic") == true || style.fontStyle?.contains("oblique") == true { requestedTraits.insert(.italicTrait) }
    let font = requestedTraits.isEmpty ? base : CTFontCreateCopyWithSymbolicTraits(base, style.fontSize, nil, requestedTraits, requestedTraits) ?? base
    let fill = cssColor(style.color)
    var attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill
    ]
    if abs(style.letterSpacing) > .ulpOfOne { attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = style.letterSpacing }
    if let stroke = style.textStrokeWidth, stroke > 0 {
        attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -(stroke / style.fontSize * 100)
        attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = cssColor(style.textStrokeColor ?? style.color)
    }
    let attributed = NSAttributedString(string: entry.text, attributes: attributes)
    let line = CTLineCreateWithAttributedString(attributed)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let advance = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    let naturalLineHeight = ascent + descent + leading
    let fixedLineHeight = style.lineHeightPx ?? ((style.lineHeight ?? 0) * style.fontSize)
    let lineBoxHeight = fixedLineHeight > 0 ? fixedLineHeight : naturalLineHeight
    let baselineOffset = fixedLineHeight > 0 ? ascent + (fixedLineHeight - ascent - descent) / 2 : ascent
    let verticalOffset = max(0, (item.frame.height - lineBoxHeight) / 2)
    let baselineY = item.frame.y + verticalOffset + baselineOffset
    let baselineX = item.frame.x + CTLineGetPenOffsetForFlush(line, 0.5, item.frame.width)

    let runs = (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).map { run -> [String: Any] in
        let count = CTRunGetGlyphCount(run)
        var glyphs = Array(repeating: CGGlyph(), count: count)
        var advances = Array(repeating: CGSize.zero, count: count)
        var indices = Array(repeating: 0, count: count)
        CTRunGetGlyphs(run, CFRange(), &glyphs)
        CTRunGetAdvances(run, CFRange(), &advances)
        CTRunGetStringIndices(run, CFRange(), &indices)
        return [
            "range": ["location": CTRunGetStringRange(run).location, "length": CTRunGetStringRange(run).length],
            "advance": round3(advances.reduce(0) { $0 + $1.width }),
            "glyphs": glyphs.indices.map { index in
                ["stringIndex": indices[index], "glyph": Int(glyphs[index]), "glyphName": CTFontCopyNameForGlyph(font, glyphs[index]) as String? ?? NSNull(), "advance": round3(advances[index].width)] as [String: Any]
            }
        ]
    }
    let traits = CTFontCopyTraits(font) as NSDictionary
    let shadows: Any = style.textShadows?.map { ["offsetX": $0.offsetX, "offsetY": $0.offsetY, "blurRadius": $0.blurRadius, "color": $0.color] as [String: Any] } ?? NSNull()
    let firstShadow: Any = style.textShadows?.first.map { ["offsetX": $0.offsetX, "offsetY": $0.offsetY, "blurRadius": $0.blurRadius, "color": $0.color] as [String: Any] } ?? NSNull()
    let input: [String: Any] = [
        "fontFamily": style.fontFamily, "fontPostScriptName": style.fontPostScriptName ?? NSNull(),
        "fontSize": style.fontSize, "fontWeight": style.fontWeight, "fontStyle": style.fontStyle ?? NSNull(),
        "letterSpacing": style.letterSpacing, "wordSpacing": style.wordSpacing,
        "lineHeight": style.lineHeight ?? NSNull(), "lineHeightPx": style.lineHeightPx ?? NSNull(),
        "textShadows": shadows, "textStrokeWidth": style.textStrokeWidth ?? NSNull(),
        "textStrokeColor": style.textStrokeColor ?? NSNull(), "textTransform": style.textTransform ?? NSNull(), "color": style.color
    ]
    let fontReport: [String: Any] = [
        "postScriptName": CTFontCopyPostScriptName(font) as String, "fullName": CTFontCopyFullName(font) as String,
        "familyName": CTFontCopyFamilyName(font) as String, "styleName": CTFontCopyName(font, kCTFontStyleNameKey) as String? ?? "",
        "size": round3(CTFontGetSize(font)), "symbolicTraits": CTFontGetSymbolicTraits(font).rawValue,
        "normalizedWeightTrait": (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? NSNull(),
        "variation": CTFontCopyVariation(font).map { String(describing: $0) } ?? NSNull()
    ]
    let translation: [String: Any] = [
        "kernAttributePresent": attributes[NSAttributedString.Key(kCTKernAttributeName as String)] != nil,
        "wordSpacingApplied": abs(style.wordSpacing) > .ulpOfOne,
        "strokeAttributePresent": attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] != nil,
        "shadowApplied": style.textShadows?.isEmpty == false, "shadow": firstShadow
    ]
    let metrics: [String: Any] = [
        "advance": round3(advance), "ascent": round3(ascent), "descent": round3(descent), "leading": round3(leading),
        "naturalLineHeight": round3(naturalLineHeight), "lineBoxHeight": round3(lineBoxHeight),
        "baselineX": round3(baselineX), "baselineY": round3(baselineY), "runs": runs
    ]
    reports.append(["text": entry.text, "itemId": item.id, "input": input, "font": fontReport, "translation": translation, "metrics": metrics, "coordinateModel": ["canvasPixelsPerPoint": 1, "externalDisplayBackingScale": 1]])
}

let output: [String: Any] = ["generatedAt": ISO8601DateFormatter().string(from: Date()), "items": reports]
let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
let outputURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCRIM_TRACE_CORETEXT_OUTPUT"] ?? "Artifacts/live-typography-coretext.json")
try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try data.write(to: outputURL)
print(outputURL.path)
