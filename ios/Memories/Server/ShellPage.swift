import Foundation

/** Offline equivalent of the server page: local scripts/styles plus a nonced bootstrap snippet. */
enum ShellPage {
    /** Content-Security-Policy for the shell: local pages only, API calls anywhere. */
    static func csp(nonce: String) -> String {
        [
            "default-src 'self'",
            "script-src 'self' blob: 'nonce-\(nonce)'",
            "worker-src 'self' blob:",
            "style-src 'self' 'unsafe-inline'",
            "img-src 'self' data: blob: https:",
            "media-src 'self' blob: data:",
            "connect-src 'self' https: http: wss: ws: data: blob:",
            "font-src 'self' data:",
            "frame-src 'self' https://www.openstreetmap.org",
            "object-src 'none'",
            "base-uri 'self'",
            "form-action 'self'",
            "frame-ancestors 'none'",
        ].joined(separator: "; ")
    }

    static func build(describe: [String: Any], webRoot: String, user: String?, nonce: String) -> String {
        var head = ""
        head += #"<meta charset="utf-8">"#
        head += #"<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">"#
        head += "<title>Memories</title>"
        for (i, attrs) in ((describe["cssManifest"] as? [[String: Any]]) ?? []).enumerated() {
            guard let href = attrs["href"] as? String else { continue }
            let rel = (attrs["rel"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "stylesheet"
            var tag = #"<link href="\#(attr("/local/assets/css/" + AssetCache.cssName(i, href)))" rel="\#(attr(rel))""#
            for (name, value) in attrs where name != "href" && name != "rel" && !(value is NSNull) {
                tag += #" \#(attr(name))="\#(attr("\(value)"))""#
            }
            head += tag + ">"
        }
        head += #"<link href="/local/static/shell-overrides.css" rel="stylesheet">"#
        head += #"<script src="/local/assets/js/\#(AssetCache.l10nJS)"></script>"#

        let root = jsString(webRoot)
        let bootstrap = """
        window._oc_webroot = \(root); window._oc_appswebroots = {'memories': \(root) + '/apps/memories'};
        window._oc_capabilities = {
          'files': {
            'forbidden_filename_characters': ['/', '\\\\'],
            'forbidden_filenames': ['.htaccess'],
            'forbidden_filename_basenames': [],
            'forbidden_filename_extensions': ['.part', '.filepart']
          }
        };
        """

        let userAttr = user.map { #" data-user="\#(attr($0))""# } ?? ""
        return "<!DOCTYPE html>\n<html><head\(userAttr)>\(head)</head><body>"
            + #"<div id="skip-actions"></div><div id="content"></div>"#
            + #"<script nonce="\#(nonce)">\#(bootstrap)</script>"#
            + #"<script src="/local/assets/js/\#(AssetCache.entryJS)" defer></script>"#
            + "</body></html>"
    }

    /** Single-quoted JS string literal for a trusted server path. */
    private static func jsString(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    private static func attr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
