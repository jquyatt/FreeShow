import CoreText
import Foundation
import Testing

@testable import ScrimCore

private struct ForcedFixtureFile: Decodable {
  struct Fixture: Decodable {
    struct Frame: Decodable { let width: Double; let height: Double }
    struct Run: Decodable {
      let text: String
      let fontWeight: Int
      let italic: Bool?
      let letterSpacing: Double?
      let wordSpacing: Double?
    }
    let id: String
    let purpose: String
    let frame: Frame
    let fontSize: Double
    let textFit: String
    let alignment: String
    let runs: [Run]
  }
  let fontFamily: String
  let lineHeight: Double
  let fixtures: [Fixture]
}

private struct ForcedChromiumReport: Decodable {
  struct Engine: Decodable {
    let userAgent: String
    let devicePixelRatio: Double
  }
  struct Fixture: Decodable {
    struct Range: Decodable { let location: Int; let length: Int }
    struct Bounds: Decodable { let x: Double; let y: Double; let width: Double; let height: Double }
    struct PlatformFont: Decodable { let postScriptName: String }
    struct Line: Decodable {
      struct RunAdvance: Decodable {
        let runIndex: Int
        let range: Range
        let advance: Double
      }
      let range: Range
      let text: String
      let x: Double
      let width: Double
      let baselineY: Double
      let runAdvances: [RunAdvance]
    }
    struct Grapheme: Decodable {
      let location: Int
      let length: Int
      let text: String
      let runIndex: Int
      let width: Double
    }
    let id: String
    let text: String
    let resolvedFontSize: Double
    let blockBounds: Bounds
    let visualLines: [Line]
    let graphemeAdvances: [Grapheme]
    let platformFonts: [PlatformFont]
  }
  let engine: Engine
  let fixtures: [Fixture]
}

private struct ForcedNativeReport: Encodable {
  struct Runtime: Encodable {
    let operatingSystem: String
    let architecture: String
    let renderer: String
  }
  struct Fixture: Encodable {
    struct Range: Encodable { let location: Int; let length: Int }
    struct Glyph: Encodable { let stringIndex: Int; let advance: Double }
    struct Run: Encodable {
      let range: Range
      let advance: Double
      let glyphs: [Glyph]
    }
    struct Line: Encodable {
      let range: Range
      let text: String
      let chromiumWidth: Double
      let coreTextWidth: Double
      let widthDelta: Double
      let chromiumBaselineY: Double
      let coreTextBaselineY: Double
      let baselineDelta: Double
      let chromiumX: Double
      let coreTextX: Double
      let xDelta: Double
      let chromiumRuns: [Run]
      let coreTextRuns: [Run]
      let maximumRunAdvanceDelta: Double
    }
    struct Grapheme: Encodable {
      let range: Range
      let text: String
      let runIndex: Int
      let chromiumAdvance: Double
    }
    let id: String
    let purpose: String
    let lineBreaksMatch: Bool
    let richRunCount: Int
    let chromiumPostScriptNames: [String]
    let coreTextPostScriptNames: [String]
    let fontFacesMatch: Bool
    let chromiumBlockTop: Double
    let coreTextBlockTop: Double
    let blockTopDelta: Double
    let chromiumBlockHeight: Double
    let coreTextBlockHeight: Double
    let blockHeightDelta: Double
    let maximumLineWidthDelta: Double
    let maximumBaselineDelta: Double
    let maximumHorizontalPositionDelta: Double
    let maximumRunAdvanceDelta: Double
    let lines: [Line]
    let chromiumGraphemes: [Grapheme]
  }
  struct Gate: Encodable {
    let passed: Bool
    let lineWidthTolerance: Double
    let baselineTolerance: Double
    let blockTolerance: Double
    let horizontalPositionTolerance: Double
    let runAdvanceTolerance: Double
  }
  let generatedAt: String
  let chromiumUserAgent: String
  let chromiumDevicePixelRatio: Double
  let runtime: Runtime
  let gate: Gate
  let fixtures: [Fixture]
}

