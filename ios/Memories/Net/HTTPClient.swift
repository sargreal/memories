import Foundation

/** Thrown when Nextcloud cannot be reached (offline, DNS, connect/timeout, reset). */
struct UpstreamNetworkError: Error {
    let underlying: Error
}

/**
 * URLSession following the current [AuthState]. Session cookies returned by
 * the first basic-auth request are kept in the shared cookie storage, which
 * turns later calls into Nextcloud's much faster session path; basic auth is
 * still sent on every call as a fallback when the session lapses.
 */
final class HTTPClient: NSObject, URLSessionDelegate {
    private let auth: AuthState
    private(set) var session: URLSession!

    init(auth: AuthState) {
        self.auth = auth
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = .shared
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 60
        cfg.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    /** Opt-in certificate bypass for self-signed home servers. Never enabled by default. */
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           auth.trustAll, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func clearCookies() {
        HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
    }

    /** Request carrying the app user agent and, when logged in, basic auth plus the CSRF exemption. */
    func request(_ url: URL, method: String = "GET", withAuth: Bool = true) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Memories", forHTTPHeaderField: "User-Agent")
        if withAuth, let header = auth.authHeader {
            req.setValue(header, forHTTPHeaderField: "Authorization")
            req.setValue("true", forHTTPHeaderField: "OCS-APIREQUEST")
        }
        return req
    }

    func data(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, res) = try await session.data(for: req)
        guard let http = res as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /** Downloads to a temporary file the caller must move or delete. */
    func download(_ req: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (file, res) = try await session.download(for: req)
        guard let http = res as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (file, http)
    }

    func upload(_ req: URLRequest, fromFile file: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, res) = try await session.upload(for: req, fromFile: file)
        guard let http = res as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    func stream(_ req: URLRequest) -> StreamingFetch {
        StreamingFetch(session: session, request: req)
    }
}

/**
 * Streams one response body as chunks without following redirects. The
 * task is suspended while too much data waits for the consumer, so large
 * videos never sit fully in memory.
 */
final class StreamingFetch: NSObject, URLSessionDataDelegate {
    private static let highWater = 8 * 1024 * 1024
    private static let lowWater = 2 * 1024 * 1024

    let body: AsyncThrowingStream<Data, Error>
    private var bodyCont: AsyncThrowingStream<Data, Error>.Continuation!
    private var responseCont: CheckedContinuation<HTTPURLResponse, Error>?
    private let task: URLSessionDataTask
    private let lock = NSLock()
    private var buffered = 0
    private var paused = false

    init(session: URLSession, request: URLRequest) {
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        body = AsyncThrowingStream { cont = $0 }
        task = session.dataTask(with: request)
        super.init()
        bodyCont = cont
        task.delegate = self
        bodyCont.onTermination = { [task] reason in
            if case .cancelled = reason { task.cancel() }
        }
    }

    /** Starts the request and waits for the response head. */
    func response() async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            responseCont = cont
            lock.unlock()
            task.resume()
        }
    }

    /** Consumer acknowledgement; resumes the transfer once the backlog drains. */
    func consumed(_ n: Int) {
        lock.lock()
        buffered -= n
        let resume = paused && buffered < StreamingFetch.lowWater
        if resume { paused = false }
        lock.unlock()
        if resume { task.resume() }
    }

    func cancel() {
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        let cont = responseCont
        responseCont = nil
        lock.unlock()
        if let http = response as? HTTPURLResponse {
            cont?.resume(returning: http)
        } else {
            cont?.resume(throwing: URLError(.badServerResponse))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffered += data.count
        let pause = !paused && buffered > StreamingFetch.highWater
        if pause { paused = true }
        lock.unlock()
        bodyCont.yield(data)
        if pause { dataTask.suspend() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = responseCont
        responseCont = nil
        lock.unlock()
        if let error {
            cont?.resume(throwing: UpstreamNetworkError(underlying: error))
            bodyCont.finish(throwing: UpstreamNetworkError(underlying: error))
        } else {
            cont?.resume(throwing: URLError(.badServerResponse))
            bodyCont.finish()
        }
    }
}
