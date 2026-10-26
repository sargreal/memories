import UIKit
import WebKit

/**
 * Injects `window.nativex` (see the NativeX type in src/native/api.ts).
 * WKWebView has no synchronous JS → native calls, so getters use a
 * synchronous same-origin XHR against the loopback bridge (/api/nx/…), and
 * setters that later requests depend on POST synchronously too. Everything
 * else is fire-and-forget through a script message handler.
 */
@MainActor
final class NativeX: NSObject, WKScriptMessageHandler {
    static let handlerName = "nativex"

    static let script = """
    (function () {
      if (window.nativex) return;
      const post = (method, ...args) => {
        try { window.webkit.messageHandlers.\(handlerName).postMessage({ method, args }); } catch (e) {}
      };
      const xhr = (method, name, body, fallback) => {
        try {
          const x = new XMLHttpRequest();
          x.open(method, '/api/nx/' + name, false);
          if (body !== undefined) x.setRequestHeader('Content-Type', 'application/json');
          x.send(body === undefined ? null : body);
          if (x.status === 200) return JSON.parse(x.responseText);
        } catch (e) {}
        return fallback;
      };
      const str = (v) => (v === undefined || v === null ? '' : String(v));
      window.nativex = {
        isNative: () => true,
        getPlatform: () => 'ios',
        setThemeColor: (color, isDark) => post('setThemeColor', str(color).trim(), !!isDark),
        playTouchSound: () => {},
        vibrate: (duration) => post('vibrate', Number(duration) || 0),
        toast: (message, long) => post('toast', str(message), !!long),
        logout: () => post('logout'),
        reload: () => post('reload'),
        downloadFromUrl: (url, filename, title) => post('downloadFromUrl', str(url), str(filename), str(title)),
        setShareBlobs: (objects) => { xhr('POST', 'share_blobs', str(objects), null); },
        playVideo: () => {},
        playVideo2: () => {},
        destroyVideo: () => {},
        configSetLocalFolders: (json) => { xhr('POST', 'local_folders', str(json), null); },
        configGetLocalFolders: () => JSON.stringify(xhr('GET', 'folders', undefined, [])),
        configHasMediaPermission: () => !!xhr('GET', 'media_permission', undefined, false),
        getSyncStatus: () => Number(xhr('GET', 'sync_status', undefined, -1)),
        setHasRemote: (auids, buids, value) => post('setHasRemote', str(auids), str(buids), !!value),
      };
    })();
    """

    private let container: AppContainer
    private weak var host: MainViewController?

    init(container: AppContainer, host: MainViewController) {
        self.container = container
        self.host = host
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let host, let url = message.frameInfo.request.url, host.isLocal(url),
              let body = message.body as? [String: Any], let method = body["method"] as? String
        else { return }
        let args = body["args"] as? [Any] ?? []
        let str = { (i: Int) in i < args.count ? (args[i] as? String) ?? "" : "" }
        let bool = { (i: Int) in i < args.count ? (args[i] as? Bool) ?? false : false }

        switch method {
        case "setThemeColor":
            host.setThemeColor(str(0), isDark: bool(1))
        case "vibrate":
            let ms = (args.first as? NSNumber)?.doubleValue ?? 0
            if ms > 0 { UIImpactFeedbackGenerator(style: ms > 50 ? .medium : .light).impactOccurred() }
        case "toast":
            host.toast(str(0), long: bool(1))
        case "logout":
            Task { await container.account.loggedOut() }
        case "reload":
            host.loadDefault()
        case "downloadFromUrl":
            if let url = URL(string: str(0)) { container.share.downloadFromUrl(url, filename: str(1), title: str(2)) }
        case "setHasRemote":
            let parse = { (s: String) in (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String] ?? [] }
            let (auids, buids, value) = (parse(str(0)), parse(str(1)), bool(2))
            DispatchQueue.global(qos: .utility).async { [container] in
                container.timeline.setHasRemote(auids: auids, buids: buids, value: value)
            }
        default:
            log.warning("Unknown nativex call: \(method)")
        }
    }
}
