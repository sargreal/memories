import Foundation

/**
 * Maps loopback bridge paths (/api/…, /image/…) to app services. Patterns
 * must stay in sync with the @regex docs in src/native/api.ts. The
 * /api/nx/ routes back the synchronous NativeX getters (see NativeX.swift).
 */
final class BridgeRouter {
    private enum Route: String, CaseIterable {
        case login = "^/api/login/[^/]+$"
        case days = "^/api/days$"
        case day = "^/api/days/\\d+$"
        case imageInfo = "^/api/image/info/\\d+$"
        case imageDelete = "^/api/image/delete/[0-9a-f]+(,[0-9a-f]+)*$"
        case imagePreview = "^/image/preview/\\d+$"
        case imageFull = "^/image/full/[0-9a-f]+$"
        case shareUrl = "^/api/share/url/[^/]+$"
        case shareBlobs = "^/api/share/blobs$"
        case uploadLocal = "^/api/upload/local$"
        case allowMedia = "^/api/config/allow_media/\\d+$"
        case allowManageMedia = "^/api/config/allow_manage_media$"
        case assetsProgress = "^/api/assets/progress$"
        case nxFolders = "^/api/nx/folders$"
        case nxMediaPermission = "^/api/nx/media_permission$"
        case nxSyncStatus = "^/api/nx/sync_status$"
        case nxShareBlobs = "^/api/nx/share_blobs$"
        case nxLocalFolders = "^/api/nx/local_folders$"

        /** Setters carry their JSON as a POST body, so they land before any later request. */
        var method: String { self == .nxShareBlobs || self == .nxLocalFolders ? "POST" : "GET" }

        private static let compiled = Dictionary(uniqueKeysWithValues: allCases.map { ($0, try! NSRegularExpression(pattern: $0.rawValue)) })

        static func match(_ path: String) -> Route? {
            allCases.first { compiled[$0]!.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil }
        }
    }

    private let account: AccountManager
    private let timeline: Timeline
    private let share: ShareService
    private let upload: UploadService
    private let assets: AssetSync
    private let onAllowMedia: () -> Void

    init(account: AccountManager, timeline: Timeline, share: ShareService, upload: UploadService, assets: AssetSync, onAllowMedia: @escaping () -> Void) {
        self.account = account
        self.timeline = timeline
        self.share = share
        self.upload = upload
        self.assets = assets
        self.onAllowMedia = onAllowMedia
    }

    /** Bridge paths work before login; everything else goes through proxy/static/shell. */
    static func isBridge(_ path: String) -> Bool {
        path == "/api" || path.hasPrefix("/api/") || path == "/image" || path.hasPrefix("/image/")
    }

    func handle(_ req: HTTPRequest, _ res: HTTPResponse) async throws {
        var headers: [(String, String)] = [("Access-Control-Allow-Origin", "*"), ("Access-Control-Allow-Headers", "*")]
        if req.method == "OPTIONS" {
            try await res.send(status: 200, contentType: "text/plain", headers: headers)
            return
        }
        let path = req.path
        do {
            guard let route = Route.match(path) else { throw AppError("Path did not match any known API route: \(path)") }
            guard req.method == route.method else { throw AppError("Method Not Allowed") }
            let (body, mime) = try await dispatch(route, req)
            if route == .imagePreview || route == .imageFull { headers.append(("Cache-Control", "max-age=604800")) }
            try await res.send(status: 200, contentType: mime, body: body, headers: headers)
        } catch {
            log.warning("Bridge \(req.method) \(path) failed: \(error.localizedDescription)")
            try await res.send(status: 500, contentType: "application/json", body: Data("{}".utf8), headers: headers)
        }
    }

    private func dispatch(_ route: Route, _ req: HTTPRequest) async throws -> (Data, String) {
        let parts = req.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch route {
        case .login:
            try await account.login(url: decodeTwice(parts[3]), trustAll: req.boolParam("trustAll"))
            return try json(["message": "ok"])
        case .days:
            return try json(timeline.days())
        case .day:
            return try json(timeline.day(int(parts[3])))
        case .imageInfo:
            return try json(await timeline.imageInfo(int(parts[4])))
        case .imageDelete:
            let auids = parts[4].split(separator: ",").map(String.init).filter { !$0.isEmpty }
            return try json(await timeline.delete(auids: auids, dry: req.boolParam("dry")))
        case .imagePreview:
            guard let photo = timeline.photo(localId: try int(parts[3])), let asset = timeline.asset(photo.assetId) else {
                throw AppError("Image not found")
            }
            let x = req.queryParam("x").flatMap(Int.init), y = req.queryParam("y").flatMap(Int.init)
            return (try await ImageService.preview(asset, x: x, y: y), "image/jpeg")
        case .imageFull:
            guard let photo = timeline.photos(auids: [parts[3]]).first, let asset = timeline.asset(photo.assetId) else {
                throw AppError("Image not found")
            }
            return (try await ImageService.full(asset, size: req.queryParam("size").flatMap(Int.init)), "image/jpeg")
        case .uploadLocal:
            guard let auid = req.queryParam("auid"), let filename = req.queryParam("filename") else {
                throw AppError("Missing auid or filename")
            }
            return try json(["fileid": await upload.upload(auid: auid, destPath: filename)])
        case .shareUrl:
            guard let url = URL(string: try decodeTwice(parts[4])) else { throw AppError("Bad URL") }
            await share.shareURL(url)
            return try json(true)
        case .shareBlobs:
            try await share.shareBlobs()
            return try json(true)
        case .allowMedia:
            MediaPermissions.allowMedia = true
            if await MediaPermissions.request() { onAllowMedia() }
            return try json("done")
        case .allowManageMedia:
            // iOS always confirms deletions itself; there is no grant to request.
            return try json("done")
        case .assetsProgress:
            return try json(assets.progressJSON())
        case .nxFolders:
            return try json(timeline.localFolders)
        case .nxMediaPermission:
            return try json(MediaPermissions.hasMediaPermission)
        case .nxSyncStatus:
            return try json(timeline.syncStatus)
        case .nxShareBlobs:
            share.setShareBlobs(String(decoding: req.body, as: UTF8.self))
            return try json(true)
        case .nxLocalFolders:
            let folders = (try JSONSerialization.jsonObject(with: req.body) as? [[String: Any]]) ?? []
            timeline.setLocalFolders(folders)
            return try json(true)
        }
    }

    private func json(_ value: Any) throws -> (Data, String) {
        (try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), "application/json")
    }

    private func int(_ s: String) throws -> Int64 {
        guard let v = Int64(s) else { throw AppError("Bad id: \(s)") }
        return v
    }

    /** Path segments arrive double-encoded (see NAPI in src/native/api.ts). */
    private func decodeTwice(_ s: String) throws -> String {
        guard let once = s.removingPercentEncoding, let twice = once.removingPercentEncoding else { throw AppError("Bad encoding") }
        return twice
    }
}
