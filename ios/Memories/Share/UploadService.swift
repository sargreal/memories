import Foundation

/** Uploads device files to Nextcloud over WebDAV without routing bytes through the WebView. */
final class UploadService {
    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private let timeline: Timeline
    private let auth: AuthState
    private let http: HTTPClient

    init(timeline: Timeline, auth: AuthState, http: HTTPClient) {
        self.timeline = timeline
        self.auth = auth
        self.http = http
    }

    /** PUTs the device file behind [auid] to [destPath] (e.g. /Photos/IMG.jpg); returns the new fileid. */
    func upload(auid: String, destPath: String) async throws -> Int64 {
        guard let photo = timeline.photos(auids: [auid]).first, let asset = timeline.asset(photo.assetId) else {
            throw AppError("Image not found")
        }
        guard let base = auth.baseUrl, let user = auth.credentials?.user else { throw AppError("Not logged in") }
        let segments = destPath.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: UploadService.unreserved) ?? String($0) }
        guard !segments.isEmpty else { throw AppError("Invalid destination") }
        let encodedUser = user.addingPercentEncoding(withAllowedCharacters: UploadService.unreserved) ?? user
        let dav = AssetCache.originOf(base) + AssetCache.webrootOf(base) + "/remote.php/dav/files/\(encodedUser)/" + segments.joined(separator: "/")
        guard let url = URL(string: dav) else { throw AppError("Invalid destination") }

        let file = try await MediaFiles.exportOriginal(asset)
        defer { MediaFiles.cleanupTemp(file) }
        var req = http.request(url, method: "PUT")
        req.setValue(photo.mimetype, forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 24 * 3600
        let (_, res) = try await http.upload(req, fromFile: file)
        guard (200..<300).contains(res.statusCode) else { throw AppError("Upload failed: HTTP \(res.statusCode)") }
        // oc-fileid is the DAV id (zero-padded id + instance id); the numeric id is its leading digits.
        let davId = res.value(forHTTPHeaderField: "oc-fileid") ?? ""
        return Int64(String(davId.prefix { $0.isNumber })) ?? 0
    }
}
