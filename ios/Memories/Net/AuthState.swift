import Foundation

struct Credential: Codable {
    let url: String
    let trustAll: Bool
    let username: String
    let token: String
}

/**
 * Current server, credentials and TLS mode. Rebuilt from the keychain on
 * login/logout; read from any thread.
 */
final class AuthState {
    private let lock = NSLock()
    private var _baseUrl: String?
    private var _trustAll = false
    private var _creds: (user: String, password: String)?

    var baseUrl: String? { lock.lock(); defer { lock.unlock() }; return _baseUrl }
    var trustAll: Bool { lock.lock(); defer { lock.unlock() }; return _trustAll }
    var credentials: (user: String, password: String)? { lock.lock(); defer { lock.unlock() }; return _creds }
    var isLoggedIn: Bool { credentials != nil }

    var authHeader: String? {
        guard let c = credentials else { return nil }
        return "Basic " + Data("\(c.user):\(c.password)".utf8).base64EncodedString()
    }

    /** Points at a server; a nil url clears it. */
    func build(url: String?, trustAll: Bool) {
        lock.lock()
        _baseUrl = url
        _trustAll = trustAll
        lock.unlock()
    }

    func setCredentials(_ creds: (user: String, password: String)?) {
        lock.lock()
        _creds = creds
        lock.unlock()
    }
}
