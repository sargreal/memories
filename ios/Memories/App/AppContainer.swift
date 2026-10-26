import Foundation
import os
import UIKit

let log = Logger(subsystem: "gallery.memories", category: "Memories")

/** What services may ask of the UI. Implemented by [MainViewController]. */
@MainActor
protocol AppUI: AnyObject {
    func toast(_ message: String, long: Bool)
    func presentSheet(_ vc: UIViewController)
    func presentLogin(_ url: URL)
    func dismissLogin()
    func loadStatic(_ name: String, entryTheme: Bool)
    func loadDefault()
    func startLocalApp(toNxSetup: Bool)
    func timelineChanged()
}

/** Late-bound weak UI handle, so services can be built before the view controller exists. */
final class UIRef {
    weak var ui: AppUI?
}

/** Owns every app-scoped service and wires their dependencies. */
final class AppContainer {
    let ui: UIRef
    let auth: AuthState
    let http: HTTPClient
    let assets: AssetSync
    let timeline: Timeline
    let share: ShareService
    let account: AccountManager
    let router: ServerRouter
    let server: LocalServer

    init() {
        let ui = UIRef()
        let auth = AuthState()
        let http = HTTPClient(auth: auth)
        let api = NextcloudAPI(auth: auth, http: http)
        let assets = AssetSync(auth: auth, api: api, cache: AssetCache())
        let timeline = Timeline(onChanged: { Task { await ui.ui?.timelineChanged() } })
        let account = AccountManager(auth: auth, http: http, api: api, assets: assets, ui: ui)

        var routerRef: ServerRouter?
        let downloader = Downloader(http: http) { url in
            guard let config = routerRef?.config, url.host == LocalServer.host else { return url }
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
            c?.scheme = nil
            c?.host = nil
            c?.port = nil
            return c?.url.flatMap { URL(string: config.serverOrigin + $0.absoluteString) } ?? url
        }
        let share = ShareService(timeline: timeline, downloader: downloader, ui: ui)
        let bridge = BridgeRouter(account: account, timeline: timeline, share: share,
                                  upload: UploadService(timeline: timeline, auth: auth, http: http), assets: assets) {
            timeline.indexer.start()
        }
        let secret = UUID().uuidString
        let router = ServerRouter(secret: secret, auth: auth, assets: assets, bridge: bridge,
                                  video: VideoController(timeline: timeline), proxy: ProxyController(auth: auth, http: http))
        routerRef = router
        assets.onError = { msg in Task { await ui.ui?.toast(msg, long: true) } }

        self.ui = ui
        self.auth = auth
        self.http = http
        self.assets = assets
        self.timeline = timeline
        self.share = share
        self.account = account
        self.router = router
        server = LocalServer { req, res in await router.handle(req, res) }
    }

    /** Starts the loopback server (again after a suspension) and records its origin. */
    func ensureServer() throws {
        try server.ensureStarted()
        router.localOrigin = server.origin
    }

    /** Indexes local media when the user opted in and the OS grant exists. */
    func startMediaSync() {
        if MediaPermissions.hasMediaPermission { timeline.indexer.start() }
    }
}
