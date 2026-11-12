import CoreText
import Foundation
import Testing

@testable import ScrimCore

private struct FidelityFixtureFile: Decodable {
  let fontFamily: String
  let lineHeight: Double
  let fixtures: [FidelityFixture]
}

private struct FidelityFixture: Decodable {
  struct Frame: Decodable {
    let width: Double
    let height: Double
  }

  let id: String
  let purpose: String
  let frame: Frame
  let paragraphs: [String]
  let fontSize: Double
  let fontWeight: Int
  let textFit: String
}

private struct ChromiumReport: Decodable {
  struct Engine: Decodable {
    let userAgent: String
    let devicePixelRatio: Double
  }

  struct Fixture: Decodable {
    struct ComputedStyle: Decodable {
      let fontFamily: String
      let fontSize: String
      let fontWeight: String
      let fontStyle: String
      let fontStretch: String
      let fontKerning: String
      let fontFeatureSettings: String
      let fontVariationSettings: String
      let lineHeight: String
      let letterSpacing: String
      let wordSpacing: String
      let whiteSpace: String
      let overflowWrap: String
      let textWrap: String
      let textAlign: String
    }

    struct PlatformFont: Decodable {
      let familyName: String
      let postScriptName: String
      let isCustomFont: Bool
      let glyphCount: Int
    }

    struct VisibleLine: Decodable {
      let paragraphIndex: Int
      let y: Double
      let height: Double
      let text: String
      let width: Double
    }

    struct WidthHypothesis: Decodable {
      let text: String
      let kerningAutoLetterSpacingNormal: Double
      let kerningAutoLetterSpacingZero: Double
      let kerningNoneLetterSpacingZero: Double
    }

    struct Boxes: Decodable {
      struct Box: Decodable {
        let width: Double
        let height: Double
        let clientWidth: Double
        let clientHeight: Double
        let scrollWidth: Double
        let scrollHeight: Double
      }

      let item: Box
      let align: Box
      let lines: Box
      let breaks: [Box]
    }

    let id: String
    let resolvedFontSize: Double
    let computedStyle: ComputedStyle
    let boxes: Boxes
    let platformFonts: [PlatformFont]
    let visibleLines: [VisibleLine]
    let widthHypotheses: [WidthHypothesis]
  }

  let engine: Engine
  let fixtures: [Fixture]
}

private struct NativeFidelityReport: Encodable {
  struct Runtime: Encodable {
    let operatingSystem: String
    let architecture: String
    let renderer: String
  }

  struct CoordinateModel: Encodable {
    let sceneUnit: String
    let bitmapScale: Double
    let backingScaleUsedForLayout: Bool
    let note: String
  }

  struct Fixture: Encodable {
    struct Size: Encodable {
      let width: Double
      let height: Double
    }

    struct Font: Encodable {
      let requestedFamily: String
      let requestedWeight: Int
      let postScriptName: String
      let fullName: String
      let familyName: String
      let styleName: String
      let fileURL: String?
      let size: Double
      let symbolicTraits: UInt32
      let normalizedWeightTrait: Double?
      let ascent: Double
      let descent: Double
      let leading: Double
      let capHeight: Double
      let xHeight: Double
      let unitsPerEm: UInt32
      let variation: String?
      let variationAxes: [String]
    }

    struct Glyph: Encodable {
      let glyphID: UInt16
      let glyphName: String?
      let stringIndex: Int
      let positionX: Double
      let positionY: Double
      let advanceWidth: Double
      let advanceHeight: Double
    }

    struct Run: Encodable {
      let rangeLocation: Int
      let rangeLength: Int
      let text: String
      let width: Double
      let postScriptName: String
      let glyphs: [Glyph]
    }

    struct Word: Encodable {
      let rangeLocation: Int
      let rangeLength: Int
      let text: String
      let offsetX: Double
      let width: Double
    }

