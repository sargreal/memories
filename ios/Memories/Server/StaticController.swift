import Foundation

/** Serves bundled pages and snapshot files. All lookups are basename-only: no traversal. */
enum StaticController {
    /** Basename of the request path; replies 405/404 itself and returns nil when unusable. */
    private static func staticName(_ req: HTTPRequest, _ res: HTTPResponse) async throws -> String? {
        guard req.method == "GET" else {
            try await res.plain(405, "method")
            return nil
        }
        let name = String(req.path.split(separator: "/").last ?? "")
        guard !name.isEmpty, !name.contains("..") else {
            try await res.plain(404, "not found")
            return nil
        }
        return name
    }

    static func mime(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "json": return "application/json"
        default: return "application/octet-stream"
        }
    }

    /** Welcome/waiting pages and overrides bundled in the app. */
    static func serveBundled(_ req: HTTPRequest, _ res: HTTPResponse) async throws {
        guard let name = try await staticName(req, res) else { return }
        let ns = name as NSString
        guard let url = Bundle.main.url(forResource: ns.deletingPathExtension, withExtension: ns.pathExtension),
              let data = try? Data(contentsOf: url)
        else {
            try await res.plain(404, "not found")
            return
        }
        try await res.send(status: 200, contentType: mime(for: name), body: data, headers: [("Cache-Control", "no-store")])
    }

    /** One snapshot file (js/css), ETag-validated so repeat launches reuse the WebView cache. */
    static func serveFile(_ req: HTTPRequest, _ res: HTTPResponse, dir: URL, mime: String) async throws {
        guard let name = try await staticName(req, res) else { return }
        let file = dir.appendingPathComponent(name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let mtime = attrs[.modificationDate] as? Date
        else {
            try await res.plain(404, "not found")
            return
        }
        let etag = "\"\(String(Int64(mtime.timeIntervalSince1970 * 1000), radix: 16))-\(String(size, radix: 16))\""
        if let inm = req.header("If-None-Match"), inm.split(separator: ",").contains(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t == etag || t == "*"
        }) {
            try await res.start(status: 304, headers: [("ETag", etag)], contentLength: 0)
            return
        }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            try await res.plain(404, "not found")
            return
        }
        try await res.send(status: 200, contentType: mime, body: data, headers: [("ETag", etag), ("Cache-Control", "no-cache")])
    }
}
