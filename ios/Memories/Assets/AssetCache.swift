import CryptoKit
import Foundation

/**
 * On-disk snapshots of the web app (one dir per server + manifest hash).
 * A snapshot is usable only with a .ready marker. Dir names are the SHA-256
 * of the manifests, so each distinct asset set gets its own dir.
 */
final class AssetCache {
    /** Entry chunk the shell page loads; every snapshot must contain it. */
    static let entryJS = "memories-main.js"
    static let l10nJS = "memories-l10n.js"

    /** Stable local filename for the i-th stylesheet: index plus remote basename. */
    static func cssName(_ i: Int, _ href: String) -> String {
        let base = href.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? href
        return String(format: "%02d_", i) + (base.split(separator: "?", omittingEmptySubsequences: false).first.map(String.init) ?? base)
    }

    /** Scheme + host + port of a describeApi baseUrl, e.g. https://cloud.example.com. */
    static func originOf(_ baseUrl: String) -> String {
        guard let c = URLComponents(string: baseUrl), let scheme = c.scheme, let host = c.host else { return baseUrl }
        return "\(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? "")
    }

    /** Nextcloud web root (path prefix before index.php), "" for domain roots. */
    static func webrootOf(_ baseUrl: String) -> String {
        let path = URLComponents(string: baseUrl)?.percentEncodedPath ?? ""
        guard let r = path.range(of: "/index.php/") else { return path }
        return String(path[..<r.lowerBound])
    }

    private let root: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = support.appendingPathComponent("offline", isDirectory: true)
    }

    func serverDir(_ baseUrl: String) -> URL {
        let c = URLComponents(string: baseUrl)
        let raw = "\(c?.scheme ?? "")_\(c?.host ?? "")\(c?.port.map(String.init) ?? "")"
        let safe = String(raw.map { $0.isLetter || $0.isNumber || "_.-".contains($0) ? $0 : "_" })
        return root.appendingPathComponent(safe, isDirectory: true)
    }

    func dirFor(_ baseUrl: String, key: String) -> URL {
        serverDir(baseUrl).appendingPathComponent(key, isDirectory: true)
    }

    func isReady(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(".ready").path)
    }

    /** Newest usable snapshot by modification time. */
    func latestSnapshot(_ baseUrl: String) -> (key: String, dir: URL)? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: serverDir(baseUrl), includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let ready = dirs.filter { isReady($0) }
        let mtime = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        guard let best = ready.max(by: { mtime($0) < mtime($1) }) else { return nil }
        return (best.lastPathComponent, best)
    }

    func hasSnapshot(_ baseUrl: String) -> Bool {
        latestSnapshot(baseUrl) != nil
    }

    func readDescribe(_ dir: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("describe.json")) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /** Deletes every snapshot for [baseUrl] except [keepKey]. Best-effort. */
    func pruneExcept(_ baseUrl: String, keepKey: String) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: serverDir(baseUrl), includingPropertiesForKeys: nil) else { return }
        for dir in dirs where dir.lastPathComponent != keepKey {
            do {
                try fm.removeItem(at: dir)
                log.info("Pruned old snapshot: \(dir.lastPathComponent)")
            } catch {
                log.warning("Failed to prune old snapshot: \(dir.lastPathComponent)")
            }
        }
    }

    /** DSSE payload of the JS manifest: catches upstream rebuilds that keep the version number. */
    func jsKey(_ describe: [String: Any]) -> String {
        ((describe["jsManifest"] as? [String: Any])?["payload"] as? String) ?? ""
    }

    /** Hrefs of the CSS manifest, order-sensitive like the shell renderer. */
    func cssKey(_ describe: [String: Any]) -> String {
        ((describe["cssManifest"] as? [[String: Any]]) ?? []).map { ($0["href"] as? String) ?? "" }.joined(separator: "\n")
    }

    func changed(_ old: [String: Any], _ fresh: [String: Any]) -> Bool {
        jsKey(old) != jsKey(fresh) || cssKey(old) != cssKey(fresh)
    }

    /** Content address of a describe, used as the snapshot dir name. */
    func snapshotKey(_ describe: [String: Any]) -> String {
        let key = jsKey(describe) + "\n" + cssKey(describe)
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
