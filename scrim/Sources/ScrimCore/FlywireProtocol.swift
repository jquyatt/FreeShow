import Foundation

public let flywireProtocolVersion = 1

public struct FlywireSize: Codable, Equatable, Sendable {
    public let width: Double
    public let height: Double
}

public struct FlywireRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct FlywireAssetRef: Codable, Equatable, Sendable {
    public let assetId: String
    public let kind: String
    public let url: String
    public let muted: Bool?
    public let loop: Bool?
}

/// FreeShow's authoritative audio-clock state for one published video scene.
public struct FlywireVideoPlaybackState: Codable, Equatable, Sendable {
    public let outputId: String
    public let sceneId: String
    public let assetId: String
    public let positionSeconds: Double
    public let durationSeconds: Double
    public let paused: Bool
    public let loop: Bool
    public let clearOnEnd: Bool
    public let playbackRate: Double
    public let sentAt: Double

    public init(
        outputId: String,
        sceneId: String,
        assetId: String,
        positionSeconds: Double,
        durationSeconds: Double,
        paused: Bool,
        loop: Bool,
        clearOnEnd: Bool,
        playbackRate: Double,
        sentAt: Double
    ) {
        self.outputId = outputId
        self.sceneId = sceneId
        self.assetId = assetId
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.paused = paused
        self.loop = loop
        self.clearOnEnd = clearOnEnd
        self.playbackRate = playbackRate
        self.sentAt = sentAt
    }

    public var isValid: Bool {
        !outputId.isEmpty && !sceneId.isEmpty && !assetId.isEmpty &&
            positionSeconds.isFinite && positionSeconds >= 0 &&
            durationSeconds.isFinite && durationSeconds >= 0 &&
            playbackRate.isFinite && playbackRate > 0 && sentAt.isFinite
    }

    public func targetPosition(at nowMilliseconds: Double) -> Double {
        let elapsed = paused ? 0 : max(0, nowMilliseconds - sentAt) / 1_000 * playbackRate
        let target = max(0, positionSeconds + elapsed)
        return durationSeconds > 0 ? min(target, durationSeconds) : target
    }

    public func isExplicitSeek(from previous: FlywireVideoPlaybackState?) -> Bool {
        guard let previous, previous.sceneId == sceneId, sentAt >= previous.sentAt else { return true }
        let elapsed = previous.paused ? 0 : (sentAt - previous.sentAt) / 1_000 * previous.playbackRate
        let expected = previous.positionSeconds + elapsed
        return abs(positionSeconds - expected) > 0.5 * playbackRate
    }
}

public struct FlywireBackground: Codable, Equatable, Sendable {
    public let color: String
    public let image: FlywireAssetRef?
    public let video: FlywireAssetRef?
    public var live: FlywireLiveSourceRef? = nil
}

public struct FlywireLiveSourceRef: Codable, Equatable, Sendable {
    public let kind: String
    public let sourceId: String
    public let target: String
    public let nativeId: UInt32
    public let fit: String
    public let crop: FlywireRect?
    public let showsCursor: Bool
    public let muted: Bool

    public init(kind: String = "screenCapture", sourceId: String, target: String, nativeId: UInt32,
                fit: String = "fill", crop: FlywireRect? = nil, showsCursor: Bool = true, muted: Bool = true) {
        self.kind = kind
        self.sourceId = sourceId
        self.target = target
        self.nativeId = nativeId
        self.fit = fit
        self.crop = crop
        self.showsCursor = showsCursor
        self.muted = muted
    }

    public func validate() throws {
        guard kind == "screenCapture", ["display", "window"].contains(target), nativeId > 0,
              sourceId.hasPrefix(target == "display" ? "screen:" : "window:"),
              ["contain", "cover", "fill"].contains(fit), muted else {
            throw FlywireProtocolError.invalidBackground(reason: "invalid live capture descriptor")
        }
        if let crop {
            guard [crop.x, crop.y, crop.width, crop.height].allSatisfy(\.isFinite),
                  crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0,
                  crop.x + crop.width <= 1, crop.y + crop.height <= 1 else {
                throw FlywireProtocolError.invalidBackground(reason: "invalid normalized capture crop")
            }
        }
    }

