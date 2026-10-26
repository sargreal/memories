import Foundation
import Network

/**
 * Loopback HTTP server that serves the offline shell/assets and proxies the
 * rest to Nextcloud with stored credentials, keeping everything same-origin.
 * The port alone is not a secret, so every request must carry the
 * per-process cookie checked by [ServerRouter].
 *
 * One request per connection (Connection: close): bodies without a known
 * length are delimited by the close, which keeps framing trivial.
 */
final class LocalServer {
    static let host = "127.0.0.1"
    /** Fixed port so the WebView origin (and its storage) stays identical across launches. */
    static let fixedPort: UInt16 = 62079

    private(set) var port: UInt16 = 0
    var origin: String { "http://\(LocalServer.host):\(port)" }

    private let queue = DispatchQueue(label: "memories.server", attributes: .concurrent)
    private var listener: NWListener?
    private let handler: (HTTPRequest, HTTPResponse) async -> Void

    init(handler: @escaping (HTTPRequest, HTTPResponse) async -> Void) {
        self.handler = handler
    }

    /** Starts (or restarts after suspension) the listener; returns the bound port. */
    @discardableResult
    func ensureStarted() throws -> UInt16 {
        if let listener, listener.state == .ready { return port }
        listener?.cancel()
        listener = nil
        do {
            try start(port: port == 0 ? LocalServer.fixedPort : port)
        } catch {
            log.warning("Port \(self.port == 0 ? LocalServer.fixedPort : self.port) busy, falling back to ephemeral: \(error.localizedDescription)")
            try start(port: 0)
        }
        log.info("Listening on \(self.origin)")
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func start(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: params)

        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let err):
                failure = err
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw NSError(domain: "LocalServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener timed out"])
        }
        if let failure {
            listener.cancel()
            throw failure
        }
        // Suspension can kill the socket under a running app: rebind on the same port.
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let err) = state else { return }
            log.warning("Listener failed: \(err.localizedDescription)")
            DispatchQueue.main.async { _ = try? self?.ensureStarted() }
        }
        self.listener = listener
        self.port = listener.port?.rawValue ?? port
    }

    private func accept(_ nw: NWConnection) {
        nw.start(queue: queue)
        let conn = Connection(nw)
        Task {
            await serve(conn)
            conn.close()
        }
    }

    private func serve(_ conn: Connection) async {
        var parser = HTTPRequestParser()
        do {
            var request: HTTPRequest?
            while request == nil {
                guard let chunk = try await conn.receive() else { return }
                request = try parser.feed(chunk)
            }
            guard let request else { return }
            let response = HTTPResponse(sink: conn)
            await handler(request, response)
            if !response.headSent { try? await response.plain(500, "no response") }
        } catch HTTPRequestParser.ParseError.chunkedUnsupported {
            try? await HTTPResponse(sink: conn).plain(411, "length required")
        } catch {
            try? await HTTPResponse(sink: conn).plain(400, "bad request")
        }
    }

    /** NWConnection adapter: awaited sends give natural backpressure. */
    private final class Connection: ResponseSink {
        private let nw: NWConnection

        init(_ nw: NWConnection) {
            self.nw = nw
        }

        func receive() async throws -> Data? {
            try await withCheckedThrowingContinuation { cont in
                nw.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(returning: nil)
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
        }

        func send(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                nw.send(content: data, completion: .contentProcessed { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                })
            }
        }

        /** Flushes, then tears down; the close delimits bodies of unknown length. */
        func close() {
            let nw = self.nw
            nw.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                nw.cancel()
            })
        }
    }
}
