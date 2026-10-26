import Foundation

/**
 * In-process downloads with the app's own session and credentials. Loopback
 * URLs (the web app's own links) are unwrapped to the upstream server so the
 * request never needs the WebView's local-auth cookie.
 */
final class Downloader {
    private let http: HTTPClient
    private let upstream: (URL) -> URL

    init(http: HTTPClient, upstream: @escaping (URL) -> URL) {
        self.http = http
        self.upstream = upstream
    }

    /** Downloads into a fresh temp dir; the file is named from [filename] or the response. */
    func download(_ url: URL, filename: String? = nil) async throws -> URL {
        let (tmp, res) = try await http.download(http.request(upstream(url)))
        guard (200..<300).contains(res.statusCode) else {
            try? FileManager.default.removeItem(at: tmp)
            throw AppError("Download failed: HTTP \(res.statusCode)")
        }
        let name = Downloader.sanitize(filename.flatMap { $0.isEmpty ? nil : $0 }
            ?? Downloader.dispositionName(res.value(forHTTPHeaderField: "Content-Disposition"))
            ?? res.url?.lastPathComponent ?? url.lastPathComponent)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent(name)
        try FileManager.default.moveItem(at: tmp, to: target)
        return target
    }

    /** filename*=UTF-8''… wins over filename="…". */
    static func dispositionName(_ header: String?) -> String? {
        guard let header else { return nil }
        var plain: String?
        for part in header.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let lower = part.lowercased()
            if lower.hasPrefix("filename*=") {
                let value = String(part.dropFirst("filename*=".count))
                let encoded = value.components(separatedBy: "''").last ?? value
                if let decoded = encoded.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).removingPercentEncoding { return decoded }
            } else if lower.hasPrefix("filename=") {
                plain = String(part.dropFirst("filename=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return plain
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "download" : cleaned
    }
}