@Test func chromiumForcedBreakFidelityMatrix() throws {
  let scrimRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let fixtureFile = try JSONDecoder().decode(
    ForcedFixtureFile.self,
    from: Data(contentsOf: scrimRoot.appending(path: "Fixtures/forced-break-fidelity-fixtures.json")))
  let chromium = try JSONDecoder().decode(
    ForcedChromiumReport.self,
    from: Data(contentsOf: scrimRoot.appending(path: "Artifacts/forced-break-chromium.json")))
  let chromiumByID = Dictionary(uniqueKeysWithValues: chromium.fixtures.map { ($0.id, $0) })
  let renderer = SceneRenderer()

  let results = try fixtureFile.fixtures.map { fixture -> ForcedNativeReport.Fixture in
    let browser = try #require(chromiumByID[fixture.id])
    let text = fixture.runs.map(\.text).joined()
    #expect(text == browser.text)
    let runs = fixture.runs.map { run in
      FlywireTextRun(
        text: run.text,
        style: FlywireTextStyle(
          fontFamily: fixtureFile.fontFamily,
          fontSize: browser.resolvedFontSize,
          fontWeight: run.fontWeight,
          italic: run.italic ?? false,
          color: "#ffffff",
          underline: false,
          letterSpacing: run.letterSpacing ?? 0,
          wordSpacing: run.wordSpacing ?? 0,
          lineHeight: fixtureFile.lineHeight))
    }
    let item = FlywireTextItem(
      id: fixture.id,
      kind: "text",
      frame: .init(x: 0, y: 0, width: fixture.frame.width, height: fixture.frame.height),
      text: text,
      runs: runs,
      visualLines: browser.visualLines.map { .init(location: $0.range.location, length: $0.range.length) },
      textAlign: fixture.alignment,
      verticalAlign: "center",
      opacity: 1,
      backgroundColor: nil,
      textFit: fixture.textFit,
      chromiumFontSize: browser.resolvedFontSize)
    let metrics = renderer.measure(textItem: item)
    let attributed = renderer.attributedString(for: item, fontScale: 1) as NSAttributedString
    var coreTextPostScriptNames = Set<String>()
    attributed.enumerateAttribute(
      NSAttributedString.Key(kCTFontAttributeName as String),
      in: NSRange(location: 0, length: attributed.length)
    ) { value, _, _ in
      if let font = value as! CTFont? {
        coreTextPostScriptNames.insert(CTFontCopyPostScriptName(font) as String)
      }
    }
    let chromiumPostScriptNames = Set(browser.platformFonts.map(\.postScriptName))
    let nativeTop = max(0, (fixture.frame.height - metrics.suggestedSize.height) / 2)
    let nativeLines = zip(browser.visualLines, metrics.lineMetrics).map { browserLine, nativeLine in
      let nativeBaseline = nativeTop + nativeLine.baselineY
      let chromiumRuns = browserLine.runAdvances.map { run in
        ForcedNativeReport.Fixture.Run(
          range: .init(location: run.range.location, length: run.range.length),
          advance: run.advance,
          glyphs: [])
      }
      let coreTextRuns = nativeLine.runAdvances.map { run in
        ForcedNativeReport.Fixture.Run(
          range: .init(location: run.range.location, length: run.range.length),
          advance: run.advance,
          glyphs: run.glyphAdvances.map { .init(stringIndex: $0.stringIndex, advance: $0.advance) })
      }
      let runDeltas = browserLine.runAdvances.compactMap { browserRun -> Double? in
        guard let nativeRun = nativeLine.runAdvances.first(where: {
          $0.range.location == browserRun.range.location && $0.range.length == browserRun.range.length
        }) else { return nil }
        return nativeRun.advance - browserRun.advance
      }
      return ForcedNativeReport.Fixture.Line(
        range: .init(location: nativeLine.range.location, length: nativeLine.range.length),
        text: (text as NSString).substring(with: nativeLine.range),
        chromiumWidth: browserLine.width,
        coreTextWidth: nativeLine.typographicWidth,
        widthDelta: nativeLine.typographicWidth - browserLine.width,
        chromiumBaselineY: browserLine.baselineY,
        coreTextBaselineY: nativeBaseline,
        baselineDelta: nativeBaseline - browserLine.baselineY,
        chromiumX: browserLine.x,
        coreTextX: nativeLine.baselineX,
        xDelta: nativeLine.baselineX - browserLine.x,
        chromiumRuns: chromiumRuns,
        coreTextRuns: coreTextRuns,
        maximumRunAdvanceDelta: runDeltas.map { abs($0) }.max() ?? 0)
    }
    let maxWidthDelta = nativeLines.map { abs($0.widthDelta) }.max() ?? 0
    let maxBaselineDelta = nativeLines.map { abs($0.baselineDelta) }.max() ?? 0
    let maxXDelta = nativeLines.map { abs($0.xDelta) }.max() ?? 0
    let maxRunDelta = nativeLines.map(\.maximumRunAdvanceDelta).max() ?? 0
    let nativeTextLines = metrics.lineMetrics.map { (text as NSString).substring(with: $0.range) }
    let browserTextLines = browser.visualLines.map(\.text)
    return .init(
      id: fixture.id,
      purpose: fixture.purpose,
      lineBreaksMatch: nativeTextLines == browserTextLines,
      richRunCount: fixture.runs.count,
      chromiumPostScriptNames: chromiumPostScriptNames.sorted(),
      coreTextPostScriptNames: coreTextPostScriptNames.sorted(),
      fontFacesMatch: chromiumPostScriptNames == coreTextPostScriptNames,
      chromiumBlockTop: browser.blockBounds.y,
      coreTextBlockTop: nativeTop,
      blockTopDelta: nativeTop - browser.blockBounds.y,
      chromiumBlockHeight: browser.blockBounds.height,
      coreTextBlockHeight: metrics.suggestedSize.height,
      blockHeightDelta: metrics.suggestedSize.height - browser.blockBounds.height,
      maximumLineWidthDelta: maxWidthDelta,
      maximumBaselineDelta: maxBaselineDelta,
      maximumHorizontalPositionDelta: maxXDelta,
      maximumRunAdvanceDelta: maxRunDelta,
      lines: nativeLines,
      chromiumGraphemes: browser.graphemeAdvances.map {
        .init(
          range: .init(location: $0.location, length: $0.length),
          text: $0.text,
          runIndex: $0.runIndex,
          chromiumAdvance: $0.width)
      })
  }

  let gate = ForcedNativeReport.Gate(
    passed: results.allSatisfy {
      $0.lineBreaksMatch && $0.fontFacesMatch && $0.maximumLineWidthDelta < 0.25
        && $0.maximumBaselineDelta < 0.75 && abs($0.blockHeightDelta) < 0.55
        && abs($0.blockTopDelta) < 0.3 && $0.maximumHorizontalPositionDelta < 0.25
        && $0.maximumRunAdvanceDelta < 0.25
    },
    lineWidthTolerance: 0.25,
    baselineTolerance: 0.75,
    blockTolerance: 0.55,
    horizontalPositionTolerance: 0.25,
    runAdvanceTolerance: 0.25)

  #expect(results.count == 10)
  #expect(results.allSatisfy { $0.lineBreaksMatch })
  let rich = try #require(results.first { $0.id == "rich-mixed-weight" })
  #expect(rich.richRunCount == 3)
  #expect(Set(rich.chromiumPostScriptNames) == ["HelveticaNeue", "HelveticaNeue-Bold"])
  #expect(rich.fontFacesMatch)

  let report = ForcedNativeReport(
    generatedAt: ISO8601DateFormatter().string(from: Date()),
    chromiumUserAgent: chromium.engine.userAgent,
    chromiumDevicePixelRatio: chromium.engine.devicePixelRatio,
    runtime: .init(
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      architecture: forcedArchitectureName(),
      renderer: "CoreText/CoreGraphics"),
    gate: gate,
    fixtures: results)
  if let outputPath = ProcessInfo.processInfo.environment["SCRIM_FORCED_FIDELITY_OUTPUT"],
    !outputPath.isEmpty
  {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(report)
    data.append(0x0A)
    try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
  }

  #expect(gate.passed)
}

private func forcedArchitectureName() -> String {
  #if arch(arm64)
    return "arm64"
  #elseif arch(x86_64)
    return "x86_64"
  #else
    return "unknown"
  #endif
}
