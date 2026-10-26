import Foundation

/** Streams on-device videos to the WebView's <video> element; range-aware so seeking works. */
final class VideoController {
    private static let pattern = try! NSRegularExpression(pattern: "^/video/full/\\d+$")
    private let timeline: Timeline

    init(timeline: Timeline) {
        self.timeline = timeline
    }

    static func isVideo(_ path: String) -> Bool {
        pattern.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    func serve(_ req: HTTPRequest, _ res: HTTPResponse) async throws {
        guard req.method == "GET" || req.method == "HEAD" else {
            try await res.plain(405, "method")
            return
        }
        guard let id = Int64(req.path.split(separator: "/").last ?? ""),
              let photo = timeline.photo(localId: id),
              let asset = timeline.asset(photo.assetId)
        else {
            try await res.plain(404, "not found")
            return
        }
        let file = try await MediaFiles.videoFile(asset, photo: photo)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let total = Int64(try handle.seekToEnd())
        guard total > 0 else {
            try await res.plain(500, "no size")
            return
        }

        var range: ClosedRange<Int64> = 0...(total - 1)
        var status = 200
        var headers: [(String, String)] = [("Content-Type", photo.mimetype), ("Accept-Ranges", "bytes")]
        if let header = req.header("Range") {
            guard let r = parseByteRange(header, total: total) else {
                try await res.start(status: 416, headers: [("Content-Range", "bytes */\(total)")], contentLength: 0)
                return
            }
            range = r
            status = 206
            headers.append(("Content-Range", "bytes \(r.lowerBound)-\(r.upperBound)/\(total)"))
        }
        let length = range.upperBound - range.lowerBound + 1
        try await res.start(status: status, headers: headers, contentLength: length)
        if req.method == "HEAD" { return }

        try handle.seek(toOffset: UInt64(range.lowerBound))
        var remaining = length
        while remaining > 0 {
            let chunk = handle.readData(ofLength: Int(min(remaining, 256 * 1024)))
            if chunk.isEmpty { break }
            try await res.write(chunk)
            remaining -= Int64(chunk.count)
        }
    }
}