    /// Presentation fit/crop do not require a second capture of the same source.
    public var captureKey: String { "\(kind):\(target):\(nativeId):cursor=\(showsCursor)" }
}

public struct FlywireTextShadow: Codable, Equatable, Sendable {
    public let offsetX: Double
    public let offsetY: Double
    public let blurRadius: Double
    public let color: String

    public init(offsetX: Double, offsetY: Double, blurRadius: Double, color: String) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.blurRadius = blurRadius
        self.color = color
    }
}

public struct FlywireTextStyle: Codable, Equatable, Sendable {
    public let fontFamily: String
    public let fontPostScriptName: String?
    public let fontSize: Double
    public let fontWeight: Int
    public let fontStyle: String?
    public let italic: Bool
    public let color: String
    public let underline: Bool
    public let letterSpacing: Double
    public let wordSpacing: Double
    public let lineHeight: Double?
    public let lineHeightPx: Double?
    public let textShadows: [FlywireTextShadow]?
    public let textStrokeWidth: Double?
    public let textStrokeColor: String?
    public let textTransform: String?

    public init(
        fontFamily: String,
        fontPostScriptName: String? = nil,
        fontSize: Double,
        fontWeight: Int,
        fontStyle: String? = nil,
        italic: Bool,
        color: String,
        underline: Bool,
        letterSpacing: Double,
        wordSpacing: Double,
        lineHeight: Double? = nil,
        lineHeightPx: Double? = nil,
        textShadows: [FlywireTextShadow]? = nil,
        textStrokeWidth: Double? = nil,
        textStrokeColor: String? = nil,
        textTransform: String? = nil
    ) {
        self.fontFamily = fontFamily
        self.fontPostScriptName = fontPostScriptName
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.fontStyle = fontStyle
        self.italic = italic
        self.color = color
        self.underline = underline
        self.letterSpacing = letterSpacing
        self.wordSpacing = wordSpacing
        self.lineHeight = lineHeight
        self.lineHeightPx = lineHeightPx
        self.textShadows = textShadows
        self.textStrokeWidth = textStrokeWidth
        self.textStrokeColor = textStrokeColor
        self.textTransform = textTransform
    }
}

public struct FlywireTextRun: Codable, Equatable, Sendable {
    public let text: String
    public let style: FlywireTextStyle
}

/// A half-open UTF-16 range into `FlywireTextItem.text`.
public struct FlywireTextLineRange: Codable, Equatable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public struct FlywireTextItem: Codable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let frame: FlywireRect
    public let text: String
    public let runs: [FlywireTextRun]
    public let visualLines: [FlywireTextLineRange]?
    public let textAlign: String
    public let verticalAlign: String
    public let opacity: Double
    public let backgroundColor: String?
    public let textFit: String
    public let chromiumFontSize: Double?

    public init(
        id: String,
        kind: String,
        frame: FlywireRect,
        text: String,
        runs: [FlywireTextRun],
        visualLines: [FlywireTextLineRange]? = nil,
        textAlign: String,
        verticalAlign: String,
        opacity: Double,
        backgroundColor: String?,
        textFit: String,
        chromiumFontSize: Double?
    ) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.text = text
        self.runs = runs
        self.visualLines = visualLines
        self.textAlign = textAlign
        self.verticalAlign = verticalAlign
        self.opacity = opacity
        self.backgroundColor = backgroundColor
        self.textFit = textFit
        self.chromiumFontSize = chromiumFontSize
    }
}

public struct FlywireUnsupportedContent: Codable, Equatable, Sendable {
    public let kind: String
    public let id: String?
    public let reason: String
}

public struct FlywireTransition: Codable, Equatable, Sendable {
    public let type: String
    public let durationMs: Double
    public let easing: String
}

