import Foundation

/** Forwards non-local requests to Nextcloud with stored basic auth, streaming the response back. */
final class ProxyController {
    /** Hop-by-hop and client-specific headers that must not be forwarded upstream. */
    private static let skippedRequestHeaders: Set<String> = [
        "host", "content-length", "transfer-encoding", "connection",
        "cookie", "accept-encoding", "expect", "authorization",
    ]

    /** Framing and session headers regenerated locally (URLSession already decoded the body). */
    private static let skippedResponseHeaders: Set<String> = [
        "content-encoding", "transfer-encoding", "content-length",
        "connection", "keep-alive", "set-cookie",
    ]

    private let auth: AuthState
    private let http: HTTPClient

    init(auth: AuthState, http: HTTPClient) {
        self.auth = auth
        self.http = http
    }

    /**
     * Proxies one request. OCS-APIREQUEST exempts it from CSRF checks, so no
     * browser session is needed. Network failures throw [UpstreamNetworkError].
     */
    func forward(_ req: HTTPRequest, _ res: HTTPResponse, config: ServerConfig, localOrigin: String) async throws {
        guard let url = URL(string: config.serverOrigin + req.target) else {
            try await res.plain(400, "bad target")
            return
        }
        var up = URLRequest(url: url, timeoutInterval: 60)
        up.httpMethod = req.method
        for (name, value) in req.headers where !ProxyController.skippedRequestHeaders.contains(name.lowercased()) {
            up.addValue(value, forHTTPHeaderField: name)
        }
        if let header = auth.authHeader { up.setValue(header, forHTTPHeaderField: "Authorization") }
        up.setValue("true", forHTTPHeaderField: "OCS-APIREQUEST")
        if !req.body.isEmpty || ["POST", "PUT", "PATCH", "PROPPATCH", "REPORT"].contains(req.method) {
            up.httpBody = req.body
        }

        let fetch = http.stream(up)
        let upstream: HTTPURLResponse
        do {
            upstream = try await fetch.response()
        } catch let e as UpstreamNetworkError {
            throw e
        } catch {
            throw UpstreamNetworkError(underlying: error)
        }

        var headers: [(String, String)] = []
        for (key, value) in upstream.allHeaderFields {
            guard let name = key as? String, let value = value as? String else { continue }
            let lower = name.lowercased()
            if ProxyController.skippedResponseHeaders.contains(lower) { continue }
            if lower == "location" {
                headers.append((name, value.hasPrefix(config.serverOrigin) ? localOrigin + value.dropFirst(config.serverOrigin.count) : value))
                continue
            }
            headers.append((name, value))
        }
        // Known length only for identity bodies: URLSession reports the encoded length otherwise.
        let encoded = upstream.value(forHTTPHeaderField: "Content-Encoding").map { $0.lowercased() != "identity" } ?? false
        let length = !encoded && upstream.expectedContentLength >= 0 ? upstream.expectedContentLength : nil

        do {
            try await res.start(status: upstream.statusCode, headers: headers, contentLength: length)
            for try await chunk in fetch.body {
                try await res.write(chunk)
                fetch.consumed(chunk.count)
            }
        } catch {
            // Upstream reset or client gone mid-stream: the connection cannot complete either way.
            fetch.cancel()
            throw UpstreamNetworkError(underlying: error)
        }
    }
}