    struct Line: Encodable {
      let rangeLocation: Int
      let rangeLength: Int
      let text: String
      let visualText: String
      let typographicWidth: Double
      let trailingWhitespaceWidth: Double
      let usedWidth: Double
      let ascent: Double
      let descent: Double
      let leading: Double
      let baselineX: Double
      let baselineY: Double
      let words: [Word]
      let runs: [Run]
    }

    struct ParagraphWidth: Encodable {
      let text: String
      let chromiumKerningAuto: Double
      let chromiumKerningDisabled: Double
      let coreTextKerningAuto: Double
      let coreTextLegacyKernZero: Double
      let autoWidthDelta: Double
    }

    struct Comparison: Encodable {
      let fontFaceMatches: Bool
      let lineBreaksMatch: Bool
      let chromiumLines: [String]
      let coreTextLines: [String]
      let chromiumLineBoxHeight: Double
      let coreTextSuggestedHeight: Double
      let modeledCSSLineBoxHeight: Double
      let heightDelta: Double
      let maximumUnwrappedWidthDelta: Double
    }

    struct LegacyTranslation: Encodable {
      let kernZeroLineCount: Int
      let kernZeroLines: [String]
      let kernZeroSuggestedHeight: Double
      let lineHeightMultipleSuggestedHeight: Double
      let combinedSuggestedHeight: Double
    }

    let id: String
    let purpose: String
    let container: Size
    let insets: [String: Double]
    let resolvedFontSize: Double
    let cssLineHeight: Double
    let paragraphStyle: [String: String]
    let font: Font
    let suggestedSize: Size
    let baselineSteps: [Double]
    let lines: [Line]
    let paragraphWidths: [ParagraphWidth]
    let comparison: Comparison
    let legacyTranslation: LegacyTranslation
  }

  let generatedAt: String
  let chromiumUserAgent: String
  let chromiumDevicePixelRatio: Double
  let runtime: Runtime
  let coordinateModel: CoordinateModel
  let fixtures: [Fixture]
}

@Test func textFidelityMatrixIsGeneratedFromSharedFixtures() throws {
  let scrimRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let fixtureFile = try JSONDecoder().decode(
    FidelityFixtureFile.self,
    from: Data(contentsOf: scrimRoot.appending(path: "Fixtures/text-fidelity-fixtures.json"))
  )
  let chromium = try JSONDecoder().decode(
    ChromiumReport.self,
    from: Data(contentsOf: scrimRoot.appending(path: "Artifacts/chromium-fidelity.json"))
  )
  let chromiumByID = Dictionary(uniqueKeysWithValues: chromium.fixtures.map { ($0.id, $0) })
  let renderer = SceneRenderer()
  let nativeFixtures = try fixtureFile.fixtures.map { fixture -> NativeFidelityReport.Fixture in
    let browser = try #require(chromiumByID[fixture.id])
    return inspect(
      fixture: fixture, browser: browser, fontFamily: fixtureFile.fontFamily,
      lineHeight: fixtureFile.lineHeight, renderer: renderer)
  }

  let existing = try #require(nativeFixtures.first { $0.id == "shrink-near-wrap-bold" })
  #expect(existing.font.postScriptName == "HelveticaNeue-Bold")
  #expect(existing.legacyTranslation.kernZeroLineCount == 4)
  #expect(existing.comparison.coreTextLines.count == 3)
  #expect(existing.legacyTranslation.lineHeightMultipleSuggestedHeight >= 450)
  #expect(existing.legacyTranslation.combinedSuggestedHeight >= 600)
  #expect(existing.comparison.coreTextSuggestedHeight <= 384)
  #expect(existing.comparison.maximumUnwrappedWidthDelta < 0.1)
  #expect(
    existing.comparison.chromiumLines == [
      "Great is Your faithfulness", "Morning by morning", "new mercies I see",
    ])
  #expect(
    existing.comparison.coreTextLines == [
      "Great is Your faithfulness", "Morning by morning new", "mercies I see",
    ])

  let controls = nativeFixtures.filter {
    ["single-line-regular", "manual-break-regular", "weight-regular", "weight-bold"].contains($0.id)
  }
  #expect(controls.allSatisfy { $0.comparison.fontFaceMatches })
  #expect(controls.allSatisfy { $0.comparison.lineBreaksMatch })
  #expect(controls.allSatisfy { $0.comparison.maximumUnwrappedWidthDelta < 0.1 })

  let report = NativeFidelityReport(
    generatedAt: ISO8601DateFormatter().string(from: Date()),
    chromiumUserAgent: chromium.engine.userAgent,
    chromiumDevicePixelRatio: chromium.engine.devicePixelRatio,
    runtime: .init(
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      architecture: architectureName(),
      renderer: "CoreText/CoreGraphics"
    ),
    coordinateModel: .init(
      sceneUnit: "pixel",
      bitmapScale: 1,
      backingScaleUsedForLayout: false,
      note:
        "Scrim lays out into a 1920x1080 bitmap CGContext. One Core Graphics user-space unit maps to one scene pixel; the output view backing scale is applied only when the completed image is displayed."
    ),
    fixtures: nativeFixtures
  )
  if let outputPath = ProcessInfo.processInfo.environment["SCRIM_FIDELITY_OUTPUT"],
    !outputPath.isEmpty
  {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(report)
    data.append(0x0A)
    try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
  }
}

