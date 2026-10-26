import Foundation

/** One parsed request from the WebView. [target] is the raw request target, never percent-decoded. */
struct HTTPRequest {
    let method: String
    let target: String
    let headers: [(name: String, value: String)]
    let body: Data

    var path: String { String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]) }

    var query: String? {
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
    }

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func queryParam(_ name: String) -> String? {
        guard let query else { return nil }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv[0] == name else { continue }
            let raw = kv.count > 1 ? String(kv[1]) : ""
            return raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
        }
        return nil
    }

    func boolParam(_ name: String) -> Bool {
        guard let v = queryParam(name)?.lowercased() else { return false }
        return v == "1" || v == "true"
    }
}

/** Byte sink of one connection; implemented over NWConnection by [LocalServer]. */
protocol ResponseSink: AnyObject {
    func send(_ data: Data) async throws
}

/**
 * Writes one response. Every connection is closed after its response, so a
 * body without a known length is simply delimited by the close.
 */
final class HTTPResponse {
    private let sink: ResponseSink
    private(set) var headSent = false

    init(sink: ResponseSink) {
        self.sink = sink
    }

    func start(status: Int, headers: [(String, String)] = [], contentLength: Int64? = nil) async throws {
        precondition(!headSent, "response head already sent")
        headSent = true
        var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
        for (name, value) in headers {
            let clean = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            head += "\(name): \(clean)\r\n"
        }
        if let contentLength { head += "Content-Length: \(contentLength)\r\n" }
        head += "Connection: close\r\n\r\n"
        try await sink.send(Data(head.utf8))
    }

    func write(_ data: Data) async throws {
        if !data.isEmpty { try await sink.send(data) }
    }

    func send(status: Int, contentType: String?, body: Data = Data(), headers: [(String, String)] = []) async throws {
        var all = headers
        if let contentType { all.append(("Content-Type", contentType)) }
        try await start(status: status, headers: all, contentLength: Int64(body.count))
        try await write(body)
    }

    func plain(_ status: Int, _ text: String) async throws {
        try await send(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 207: return "Multi-Status"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 303: return "See Other"
        case 304: return "Not Modified"
        case 307: return "Temporary Redirect"
        case 308: return "Permanent Redirect"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 412: return "Precondition Failed"
        case 413: return "Payload Too Large"
        case 416: return "Range Not Satisfiable"
        case 423: return "Locked"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        case 507: return "Insufficient Storage"
        default: return "Status"
        }
    }
}

/** Incremental HTTP/1.1 request head + Content-Length body parser. */
struct HTTPRequestParser {
    static let maxHeadBytes = 64 * 1024

    enum ParseError: Error {
        case headTooLarge, malformed, chunkedUnsupported
    }

    private var buffer = Data()

    /** Feeds bytes; returns a request once the head and the whole body arrived. */
    mutating func feed(_ data: Data) throws -> HTTPRequest? {
        buffer.append(data)
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > HTTPRequestParser.maxHeadBytes { throw ParseError.headTooLarge }
            return nil
        }
        guard let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else {
            throw ParseError.malformed
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { throw ParseError.malformed }

        var headers: [(name: String, value: String)] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.malformed }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        let te = headers.first { $0.name.lowercased() == "transfer-encoding" }?.value.lowercased()
        if let te, te.contains("chunked") { throw ParseError.chunkedUnsupported }
        let lengthHeader = headers.first { $0.name.lowercased() == "content-length" }?.value
        let length = Int(lengthHeader ?? "0") ?? 0
        guard length >= 0 else { throw ParseError.malformed }

        let bodyStart = headEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return nil }
        let body = buffer.subdata(in: bodyStart..<(bodyStart + length))
        return HTTPRequest(method: requestLine[0].uppercased(), target: String(requestLine[1]), headers: headers, body: body)
    }
}

/** Single-range bytes=start-end, bytes=start-, bytes=-suffix. Nil when unsatisfiable. */
func parseByteRange(_ header: String, total: Int64) -> ClosedRange<Int64>? {
    let v = header.trimmingCharacters(in: .whitespaces).lowercased()
    guard v.hasPrefix("bytes=") else { return nil }
    guard let spec = v.dropFirst(6).split(separator: ",").first?.trimmingCharacters(in: .whitespaces) else { return nil }
    if spec.hasPrefix("-") {
        guard let suffix = Int64(spec.dropFirst()), suffix > 0 else { return nil }
        return max(total - suffix, 0)...(total - 1)
    }
    let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, let start = Int64(parts[0]) else { return nil }
    let end = parts[1].isEmpty ? total - 1 : (Int64(parts[1]) ?? -1)
    guard start >= 0, end >= start, start < total else { return nil }
    return start...min(end, total - 1)
}
