import Foundation
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

/** Renders device photos for the web timeline, always as JPEG. */
enum ImageService {
    /** Thumbnail aspect-fitted into x/y (pixels); omitted means 512 on the long edge. */
    static func preview(_ asset: PHAsset, x: Int?, y: Int?) async throws -> Data {
        var w = Double(asset.pixelWidth), h = Double(asset.pixelHeight)
        guard w > 0, h > 0 else { throw AppError("Invalid image dimensions") }
        let aspect = w / h
        let (bx, by) = (x ?? 512, y ?? 512)
        if Double(bx) / Double(by) < aspect {
            w = Double(bx)
            h = Double(bx) / aspect
        } else {
            w = Double(by) * aspect
            h = Double(by)
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let image: UIImage = try await withCheckedThrowingContinuation { cont in
            let once = Once()
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: max(w, 1), height: max(h, 1)),
                                                  contentMode: .aspectFit, options: options) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                guard once.claim() else { return }
                if let image { cont.resume(returning: image) } else { cont.resume(throwing: AppError("Preview failed")) }
            }
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else { throw AppError("JPEG encoding failed") }
        return data
    }

    /** Full image, downscaled only (never upscaled) to fit [size] on the long edge. */
    static func full(_ asset: PHAsset, size: Int?) async throws -> Data {
        let (data, uti) = try await imageData(asset)
        if size == nil, uti.flatMap({ UTType($0) })?.conforms(to: .jpeg) == true { return data }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw AppError("Unreadable image") }
        let longEdge = max(asset.pixelWidth, asset.pixelHeight)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(size ?? longEdge, longEdge),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw AppError("Decode failed") }
        return try jpeg(cg)
    }

    /** ImageIO properties (EXIF/TIFF/GPS) of the original file. */
    static func properties(_ asset: PHAsset) async -> [String: Any]? {
        guard let result = try? await imageData(asset),
              let src = CGImageSourceCreateWithData(result.data as CFData, nil)
        else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
    }

    private static func imageData(_ asset: PHAsset) async throws -> (data: Data, uti: String?) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        return try await withCheckedThrowingContinuation { cont in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                if let data { cont.resume(returning: (data, uti)) } else { cont.resume(throwing: AppError("Image not available")) }
            }
        }
    }

    private static func jpeg(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AppError("JPEG encoding failed")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw AppError("JPEG encoding failed") }
        return out as Data
    }
}

/** Thread-safe one-shot flag for callbacks that may fire more than once. */
final class Once {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