private func inspect(
  fixture: FidelityFixture,
  browser: ChromiumReport.Fixture,
  fontFamily: String,
  lineHeight: Double,
  renderer: SceneRenderer
) -> NativeFidelityReport.Fixture {
  let style = FlywireTextStyle(
    fontFamily: fontFamily,
    fontSize: browser.resolvedFontSize,
    fontWeight: fixture.fontWeight,
    italic: false,
    color: "#ffffff",
    underline: false,
    letterSpacing: 0,
    wordSpacing: 0,
    lineHeight: lineHeight
  )
  let text = fixture.paragraphs.joined(separator: "\n")
  let item = FlywireTextItem(
    id: fixture.id,
    kind: "text",
    frame: .init(x: 0, y: 0, width: fixture.frame.width, height: fixture.frame.height),
    text: text,
    runs: [.init(text: text, style: style)],
    textAlign: "center",
    verticalAlign: "center",
    opacity: 1,
    backgroundColor: nil,
    textFit: fixture.textFit,
    chromiumFontSize: browser.resolvedFontSize
  )

  let attributed =
    renderer.attributedString(for: item, fontScale: renderer.resolvedFontScale(for: item))
    as NSAttributedString
  let layout = createLayout(
    attributed: attributed, width: fixture.frame.width, height: fixture.frame.height)
  let font =
    attributed.attribute(
      NSAttributedString.Key(kCTFontAttributeName as String), at: 0, effectiveRange: nil) as! CTFont
  let lineDiagnostics = inspectLines(
    layout.lines, origins: layout.origins, source: attributed, fallbackFont: font)
  let coreLines = lineDiagnostics.map(\.visualText)
  let chromiumLines = browser.visibleLines.map(\.text)
  let paragraphMeasurements = measureParagraphs(
    fixture.paragraphs, attributed: attributed, browser: browser)

  let legacyKern = NSMutableAttributedString(attributedString: attributed)
  legacyKern.addAttribute(
    NSAttributedString.Key(kCTKernAttributeName as String), value: 0,
    range: NSRange(location: 0, length: legacyKern.length))
  let legacyKernLayout = createLayout(
    attributed: legacyKern, width: fixture.frame.width, height: fixture.frame.height)
  let legacyKernLines = lineStrings(legacyKernLayout.lines, source: legacyKern)

  let legacyLineHeight = NSMutableAttributedString(attributedString: attributed)
  var alignment = CTTextAlignment.center
  var lineHeightMultiple = CGFloat(lineHeight)
  let legacyParagraph = withUnsafeBytes(of: &alignment) { alignmentBytes in
    withUnsafeBytes(of: &lineHeightMultiple) { lineHeightBytes in
      var settings = [
        CTParagraphStyleSetting(
          spec: .alignment, valueSize: alignmentBytes.count, value: alignmentBytes.baseAddress!),
        CTParagraphStyleSetting(
          spec: .lineHeightMultiple, valueSize: lineHeightBytes.count,
          value: lineHeightBytes.baseAddress!),
      ]
      return CTParagraphStyleCreate(&settings, settings.count)
    }
  }
  legacyLineHeight.addAttribute(
    NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: legacyParagraph,
    range: NSRange(location: 0, length: legacyLineHeight.length))
  let legacyLineHeightLayout = createLayout(
    attributed: legacyLineHeight, width: fixture.frame.width, height: fixture.frame.height)
  let legacyCombined = NSMutableAttributedString(attributedString: legacyKern)
  legacyCombined.addAttribute(
    NSAttributedString.Key(kCTParagraphStyleAttributeName as String), value: legacyParagraph,
    range: NSRange(location: 0, length: legacyCombined.length))
  let legacyCombinedLayout = createLayout(
    attributed: legacyCombined, width: fixture.frame.width, height: fixture.frame.height)

  let fontURL = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL
  let traits = CTFontCopyTraits(font) as NSDictionary
  let normalizedWeight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue
  let variation = CTFontCopyVariation(font).map { String(describing: $0) }
  let axes = (CTFontCopyVariationAxes(font) as? [NSDictionary] ?? []).map { String(describing: $0) }
  let cssLineHeight = browser.resolvedFontSize * lineHeight
  let baselineSteps = zip(layout.origins, layout.origins.dropFirst()).map { Double($0.y - $1.y) }
  let maxWidthDelta = paragraphMeasurements.map { abs($0.autoWidthDelta) }.max() ?? 0
  let expectedPostScriptNames = Set(browser.platformFonts.map(\.postScriptName))

  return .init(
    id: fixture.id,
    purpose: fixture.purpose,
    container: .init(width: fixture.frame.width, height: fixture.frame.height),
    insets: ["top": 0, "right": 0, "bottom": 0, "left": 0],
    resolvedFontSize: browser.resolvedFontSize,
    cssLineHeight: cssLineHeight,
    paragraphStyle: [
      "alignment": "center",
      "lineBreak": "CoreText default greedy word wrapping",
      "minimumLineHeight": String(cssLineHeight),
      "maximumLineHeight": String(cssLineHeight),
      "lineSpacingAdjustment": String(-CTFontGetLeading(font).rounded()),
      "whiteSpaceInput": "explicit FreeShow line blocks joined by newline",
    ],
    font: .init(
      requestedFamily: fontFamily,
      requestedWeight: fixture.fontWeight,
      postScriptName: CTFontCopyPostScriptName(font) as String,
      fullName: CTFontCopyFullName(font) as String,
      familyName: CTFontCopyFamilyName(font) as String,
      styleName: (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? "",
      fileURL: fontURL?.path,
      size: CTFontGetSize(font),
      symbolicTraits: CTFontGetSymbolicTraits(font).rawValue,
      normalizedWeightTrait: normalizedWeight,
      ascent: CTFontGetAscent(font),
      descent: CTFontGetDescent(font),
      leading: CTFontGetLeading(font),
      capHeight: CTFontGetCapHeight(font),
      xHeight: CTFontGetXHeight(font),
      unitsPerEm: CTFontGetUnitsPerEm(font),
      variation: variation,
      variationAxes: axes
    ),
    suggestedSize: .init(width: layout.suggested.width, height: layout.suggested.height),
    baselineSteps: baselineSteps,
    lines: lineDiagnostics,
    paragraphWidths: paragraphMeasurements,
    comparison: .init(
      fontFaceMatches: expectedPostScriptNames == [CTFontCopyPostScriptName(font) as String],
      lineBreaksMatch: chromiumLines == coreLines,
      chromiumLines: chromiumLines,
      coreTextLines: coreLines,
      chromiumLineBoxHeight: browser.boxes.lines.height,
      coreTextSuggestedHeight: layout.suggested.height,
      modeledCSSLineBoxHeight: Double(coreLines.count) * cssLineHeight,
      heightDelta: layout.suggested.height - browser.boxes.lines.height,
      maximumUnwrappedWidthDelta: maxWidthDelta
    ),
    legacyTranslation: .init(
      kernZeroLineCount: legacyKernLines.count,
      kernZeroLines: legacyKernLines,
      kernZeroSuggestedHeight: legacyKernLayout.suggested.height,
      lineHeightMultipleSuggestedHeight: legacyLineHeightLayout.suggested.height,
      combinedSuggestedHeight: legacyCombinedLayout.suggested.height
    )
  )
}

private struct LayoutResult {
  let suggested: CGSize
  let lines: [CTLine]
  let origins: [CGPoint]
}

private func createLayout(attributed: NSAttributedString, width: Double, height: Double)
  -> LayoutResult
{
  let framesetter = CTFramesetterCreateWithAttributedString(attributed)
  let constraint = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
  let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
    framesetter, CFRange(), nil, constraint, nil)
  let path = CGPath(
    rect: CGRect(x: 0, y: 0, width: width, height: max(height, suggested.height)), transform: nil)
  let frame = CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
  let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
  var origins = Array(repeating: CGPoint.zero, count: lines.count)
  CTFrameGetLineOrigins(frame, CFRange(), &origins)
  return LayoutResult(suggested: suggested, lines: lines, origins: origins)
}