public struct FlywireSceneTransitions: Codable, Equatable, Sendable {
    public let media: FlywireTransition
    public let text: FlywireTransition
}

public struct FlywireSource: Codable, Equatable, Sendable {
    public let showId: String?
    public let layoutId: String?
    public let slideIndex: Int?
    public let slideId: String?
}

public struct FlywireScene: Codable, Equatable, Sendable {
    public let id: String
    public let outputId: String
    public let canvas: FlywireSize
    public let background: FlywireBackground
    public let items: [FlywireTextItem]
    public let transition: FlywireSceneTransitions
    public let unsupported: [FlywireUnsupportedContent]
    public let source: FlywireSource
}

public struct FlywireSceneEnvelope: Codable, Equatable, Sendable {
    public let `protocol`: String
    public let version: Int
    public let type: String
    public let sequence: Int
    public let sentAt: Double
    public let scene: FlywireScene

    public func validate() throws {
        guard `protocol` == "flywire", version == flywireProtocolVersion, type == "scene" else {
            throw FlywireProtocolError.unsupportedEnvelope(protocolName: `protocol`, version: version, type: type)
        }
        if let video = scene.background.video, video.kind != "video" {
            throw FlywireProtocolError.invalidBackground(reason: "video background asset kind is '\(video.kind)'")
        }
        if let image = scene.background.image, image.kind != "image" {
            throw FlywireProtocolError.invalidBackground(reason: "image background asset kind is '\(image.kind)'")
        }
        if let live = scene.background.live {
            try live.validate()
            guard scene.background.image == nil, scene.background.video == nil else {
                throw FlywireProtocolError.invalidBackground(reason: "live and file backgrounds are mutually exclusive")
            }
        }
        for (layer, transition) in [("media", scene.transition.media), ("text", scene.transition.text)] {
            guard ["cut", "fade"].contains(transition.type), transition.durationMs.isFinite, transition.durationMs >= 0 else {
                throw FlywireProtocolError.invalidTransition(layer: layer, reason: "invalid type or duration")
            }
            guard ["linear", "back", "sine", "circ", "cubic", "elastic", "bounce"].contains(transition.easing) else {
                throw FlywireProtocolError.invalidTransition(layer: layer, reason: "unsupported easing '\(transition.easing)'")
            }
        }
        for item in scene.items {
            if item.visualLines != nil {
                guard item.runs.map(\.text).joined() == item.text else {
                    throw FlywireProtocolError.invalidTextLayout(itemId: item.id, reason: "run text does not concatenate to item text")
                }
                guard item.validatedVisualLineRanges != nil else {
                    throw FlywireProtocolError.invalidTextLayout(itemId: item.id, reason: "visual lines are not ordered, covering UTF-16 ranges")
                }
            }
        }
    }
}

public enum FlywireProtocolError: Error, Equatable {
    case unsupportedEnvelope(protocolName: String, version: Int, type: String)
    case invalidBackground(reason: String)
    case invalidTransition(layer: String, reason: String)
    case invalidTextLayout(itemId: String, reason: String)
    case invalidVideoPlayback(reason: String)
}

extension FlywireTextItem {
    var validatedVisualLineRanges: [NSRange]? {
        guard let visualLines, !visualLines.isEmpty else { return nil }
        let source = text as NSString
        var previousEnd = 0
        var result: [NSRange] = []

        for line in visualLines {
            let range = NSRange(location: line.location, length: line.length)
            guard range.location >= previousEnd, range.length >= 0, NSMaxRange(range) <= source.length,
                  Range(range, in: text) != nil,
                  !source.substring(with: range).contains("\n")
            else { return nil }

            let gap = NSRange(location: previousEnd, length: range.location - previousEnd)
            guard source.substring(with: gap).allSatisfy({ $0 == "\n" }) else { return nil }
            result.append(range)
            previousEnd = NSMaxRange(range)
        }

        let tail = NSRange(location: previousEnd, length: source.length - previousEnd)
        guard source.substring(with: tail).allSatisfy({ $0 == "\n" }) else { return nil }
        return result
    }
}
