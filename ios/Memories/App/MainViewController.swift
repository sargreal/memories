import SafariServices
import UIKit
import WebKit

/**
 * Single-screen host: owns the WebView, which only ever shows pages served
 * by the loopback server (welcome/waiting pages or the offline app shell).
 * Boot mirrors Android: welcome when logged out, the cached snapshot at once
 * when available, the waiting page while assets download.
 */
final class MainViewController: UIViewController, AppUI, WKNavigationDelegate, WKUIDelegate, SFSafariViewControllerDelegate {
    static let entryThemeColor = "#174a7d"
    private static let syncTimeout: TimeInterval = 15 * 60

    let container: AppContainer
    private var webView: WKWebView!
    private var nativex: NativeX!
    private weak var loginSheet: SFSafariViewController?
    private var statusBarDark = true
    private var themeStored = false
    private var needRefresh = false

    private var auth: AuthState { container.auth }

    init(container: AppContainer) {
        self.container = container
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var preferredStatusBarStyle: UIStatusBarStyle { statusBarDark ? .lightContent : .darkContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        container.ui.ui = self
        restoreTheme()
        setupWebView()
        container.account.refreshCredentials()
        do {
            try container.ensureServer()
        } catch {
            toast("Local server failed to start", long: true)
            return
        }
        container.startMediaSync()
        if loadDefaultApp() {
            Task.detached { [container] in await container.account.checkCredentialsAndVersion() }
        }
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = "Mobile/15E148 MemoriesNative/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"
        nativex = NativeX(container: container, host: self)
        config.userContentController.add(nativex, name: NativeX.handlerName)
        config.userContentController.addUserScript(WKUserScript(source: NativeX.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        #endif

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: Lifecycle

    /** Restarts the listener after a suspension and replays a refresh deferred in the background. */
    func onForeground() {
        do {
            try container.ensureServer()
        } catch {
            toast("Local server failed to restart", long: true)
        }
        if needRefresh { timelineChanged() }
    }

    // MARK: Boot (see AppStartupCoordinator on Android)

    func loadDefault() {
        _ = loadDefaultApp()
    }

    /** Loads the app when logged in, else the welcome page. True when the app was started. */
    @discardableResult
    private func loadDefaultApp() -> Bool {
        if auth.baseUrl != nil && auth.isLoggedIn {
            startLocalApp(toNxSetup: false)
            return true
        }
        loadStatic("welcome.html", entryTheme: true)
        return false
    }

    /** Cached snapshot loads at once with a background update check; otherwise the waiting page blocks. */
    func startLocalApp(toNxSetup: Bool) {
        guard let base = auth.baseUrl else { return }
        if container.assets.hasSnapshot(base) && loadLocalApp(toNxSetup: toNxSetup) {
            Task { await backgroundUpdateCheck(toNxSetup: toNxSetup) }
        } else {
            loadStatic("waiting.html", entryTheme: true)
            Task {
                let ok = await container.assets.ensureFreshAndWait()
                if !ok || !loadLocalApp(toNxSetup: toNxSetup) { toast("Could not load offline files", long: true) }
            }
        }
    }

    private func backgroundUpdateCheck(toNxSetup: Bool) async {
        let assets = container.assets
        guard let fresh = await assets.fetchDescribe(), !assets.isCurrent(fresh) else { return }
        log.info("Assets changed, updating in foreground")
        loadStatic("waiting.html", entryTheme: true)
        guard await assets.syncAndAwait(fresh, timeout: MainViewController.syncTimeout), loadLocalApp(toNxSetup: toNxSetup) else {
            toast("Update failed", long: true)
            return
        }
    }

    /** Serves the snapshot's shell locally; API traffic is proxied upstream with basic auth. */
    @discardableResult
    private func loadLocalApp(toNxSetup: Bool) -> Bool {
        let assets = container.assets
        guard let base = auth.baseUrl,
              let snap = assets.current ?? assets.latestSnapshot(base),
              assets.readDescribe(snap.dir) != nil
        else { return false }
        let webRoot = AssetCache.webrootOf(base)
        container.router.config = ServerConfig(serverOrigin: AssetCache.originOf(base), webRoot: webRoot, assetDir: snap.dir)
        load(path: toNxSetup ? "\(webRoot)/index.php/apps/memories/nxsetup" : "\(webRoot)/")
        return true
    }

    func loadStatic(_ name: String, entryTheme: Bool) {
        if entryTheme { applyTheme(MainViewController.entryThemeColor, isDark: true) }
        load(path: "/local/static/\(name)")
    }

    /** Every top-level load goes through the auth handshake, which sets the local-auth cookie. */
    private func load(path: String) {
        webView.load(URLRequest(url: container.router.handshakeURL(next: path)))
    }

    // MARK: Theme

    /** Persists the theme once per launch while logged in, then just applies it. */
    func setThemeColor(_ color: String, isDark: Bool) {
        if !themeStored && auth.isLoggedIn {
            themeStored = true
            UserDefaults.standard.set(color, forKey: "themeColor")
            UserDefaults.standard.set(isDark, forKey: "themeDark")
        }
        applyTheme(color, isDark: isDark)
    }

    private func restoreTheme() {
        let defaults = UserDefaults.standard
        let color = defaults.string(forKey: "themeColor") ?? MainViewController.entryThemeColor
        applyTheme(color, isDark: defaults.object(forKey: "themeDark") as? Bool ?? true)
    }

    private func applyTheme(_ color: String, isDark: Bool) {
        view.backgroundColor = UIColor(css: color) ?? (isDark ? .black : .white)
        overrideUserInterfaceStyle = isDark ? .dark : .light
        statusBarDark = isDark
        setNeedsStatusBarAppearanceUpdate()
    }

    // MARK: AppUI

    func timelineChanged() {
        guard UIApplication.shared.applicationState == .active else {
            needRefresh = true
            return
        }
        needRefresh = false
        webView.evaluateJavaScript("""
            window._nc_event_bus?.emit('nativex:db:updated', null);
            window._nc_event_bus?.emit('memories:timeline:soft-refresh', null);
            """)
    }

    func toast(_ message: String, long: Bool) {
        let label = PaddedLabel()
        label.text = message
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 15)
        label.backgroundColor = UIColor(white: 0.1, alpha: 0.9)
        label.layer.cornerRadius = 18
        label.clipsToBounds = true
        label.alpha = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -64),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -48),
        ])
        UIView.animate(withDuration: 0.2) { label.alpha = 1 }
        UIView.animate(withDuration: 0.3, delay: long ? 3.5 : 2, options: []) { label.alpha = 0 } completion: { _ in
            label.removeFromSuperview()
        }
    }

    func presentSheet(_ vc: UIViewController) {
        if let pop = vc.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        topPresenter().present(vc, animated: true)
    }

    func presentLogin(_ url: URL) {
        dismissLogin()
        let sheet = SFSafariViewController(url: url)
        sheet.delegate = self
        sheet.dismissButtonStyle = .cancel
        loginSheet = sheet
        present(sheet, animated: true)
    }

    func dismissLogin() {
        guard let sheet = loginSheet else { return }
        loginSheet = nil
        sheet.dismiss(animated: true)
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        guard controller === loginSheet else { return }
        loginSheet = nil
        container.account.loginCancelled()
    }

    private func topPresenter() -> UIViewController {
        var top: UIViewController = self
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    // MARK: Navigation

    func isLocal(_ url: URL) -> Bool {
        (url.scheme == "http" || url.scheme == "https") && (url.host == LocalServer.host || url.host == "localhost")
    }

    /**
     * Only loopback pages load inside; proxied upstream paths and every other
     * site open in the browser. Back gestures never return to entry pages.
     */
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame ?? true, let url = action.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        if isLocal(url) {
            if action.navigationType == .backForward && url.path.hasPrefix("/local/") && auth.isLoggedIn {
                decisionHandler(.cancel)
                return
            }
            if let external = container.router.browserURL(path: url.path, query: url.query) {
                UIApplication.shared.open(external)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
            return
        }
        if ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
            UIApplication.shared.open(url)
        } else {
            log.warning("Blocked top-level navigation to \(url.scheme ?? "?"): URL")
        }
        decisionHandler(.cancel)
    }

    /** Popups never get their own window: route them like a top-level navigation. */
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            if isLocal(url) {
                if let external = container.router.browserURL(path: url.path, query: url.query) { UIApplication.shared.open(external) }
            } else if url.scheme == "http" || url.scheme == "https" {
                UIApplication.shared.open(url)
            }
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        toast("Failed to load page: \(error.localizedDescription)", long: true)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            toast("Failed to load page: HTTP \(http.statusCode)", long: true)
        }
        decisionHandler(.allow)
    }

    /** The web content process can be killed in the background; reload instead of showing a blank page. */
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadDefault()
    }

    // MARK: JS dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        topPresenter().present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        topPresenter().present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
        topPresenter().present(alert, animated: true)
    }
}

private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let s = super.intrinsicContentSize
        return CGSize(width: s.width + insets.left + insets.right, height: s.height + insets.top + insets.bottom)
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines n: Int) -> CGRect {
        let r = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: n)
        return r.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }
}

extension UIColor {
    /** Parses #rgb, #rrggbb, #rrggbbaa and rgb()/rgba() as produced by getComputedStyle. */
    convenience init?(css raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            if hex.count == 6 { hex += "ff" }
            guard hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
            self.init(red: CGFloat((v >> 24) & 0xff) / 255, green: CGFloat((v >> 16) & 0xff) / 255,
                      blue: CGFloat((v >> 8) & 0xff) / 255, alpha: CGFloat(v & 0xff) / 255)
            return
        }
        guard s.hasPrefix("rgb"), let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") else { return nil }
        let parts = s[s.index(after: open)..<close].split(whereSeparator: { ", /".contains($0) }).compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        self.init(red: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255, alpha: parts.count > 3 ? parts[3] : 1)
    }
}