private func inspectLines(
  _ lines: [CTLine],
  origins: [CGPoint],
  source: NSAttributedString,
  fallbackFont: CTFont
) -> [NativeFidelityReport.Fixture.Line] {
  let sourceString = source.string as NSString
  return lines.enumerated().map { index, line in
    let range = CTLineGetStringRange(line)
    let nsRange = NSRange(location: range.location, length: range.length)
    let text = sourceString.substring(with: nsRange)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    let trailing = CTLineGetTrailingWhitespaceWidth(line)
    let words = wordDiagnostics(line: line, range: nsRange, source: sourceString)
    let runs = (CTLineGetGlyphRuns(line) as? [CTRun] ?? []).map {
      runDiagnostics(run: $0, source: sourceString, fallbackFont: fallbackFont)
    }
    return .init(
      rangeLocation: range.location,
      rangeLength: range.length,
      text: text.replacingOccurrences(of: "\n", with: "\\n"),
      visualText: text.trimmingCharacters(in: .whitespacesAndNewlines),
      typographicWidth: width,
      trailingWhitespaceWidth: trailing,
      usedWidth: width - trailing,
      ascent: ascent,
      descent: descent,
      leading: leading,
      baselineX: origins[index].x,
      baselineY: origins[index].y,
      words: words,
      runs: runs
    )
  }
}

