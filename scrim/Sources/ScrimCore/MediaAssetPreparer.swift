import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

public enum MediaAssetPreparationError: Error, Equatable, CustomStringConvertible, Sendable {
    case imageDecode(assetId: String)
    case videoNotPlayable(assetId: String)
    case videoTrackMissing(assetId: String)
    case videoFrameDecode(assetId: String, reason: String)

    public var description: String {
        switch self {
        case let .imageDecode(assetId):
            return "image decode failed asset=\(assetId)"
        case let .videoNotPlayable(assetId):
            return "video is not playable asset=\(assetId)"
        case let .videoTrackMissing(assetId):
            return "video track missing asset=\(assetId)"
        case let .videoFrameDecode(assetId, reason):
            return "video first-frame decode failed asset=\(assetId) reason=\(reason)"
        }
    }
}

public enum MediaAssetPreparer {
    public static func decodeImage(data: Data, assetId: String) throws -> CGImage {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options)
        else { throw MediaAssetPreparationError.imageDecode(assetId: assetId) }
        return image
    }

    /**
     * Proves that AVFoundation can open the authored video track and decode a
     * display-oriented frame before the scene is eligible for presentation.
     */
    public static func decodeVideoFirstFrame(url: URL, assetId: String) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable) else {
                throw MediaAssetPreparationError.videoNotPlayable(assetId: assetId)
            }
            guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                throw MediaAssetPreparationError.videoTrackMissing(assetId: assetId)
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let result = try await generator.image(at: .zero)
            return result.image
        } catch let error as MediaAssetPreparationError {
            throw error
        } catch {
            throw MediaAssetPreparationError.videoFrameDecode(assetId: assetId, reason: String(describing: error))
        }
    }
}
