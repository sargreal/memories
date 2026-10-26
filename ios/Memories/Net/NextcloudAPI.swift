import Foundation

/** The few Nextcloud endpoints the app calls itself: describeApi, login flow v2 and raw downloads. */
final class NextcloudAPI {
    private let auth: AuthState
    private let http: HTTPClient

    init(auth: AuthState, http: HTTPClient) {
        self.auth = auth
        self.http = http
    }

    /** describeApi; [manifest] adds the JS/CSS asset manifests for offline sync. */
    func describe(manifest: Bool) async throws -> (json: [String: Any]?, status: Int) {
        guard let base = auth.baseUrl, let url = URL(string: base + "api/describe" + (manifest ? "?manifest=1" : "")) else {
            throw AppError("Not logged in: no server URL")
        }
        var req = http.request(url, withAuth: false)
        if let header = auth.authHeader { req.setValue(header, forHTTPHeaderField: "Authorization") }
        let (data, res) = try await http.data(req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any], res.statusCode)
    }

    /** Whole asset file; throws on non-200. */
    func downloadBytes(_ url: URL) async throws -> Data {
        let (data, res) = try await http.data(http.request(url, withAuth: false))
        guard res.statusCode == 200 else { throw AppError("HTTP \(res.statusCode) for \(url.absoluteString)") }
        return data
    }

    /** Starts login flow v2; the response carries the poll endpoint and the browser URL. */
    func startLoginFlow(_ url: URL) async throws -> (login: URL, pollEndpoint: URL, token: String) {
        var req = http.request(url, method: "POST", withAuth: false)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, res) = try await http.data(req)
        guard res.statusCode == 200 else {
            throw AppError("Login flow returned a \(res.statusCode) status code. Check your reverse proxy configuration and overwriteprotocol is correct.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let poll = json["poll"] as? [String: Any],
              let token = poll["token"] as? String,
              let endpoint = (poll["endpoint"] as? String).flatMap(URL.init(string:)),
              let login = (json["login"] as? String).flatMap(URL.init(string:))
        else { throw AppError("Failed to parse login flow response") }
        return (login, endpoint, token)
    }

    /** One poll attempt: nil while pending, credentials once approved in the browser. */
    func pollLogin(_ endpoint: URL, token: String) async throws -> (user: String, password: String)? {
        var req = http.request(endpoint, method: "POST", withAuth: false)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("token=\(token)".utf8)
        let (data, res) = try await http.data(req)
        if res.statusCode == 404 { return nil }
        guard res.statusCode == 200 else { throw AppError("poll HTTP \(res.statusCode)") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = json["loginName"] as? String,
              let password = json["appPassword"] as? String
        else { throw AppError("Failed to parse login poll response") }
        return (user, password)
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