private func wordDiagnostics(line: CTLine, range: NSRange, source: NSString)
  -> [NativeFidelityReport.Fixture.Word]
{
  let lineText = source.substring(with: range) as NSString
  let regex = try! NSRegularExpression(pattern: #"\S+"#)
  return regex.matches(in: lineText as String, range: NSRange(location: 0, length: lineText.length))
    .map { match in
      let globalStart = range.location + match.range.location
      let globalEnd = globalStart + match.range.length
      let start = CTLineGetOffsetForStringIndex(line, globalStart, nil)
      let end = CTLineGetOffsetForStringIndex(line, globalEnd, nil)
      return .init(
        rangeLocation: globalStart,
        rangeLength: match.range.length,
        text: lineText.substring(with: match.range),
        offsetX: start,
        width: abs(end - start)
      )
    }
}

private func runDiagnostics(
  run: CTRun,
  source: NSString,
  fallbackFont: CTFont
) -> NativeFidelityReport.Fixture.Run {
  let range = CTRunGetStringRange(run)
  let count = CTRunGetGlyphCount(run)
  var glyphs = Array(repeating: CGGlyph(), count: count)
  var positions = Array(repeating: CGPoint.zero, count: count)
  var advances = Array(repeating: CGSize.zero, count: count)
  var stringIndices = Array(repeating: 0, count: count)
  CTRunGetGlyphs(run, CFRange(), &glyphs)
  CTRunGetPositions(run, CFRange(), &positions)
  CTRunGetAdvances(run, CFRange(), &advances)
  CTRunGetStringIndices(run, CFRange(), &stringIndices)
  let attributes = CTRunGetAttributes(run) as NSDictionary
  let font = (attributes[kCTFontAttributeName as String] as! CTFont?) ?? fallbackFont
  var ascent: CGFloat = 0
  var descent: CGFloat = 0
  var leading: CGFloat = 0
  let width = CTRunGetTypographicBounds(run, CFRange(), &ascent, &descent, &leading)
  let glyphDiagnostics = glyphs.indices.map { index in
    NativeFidelityReport.Fixture.Glyph(
      glyphID: glyphs[index],
      glyphName: CTFontCopyNameForGlyph(font, glyphs[index]) as String?,
      stringIndex: stringIndices[index],
      positionX: positions[index].x,
      positionY: positions[index].y,
      advanceWidth: advances[index].width,
      advanceHeight: advances[index].height
    )
  }
  return .init(
    rangeLocation: range.location,
    rangeLength: range.length,
    text: source.substring(with: NSRange(location: range.location, length: range.length))
      .replacingOccurrences(of: "\n", with: "\\n"),
    width: width,
    postScriptName: CTFontCopyPostScriptName(font) as String,
    glyphs: glyphDiagnostics
  )
}

private func measureParagraphs(
  _ paragraphs: [String],
  attributed: NSAttributedString,
  browser: ChromiumReport.Fixture
) -> [NativeFidelityReport.Fixture.ParagraphWidth] {
  var location = 0
  return paragraphs.enumerated().map { index, paragraph in
    let range = NSRange(location: location, length: (paragraph as NSString).length)
    location += range.length + (index < paragraphs.count - 1 ? 1 : 0)
    let substring = attributed.attributedSubstring(from: range)
    let coreTextWidth = CTLineGetTypographicBounds(
      CTLineCreateWithAttributedString(substring), nil, nil, nil)
    let legacy = NSMutableAttributedString(attributedString: substring)
    legacy.addAttribute(
      NSAttributedString.Key(kCTKernAttributeName as String), value: 0,
      range: NSRange(location: 0, length: legacy.length))
    let legacyWidth = CTLineGetTypographicBounds(
      CTLineCreateWithAttributedString(legacy), nil, nil, nil)
    let browserWidth = browser.widthHypotheses[index]
    return .init(
      text: paragraph,
      chromiumKerningAuto: browserWidth.kerningAutoLetterSpacingNormal,
      chromiumKerningDisabled: browserWidth.kerningNoneLetterSpacingZero,
      coreTextKerningAuto: coreTextWidth,
      coreTextLegacyKernZero: legacyWidth,
      autoWidthDelta: coreTextWidth - browserWidth.kerningAutoLetterSpacingNormal
    )
  }
}

private func lineStrings(_ lines: [CTLine], source: NSAttributedString) -> [String] {
  let value = source.string as NSString
  return lines.map { line in
    let range = CTLineGetStringRange(line)
    return value.substring(with: NSRange(location: range.location, length: range.length))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private func architectureName() -> String {
  #if arch(arm64)
    "arm64"
  #elseif arch(x86_64)
    "x86_64"
  #else
    "unknown"
  #endif
}
