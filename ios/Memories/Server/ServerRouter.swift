import Foundation

/** Upstream server plus the snapshot currently being served. Nil until first login. */
struct ServerConfig {
    let serverOrigin: String
    let webRoot: String
    let assetDir: URL
}

/**
 * Dispatches local-server requests to the bridge, static files, the offline
 * shell, or the upstream proxy. Paths are matched against the raw request
 * target, since routing is prefix-based and must not depend on decoding.
 */
final class ServerRouter {
    static let authPath = "/local/auth"
    private static let cookieName = "local-auth"

    private let secret: String
    private let auth: AuthState
    private let assets: AssetSync
    private let bridge: BridgeRouter
    private let video: VideoController
    private let proxy: ProxyController

    /** Set once the server is listening; redirects are rewritten onto it. */
    var localOrigin = ""

    private let lock = NSLock()
    private var _config: ServerConfig?
    var config: ServerConfig? {
        get { lock.lock(); defer { lock.unlock() }; return _config }
        set { lock.lock(); _config = newValue; lock.unlock() }
    }

    init(secret: String, auth: AuthState, assets: AssetSync, bridge: BridgeRouter, video: VideoController, proxy: ProxyController) {
        self.secret = secret
        self.auth = auth
        self.assets = assets
        self.bridge = bridge
        self.video = video
        self.proxy = proxy
    }

    /**
     * Route order matters: auth handshake, then bridge and video (work
     * unconfigured), then local files (unknown /local/ paths 404, never
     * proxied), then the shell for app routes, and finally the proxy.
     */
    func handle(_ req: HTTPRequest, _ res: HTTPResponse) async {
        let path = req.path
        do {
            if path == ServerRouter.authPath {
                try await handshake(req, res)
                return
            }
            guard authorized(req) else {
                try await res.plain(403, "forbidden")
                return
            }
            if VideoController.isVideo(path) {
                try await video.serve(req, res)
                return
            }
            if BridgeRouter.isBridge(path) {
                try await bridge.handle(req, res)
                return
            }
            if path.hasPrefix("/local/static/") {
                try await StaticController.serveBundled(req, res)
                return
            }
            let config = self.config
            if path == "/local" || path.hasPrefix("/local/") {
                if let config {
                    if path.hasPrefix("/local/assets/js/") {
                        try await StaticController.serveFile(req, res, dir: config.assetDir.appendingPathComponent("js"), mime: "text/javascript; charset=utf-8")
                        return
                    }
                    if path.hasPrefix("/local/assets/css/") {
                        try await StaticController.serveFile(req, res, dir: config.assetDir.appendingPathComponent("css"), mime: "text/css; charset=utf-8")
                        return
                    }
                }
                try await res.plain(404, "not found")
                return
            }
            if path == "/favicon.ico" {
                try await res.plain(404, "not found")
                return
            }
            guard let config else {
                try await res.plain(503, "not configured")
                return
            }
            let jsPrefixes = [config.webRoot + "/index.php/apps/memories/js/", config.webRoot + "/apps/memories/js/"]
            if req.method == "GET" && jsPrefixes.contains(where: { path.hasPrefix($0) }) {
                try await StaticController.serveFile(req, res, dir: config.assetDir.appendingPathComponent("js"), mime: "text/javascript; charset=utf-8")
                return
            }
            let appPrefix = config.webRoot + "/index.php/apps/memories"
            let isEntry = path == "/" || path == config.webRoot || path == config.webRoot + "/"
            let isAppRoute = path == appPrefix || path.hasPrefix(appPrefix + "/")
            let wantsHtml = req.header("Accept")?.contains("text/html") == true
            if req.method == "GET" && (isEntry || (isAppRoute && wantsHtml)) {
                if try await serveShell(config, res) { return }
            }
            // Only local code serves documents: never render remote content as a local page.
            if req.method == "GET" && (wantsHtml || req.header("Sec-Fetch-Dest") == "document") {
                try await res.plain(404, "not found")
                return
            }
            try await proxy.forward(req, res, config: config, localOrigin: localOrigin)
        } catch is UpstreamNetworkError {
            // Upstream offline: a native 504 is treated as offline by isNetworkError().
            if !res.headSent { try? await res.plain(504, "upstream unreachable") }
        } catch {
            log.warning("Request failed: \(path) \(error.localizedDescription)")
            if !res.headSent { try? await res.plain(500, "proxy error") }
        }
    }

    /** URL that sets the auth cookie and redirects to [next]: the only unauthenticated route. */
    func handshakeURL(next: String) -> URL {
        var c = URLComponents(string: localOrigin + ServerRouter.authPath)!
        c.queryItems = [URLQueryItem(name: "s", value: secret), URLQueryItem(name: "next", value: next)]
        return c.url!
    }

    private func handshake(_ req: HTTPRequest, _ res: HTTPResponse) async throws {
        guard req.queryParam("s") == secret else {
            try await res.plain(403, "forbidden")
            return
        }
        var next = req.queryParam("next") ?? "/"
        if !next.hasPrefix("/") || next.hasPrefix("//") { next = "/" }
        try await res.send(status: 302, contentType: "text/plain", headers: [
            ("Set-Cookie", "\(ServerRouter.cookieName)=\(secret); Path=/; HttpOnly"),
            ("Location", next),
            ("Cache-Control", "no-store"),
        ])
    }

    private func authorized(_ req: HTTPRequest) -> Bool {
        guard let cookie = req.header("Cookie") else { return false }
        return cookie.split(separator: ";").contains { $0.trimmingCharacters(in: .whitespaces) == "\(ServerRouter.cookieName)=\(secret)" }
    }

    private func serveShell(_ config: ServerConfig, _ res: HTTPResponse) async throws -> Bool {
        guard let describe = assets.readDescribe(config.assetDir) else { return false }
        let nonce = UUID().uuidString
        let html = ShellPage.build(describe: describe, webRoot: config.webRoot, user: auth.credentials?.user, nonce: nonce)
        try await res.send(status: 200, contentType: "text/html; charset=utf-8", body: Data(html.utf8), headers: [
            ("Content-Security-Policy", ShellPage.csp(nonce: nonce)),
            ("Cache-Control", "no-store"),
        ])
        return true
    }

    /**
     * Browser URL for a top-level navigation to a loopback path: local
     * documents stay inside (nil), anything else is a proxied upstream path
     * unwrapped to the origin URL. Nil when unconfigured.
     */
    func browserURL(path: String, query: String?) -> URL? {
        guard let config else { return nil }
        let p = path.isEmpty ? "/" : path
        let local = ["/local", "/api", "/image", "/video"]
        if local.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { return nil }
        if p == "/" || p == config.webRoot || p == config.webRoot + "/" || p == "/favicon.ico" { return nil }
        for prefix in [config.webRoot + "/index.php/apps/memories", config.webRoot + "/apps/memories"] {
            if p == prefix || p.hasPrefix(prefix + "/") { return nil }
        }
        return URL(string: config.serverOrigin + p + (query.map { "?\($0)" } ?? ""))
    }
}
