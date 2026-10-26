import Foundation
import ImageIO
import Photos

/** Local-media timeline backing the web UI. JSON shapes must match the server API the frontend expects. */
final class Timeline {
    private static let enabledKey = "enabledLocalFolders"

    let db: LocalDatabase
    let indexer: MediaIndexer
    private let onChanged: () -> Void

    init(onChanged: @escaping () -> Void) {
        let db = LocalDatabase()
        self.db = db
        self.onChanged = onChanged
        indexer = MediaIndexer(db: db, onChanged: onChanged)
    }

    var syncStatus: Int { indexer.syncStatus }

    var enabledAlbums: [String] {
        get { UserDefaults.standard.stringArray(forKey: Timeline.enabledKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Timeline.enabledKey) }
    }

    /** Folder picker entries: {id, name, enabled}. */
    var localFolders: [[String: Any]] {
        let enabled = Set(enabledAlbums)
        return ((try? db.albums()) ?? []).map { ["id": $0.id, "name": $0.name, "enabled": enabled.contains($0.id)] }
    }

    func setLocalFolders(_ json: [[String: Any]]) {
        enabledAlbums = json.compactMap { ($0["enabled"] as? Bool) == true ? $0["id"] as? String : nil }
    }

    func days() throws -> [[String: Any]] {
        try db.days(albums: enabledAlbums).map { ["dayid": $0.dayId, "count": $0.count] }
    }

    /** One day of photos. Prunes rows whose assets vanished from the library as a side effect. */
    func day(_ dayId: Int64) throws -> [[String: Any]] {
        let photos = try db.photos(dayId: dayId, albums: enabledAlbums)
        guard !photos.isEmpty else { return [] }
        let present = existingAssetIds(photos.map(\.assetId))
        let gone = photos.filter { !present.contains($0.assetId) }
        if !gone.isEmpty {
            try db.delete(localIds: gone.map(\.localId))
            onChanged()
        }
        return photos.filter { present.contains($0.assetId) }.map { p in
            var json = Timeline.json(p)
            json["auid"] = p.auid
            json["buid"] = p.buid
            json["local_has_remote"] = p.hasRemote
            json["dayid"] = p.dayId
            return json
        }
    }

    func imageInfo(_ localId: Int64) async throws -> [String: Any] {
        guard let photo = try db.photos(localIds: [localId]).first else { throw AppError("File not found in database") }
        guard let asset = asset(photo.assetId) else { throw AppError("File not found in library") }
        var json = Timeline.json(photo)
        json["dayid"] = photo.dayId
        json["datetaken"] = photo.dateTaken
        json["permissions"] = "D"
        var exif: [String: Any] = [:]
        if !photo.isVideo, let props = await ImageService.properties(asset) {
            exif = Timeline.exifFields(props)
        }
        if let loc = asset.location {
            exif["GPSLatitude"] = loc.coordinate.latitude
            exif["GPSLongitude"] = loc.coordinate.longitude
            exif["GPSAltitude"] = loc.altitude
        }
        json["exif"] = exif
        return json
    }

    /** Deletes device files; iOS always asks the user, so confirms is always true. */
    func delete(auids: [String], dry: Bool) async throws -> [String: Any] {
        let photos = try db.photos(auids: auids)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: photos.map(\.assetId), options: nil)
        let response: [String: Any] = ["message": "ok", "count": assets.count, "confirms": true]
        if dry || assets.count == 0 { return response }
        // Throws when declined in the system prompt: nothing was deleted then.
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
        try db.delete(localIds: photos.map(\.localId))
        onChanged()
        return response
    }

    func setHasRemote(auids: [String], buids: [String], value: Bool) {
        try? db.setHasRemote(auids: auids, buids: buids, value: value)
    }

    func photos(auids: [String]) -> [LocalPhoto] {
        (try? db.photos(auids: auids)) ?? []
    }

    func photo(localId: Int64) -> LocalPhoto? {
        (try? db.photos(localIds: [localId]))?.first
    }

    func asset(_ assetId: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject
    }

    private func existingAssetIds(_ ids: [String]) -> Set<String> {
        var out = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { a, _, _ in out.insert(a.localIdentifier) }
        return out
    }

    /** Timeline JSON for a row; auid/buid/dayid are added by callers that need them. */
    static func json(_ p: LocalPhoto) -> [String: Any] {
        var json: [String: Any] = [
            "fileid": p.localId,
            "basename": p.basename,
            "mimetype": p.mimetype,
            "h": p.height,
            "w": p.width,
            "size": p.size,
            "etag": String(p.mtime),
            "epoch": p.epoch,
        ]
        if p.isVideo {
            json["isvideo"] = 1
            json["video_duration"] = Int(p.duration)
        }
        return json
    }

    /** ImageIO properties to server EXIF field names. Covers the viewer's detail panel. */
    static func exifFields(_ props: [String: Any]) -> [String: Any] {
        let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]
        var out: [String: Any] = [:]
        out["Aperture"] = exif[kCGImagePropertyExifApertureValue as String]
        out["FocalLength"] = exif[kCGImagePropertyExifFocalLength as String]
        out["FNumber"] = exif[kCGImagePropertyExifFNumber as String]
        out["ShutterSpeed"] = exif[kCGImagePropertyExifShutterSpeedValue as String]
        out["ExposureTime"] = exif[kCGImagePropertyExifExposureTime as String]
        out["ISO"] = (exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any])?.first
        out["DateTimeOriginal"] = exif[kCGImagePropertyExifDateTimeOriginal as String]
        out["OffsetTimeOriginal"] = exif[kCGImagePropertyExifOffsetTimeOriginal as String]
        out["Make"] = tiff[kCGImagePropertyTIFFMake as String]
        out["Model"] = tiff[kCGImagePropertyTIFFModel as String]
        out["Orientation"] = props[kCGImagePropertyOrientation as String]
        out["Description"] = tiff[kCGImagePropertyTIFFImageDescription as String]
        out["GPSAltitude"] = gps[kCGImagePropertyGPSAltitude as String]
        return out
    }
}
