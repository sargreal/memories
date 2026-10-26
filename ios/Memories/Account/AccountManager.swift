import Foundation

/** Login (Nextcloud login flow v2 in an in-app Safari sheet), credential storage and server version checks. */
final class AccountManager {
    static let minServerVersion = "9.0.0-rc.1"

    private let auth: AuthState
    private let http: HTTPClient
    private let api: NextcloudAPI
    private let assets: AssetSync
    private let ui: UIRef

    /** Invalidates in-flight login polls on retry/cancel/logout so only the latest can transition UI. */
    private let lock = NSLock()
    private var generation = 0

    init(auth: AuthState, http: HTTPClient, api: NextcloudAPI, assets: AssetSync, ui: UIRef) {
        self.auth = auth
        self.http = http
        self.api = api
        self.assets = assets
        self.ui = ui
    }

    private func nextGeneration() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        return generation
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return gen == generation
    }

    /** Validates the server, starts a non-blocking asset sync, then opens the browser login. */
    func login(url: String, trustAll: Bool) async throws {
        do {
            _ = nextGeneration()
            auth.build(url: url, trustAll: trustAll)
            let res = try await api.describe(manifest: true)
            guard res.status == 200, let body = res.json else { throw AppError("\(url)api/describe (status \(res.status))") }
            guard ManifestVerifier.verifyDescribe(body) else { throw AppError("Asset manifest signature verification failed") }
            assets.sync(body)
            guard let baseUrl = body["baseUrl"] as? String,
                  let flowUrl = (body["loginFlowUrl"] as? String).flatMap(URL.init(string:))
            else { throw AppError("Failed to parse API description") }

            let flow = try await api.startLoginFlow(flowUrl)
            let gen = nextGeneration()
            await ui.ui?.presentLogin(flow.login)
            await ui.ui?.loadStatic("waiting.html?login=1", entryTheme: true)
            Task.detached { [self] in await poll(flow.pollEndpoint, token: flow.token, baseUrl: baseUrl, gen: gen) }
        } catch {
            await ui.ui?.toast("Error: \(error.localizedDescription)", long: true)
            throw error
        }
    }

    /** User closed the login sheet: stop polling and go back to welcome. */
    func loginCancelled() {
        _ = nextGeneration()
        Task { await ui.ui?.loadDefault() }
    }

    /** Polls every 2s for up to 5min. Success boots into setup; timeout resets to welcome. */
    private func poll(_ endpoint: URL, token: String, baseUrl: String, gen: Int) async {
        for _ in 0..<150 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard isCurrent(gen) else { return }
            do {
                guard let creds = try await api.pollLogin(endpoint, token: token) else { continue }
                guard isCurrent(gen) else { return }
                storeCredentials(url: baseUrl, user: creds.user, password: creds.password)
                await ui.ui?.dismissLogin()
                await ui.ui?.startLocalApp(toNxSetup: true)
                return
            } catch {
                // Most polls fail until the user approves in the browser; keep waiting.
                continue
            }
        }
        guard isCurrent(gen) else { return }
        await ui.ui?.dismissLogin()
        await ui.ui?.toast("Login timed out. Please try again.", long: true)
        await ui.ui?.loadDefault()
    }

    /** Revalidates stored credentials: 401 logs out, an old server warns, anything else is kept. */
    func checkCredentialsAndVersion() async {
        guard auth.isLoggedIn else { return }
        do {
            let res = try await api.describe(manifest: false)
            if res.status == 401 { return await loggedOut() }
            if res.status == 404 { return await warnOldServer() }
            guard res.status == 200, let body = res.json else {
                await ui.ui?.toast("Failed to connect to server. Reset app data if this persists.", long: true)
                return
            }
            if body["uid"] == nil || body["uid"] is NSNull { return await loggedOut() }
            if let version = body["version"] as? String, AccountManager.compareVersions(version, AccountManager.minServerVersion) < 0 {
                await warnOldServer()
            }
        } catch {
            log.warning("checkCredentialsAndVersion: \(error.localizedDescription)")
        }
    }

    private func warnOldServer() async {
        await ui.ui?.toast("Your server does not have the minimum required version of Memories", long: true)
    }

    /** Clears credentials and returns to the welcome page. */
    func loggedOut() async {
        _ = nextGeneration()
        deleteCredentials()
        await ui.ui?.dismissLogin()
        await ui.ui?.toast("Logged out from server", long: true)
        await ui.ui?.loadDefault()
    }

    func storeCredentials(url: String, user: String, password: String) {
        CredentialStore.save(Credential(url: url, trustAll: auth.trustAll, username: user, token: password))
        refreshCredentials()
    }

    func deleteCredentials() {
        CredentialStore.delete()
        http.clearCookies()
        auth.setCredentials(nil)
        auth.build(url: nil, trustAll: false)
    }

    /** Reloads stored credentials; no-op when logged out. */
    func refreshCredentials() {
        guard let cred = CredentialStore.load() else { return }
        auth.build(url: cred.url, trustAll: cred.trustAll)
        auth.setCredentials((cred.username, cred.token))
    }

    /** Numeric major.minor.patch comparison; a pre-release sorts before its release. */
    static func compareVersions(_ a: String, _ b: String) -> Int {
        func parse(_ v: String) -> ([Int], Bool) {
            let parts = v.split(separator: "-", maxSplits: 1)
            let nums = parts[0].split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
            return (nums, parts.count > 1)
        }
        let (na, pa) = parse(a), (nb, pb) = parse(b)
        for i in 0..<max(na.count, nb.count) {
            let x = i < na.count ? na[i] : 0, y = i < nb.count ? nb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        if pa != pb { return pa ? -1 : 1 }
        return 0
    }
}
