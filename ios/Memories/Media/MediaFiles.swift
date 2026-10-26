import AVFoundation
import Foundation
import Photos

/** Original files of library assets, for video playback, uploads and sharing. */
enum MediaFiles {
    private static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("media", isDirectory: true)
    }

    /**
     * Readable file with the asset's video: the library file itself when
     * reachable, else a cached export (keyed on the modification time).
     */
    static func videoFile(_ asset: PHAsset, photo: LocalPhoto) async throws -> URL {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        let direct: URL? = await withCheckedContinuation { cont in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { av, _, _ in
                let url = (av as? AVURLAsset)?.url
                cont.resume(returning: url.flatMap { FileManager.default.isReadableFile(atPath: $0.path) ? $0 : nil })
            }
        }
        if let direct { return direct }
        let ext = (photo.basename as NSString).pathExtension
        let target = cacheDir.appendingPathComponent("\(photo.localId)-\(photo.mtime).\(ext.isEmpty ? "mov" : ext)")
        if FileManager.default.fileExists(atPath: target.path) { return target }
        return try await export(asset, to: target)
    }

    /** Copies the original resource into a fresh temp dir under its original filename. */
    static func exportOriginal(_ asset: PHAsset) async throws -> URL {
        guard let resource = MediaIndexer.primaryResource(asset) else { throw AppError("No resource for asset") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        return try await export(asset, to: dir.appendingPathComponent(resource.originalFilename))
    }

    static func cleanupTemp(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private static func export(_ asset: PHAsset, to target: URL) async throws -> URL {
        guard let resource = MediaIndexer.primaryResource(asset) else { throw AppError("No resource for asset") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = target.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await PHAssetResourceManager.default().writeData(for: resource, toFile: partial, options: options)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
        return target
    }
}
