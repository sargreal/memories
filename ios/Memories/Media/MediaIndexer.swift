import CryptoKit
import Foundation
import Photos
import UniformTypeIdentifiers

/**
 * Indexes the photo library into [LocalDatabase]. Every sync enumerates all
 * assets (metadata only, cheap) and reindexes just the changed ones; rows
 * not seen are pruned via the flag sweep. Library changes trigger a
 * debounced resync.
 */
final class MediaIndexer: NSObject, PHPhotoLibraryChangeObserver {
    static let allAlbumId = "all"

    private let db: LocalDatabase
    private let onChanged: () -> Void
    private let lock = NSLock()
    private var _syncStatus = -1
    private var observing = false
    private var debounce: DispatchWorkItem?
    private let queue = DispatchQueue(label: "memories.indexer", qos: .utility)

    /** Files indexed so far, or -1 when idle. Doubles as a re-entrancy guard. */
    var syncStatus: Int { lock.lock(); defer { lock.unlock() }; return _syncStatus }

    init(db: LocalDatabase, onChanged: @escaping () -> Void) {
        self.db = db
        self.onChanged = onChanged
    }

    deinit {
        if observing { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    }

    /** Starts observing and runs one sync in the background. */
    func start() {
        if !observing {
            observing = true
            PHPhotoLibrary.shared().register(self)
        }
        queue.async { [self] in
            if sync() > 0 { onChanged() }
        }
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.sync() > 0 { self.onChanged() }
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /** One full pass; returns the number of inserted, updated or removed rows. */
    @discardableResult
    func sync() -> Int {
        lock.lock()
        if _syncStatus != -1 {
            lock.unlock()
            return 0
        }
        _syncStatus = 0
        lock.unlock()
        defer { setStatus(-1) }

        guard MediaPermissions.hasLibraryAccess else { return 0 }
        do {
            let known = db.indexState()
            var changes = 0
            var seen = 0
            var ids: [String: Int64] = [:]
            try db.flagAll()

            let assets = PHAsset.fetchAssets(with: MediaIndexer.fetchOptions())
            var pending: [PHAsset] = []
            assets.enumerateObjects { asset, _, _ in pending.append(asset) }
            // Batched transactions: fast writes without starving timeline reads for the whole pass.
            for start in stride(from: 0, to: pending.count, by: 200) {
                try db.transaction {
                    for asset in pending[start..<min(start + 200, pending.count)] {
                        if let k = known[asset.localIdentifier], k.mtime == MediaIndexer.mtime(asset) {
                            try db.unflag(k.localId)
                            ids[asset.localIdentifier] = k.localId
                        } else if let photo = MediaIndexer.toPhoto(asset) {
                            try db.upsert(photo)
                            changes += 1
                        }
                        seen += 1
                    }
                }
                setStatus(seen)
            }
            changes += try db.deleteFlagged()

            // Fill ids of rows inserted during this pass.
            for (assetId, state) in db.indexState() where ids[assetId] == nil { ids[assetId] = state.localId }
            try syncAlbums(ids)
            log.info("Media sync: \(seen) assets, \(changes) changes")
            return changes
        } catch {
            log.error("Media sync failed: \(error.localizedDescription)")
            return 0
        }
    }

    private func setStatus(_ v: Int) {
        lock.lock()
        _syncStatus = v
        lock.unlock()
    }

    /** "All Photos", a few smart albums and every user album, with their members. */
    private func syncAlbums(_ ids: [String: Int64]) throws {
        var albums: [(id: String, name: String, localIds: [Int64])] = [(MediaIndexer.allAlbumId, "All Photos", [])]
        var collections: [PHAssetCollection] = []
        let smart: [PHAssetCollectionSubtype] = [.smartAlbumFavorites, .smartAlbumSelfPortraits, .smartAlbumScreenshots, .smartAlbumVideos]
        for subtype in smart {
            PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
                .enumerateObjects { c, _, _ in collections.append(c) }
        }
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            .enumerateObjects { c, _, _ in collections.append(c) }

        for c in collections {
            var members: [Int64] = []
            PHAsset.fetchAssets(in: c, options: MediaIndexer.fetchOptions()).enumerateObjects { a, _, _ in
                if let id = ids[a.localIdentifier] { members.append(id) }
            }
            if members.isEmpty { continue }
            albums.append((c.localIdentifier, c.localizedTitle ?? "Album", members))
        }
        try db.replaceAlbums(albums)
    }

    static func fetchOptions() -> PHFetchOptions {
        let o = PHFetchOptions()
        o.predicate = NSPredicate(format: "mediaType IN %@", [PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue])
        o.includeHiddenAssets = false
        return o
    }

    static func mtime(_ asset: PHAsset) -> Int64 {
        Int64(((asset.modificationDate ?? asset.creationDate)?.timeIntervalSince1970 ?? 0) * 1000)
    }

    /** Primary resource: the original photo or video file. */
    static func primaryResource(_ asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let wanted: [PHAssetResourceType] = asset.mediaType == .video ? [.video, .fullSizeVideo] : [.photo, .fullSizePhoto]
        return resources.first { wanted.contains($0.type) } ?? resources.first
    }

    static func mimeType(_ resource: PHAssetResource?, isVideo: Bool) -> String {
        resource.flatMap { UTType($0.uniformTypeIdentifier)?.preferredMIMEType } ?? (isVideo ? "video/quicktime" : "image/jpeg")
    }

    /**
     * Index row for an asset. auid/buid/dayid use the server's formulas so
     * local files match their uploaded copies; dayid is the capture day in
     * local wall-clock time.
     */
    static func toPhoto(_ asset: PHAsset) -> LocalPhoto? {
        guard let created = asset.creationDate else { return nil }
        let resource = primaryResource(asset)
        let basename = resource?.originalFilename ?? "\(asset.localIdentifier).jpg"
        let size = (resource?.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
        let isVideo = asset.mediaType == .video
        let epoch = Int64(created.timeIntervalSince1970)
        let dateTaken = epoch + Int64(TimeZone.current.secondsFromGMT(for: created))
        return LocalPhoto(
            assetId: asset.localIdentifier,
            auid: md5("\(epoch)\(size)"),
            buid: md5("\(basename)size=\(size)"),
            mtime: mtime(asset),
            dateTaken: dateTaken,
            epoch: epoch,
            dayId: Int64((Double(dateTaken) / 86400).rounded(.down)),
            basename: basename,
            mimetype: mimeType(resource, isVideo: isVideo),
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            size: size,
            isVideo: isVideo,
            duration: asset.duration
        )
    }

    private static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
