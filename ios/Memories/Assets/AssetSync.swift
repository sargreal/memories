import CryptoKit
import Foundation

/**
 * Downloads and caches the web app's JS/CSS for offline serving. Only one
 * sync runs at a time; a newer describe queued mid-sync runs right after.
 */
final class AssetSync {
    static let maxParallel = 8

    private struct Download {
        let dir: URL
        let name: String
        let url: URL
        let sha256: String?
    }

    private let auth: AuthState
    private let api: NextcloudAPI
    private let cache: AssetCache
    var onError: (String) -> Void = { _ in }

    private let lock = NSLock()
    private var status = "idle"
    private var total = 0
    private var done = 0
    private var error: String?
    private var running = false
    private var pending: [String: Any]?
    private var _current: (key: String, dir: URL)?

    init(auth: AuthState, api: NextcloudAPI, cache: AssetCache) {
        self.auth = auth
        self.api = api
        self.cache = cache
    }

    /** Currently served snapshot, nil before the first sync. */
    var current: (key: String, dir: URL)? { locked { _current } }

    func progressJSON() -> [String: Any] {
        locked { ["status": status, "done": done, "total": total, "error": error ?? NSNull()] }
    }

    func latestSnapshot(_ baseUrl: String) -> (key: String, dir: URL)? { cache.latestSnapshot(baseUrl) }
    func readDescribe(_ dir: URL) -> [String: Any]? { cache.readDescribe(dir) }
    func hasSnapshot(_ baseUrl: String) -> Bool { cache.hasSnapshot(baseUrl) }

    /** describeApi with manifests; refuses manifests with a missing or invalid signature. */
    func fetchDescribe() async -> [String: Any]? {
        guard let res = try? await api.describe(manifest: true), res.status == 200, let json = res.json else { return nil }
        guard ManifestVerifier.verifyDescribe(json) else {
            onError("Asset manifest signature verification failed")
            return nil
        }
        return json
    }

    /** True when the snapshot for [fresh] is already downloaded and ready. */
    func isCurrent(_ fresh: [String: Any]) -> Bool {
        guard let base = fresh["baseUrl"] as? String, !base.isEmpty else { return false }
        let dir = cache.dirFor(base, key: cache.snapshotKey(fresh))
        guard cache.isReady(dir), let cur = cache.readDescribe(dir) else { return false }
        return !cache.changed(cur, fresh)
    }

    /** Serves the freshest snapshot, downloading first when the server has a newer one. */
    func ensureFreshAndWait(timeout: TimeInterval = 15 * 60) async -> Bool {
        guard let base = auth.baseUrl else { return false }
        guard let fresh = await fetchDescribe() else {
            guard let snap = cache.latestSnapshot(base) else {
                setState("error", error: "No connection and no offline files")
                return false
            }
            return use(snap)
        }
        if let snap = cache.latestSnapshot(base), let cur = cache.readDescribe(snap.dir), !cache.changed(cur, fresh) {
            return use(snap)
        }
        guard await syncAndAwait(fresh, timeout: timeout) else { return false }
        let key = cache.snapshotKey(fresh)
        return use((key, cache.dirFor(base, key: key)))
    }

    private func use(_ snap: (key: String, dir: URL)) -> Bool {
        locked {
            _current = snap
            status = "ready"
        }
        return true
    }

    /** Queues a sync and waits until it finishes; true only when [fresh] is ready to serve. */
    func syncAndAwait(_ fresh: [String: Any], timeout: TimeInterval) async -> Bool {
        sync(fresh)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (status, running) = locked { (self.status, self.running) }
            if status == "ready" && !running { return true }
            if (status == "error" || status == "idle") && !running { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    /** Queues [describe] for download; coalesces with a sync already running. */
    func sync(_ describe: [String: Any]) {
        let start: Bool = locked {
            pending = describe
            // Mark synchronously: a waiter must not mistake a previous "ready" for this sync.
            status = "downloading"
            if running { return false }
            running = true
            return true
        }
        guard start else { return }
        Task.detached { [self] in
            while let next: [String: Any] = locked({ defer { pending = nil }; return pending }) {
                if !(await syncOne(next)) { break }
            }
            locked { running = false }
        }
    }

    private func syncOne(_ describe: [String: Any]) async -> Bool {
        do {
            guard let baseUrl = describe["baseUrl"] as? String else { throw AppError("describe has no baseUrl") }
            let key = cache.snapshotKey(describe)
            let dir = cache.dirFor(baseUrl, key: key)
            if cache.isReady(dir), let existing = cache.readDescribe(dir), !cache.changed(existing, describe) {
                cache.pruneExcept(baseUrl, keepKey: key)
                setState("ready")
                return true
            }
            try await syncBlocking(describe, baseUrl: baseUrl, dir: dir)
            cache.pruneExcept(baseUrl, keepKey: key)
            setState("ready")
            return true
        } catch {
            log.warning("Asset sync failed: \(error.localizedDescription)")
            setState("error", error: error.localizedDescription)
            return false
        }
    }

    private func syncBlocking(_ describe: [String: Any], baseUrl: String, dir: URL) async throws {
        let fm = FileManager.default
        let origin = AssetCache.originOf(baseUrl)
        let js = try parseJS(describe)
        let css = parseCSS(describe)

        // Previous snapshot to reuse unchanged files from.
        let prev = cache.latestSnapshot(baseUrl).flatMap { $0.dir.standardizedFileURL == dir.standardizedFileURL ? nil : $0 }
        let prevDescribe = prev.flatMap { cache.readDescribe($0.dir) }
        let prevHashes = prevDescribe.flatMap { d in try? parseJS(d) }.map { assets in
            Dictionary(assets.map { ($0.name, $0.hash) }, uniquingKeysWith: { a, _ in a })
        }
        let reuseCSS = prevDescribe.map { cache.cssKey($0) == cache.cssKey(describe) } ?? false

        locked {
            done = 0
            total = 0
            error = nil
            status = "downloading"
        }
        try? fm.removeItem(at: dir)
        let jsDir = dir.appendingPathComponent("js", isDirectory: true)
        let cssDir = dir.appendingPathComponent("css", isDirectory: true)
        try fm.createDirectory(at: jsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: cssDir, withIntermediateDirectories: true)

        var tasks: [Download] = []
        var reused = 0
        for asset in js {
            let prevFile = prev?.dir.appendingPathComponent("js").appendingPathComponent(asset.name)
            if let prevFile, fm.fileExists(atPath: prevFile.path), prevHashes?[asset.name] == asset.hash {
                try fm.copyItem(at: prevFile, to: jsDir.appendingPathComponent(asset.name))
                reused += 1
            } else {
                tasks.append(Download(dir: jsDir, name: asset.name, url: try absURL(origin, asset.href), sha256: asset.hash))
            }
        }
        for asset in css {
            // CSS has no content hash, so reuse only when the whole manifest is unchanged.
            let prevFile = prev?.dir.appendingPathComponent("css").appendingPathComponent(asset.name)
            if reuseCSS, let prevFile, fm.fileExists(atPath: prevFile.path) {
                try fm.copyItem(at: prevFile, to: cssDir.appendingPathComponent(asset.name))
                reused += 1
            } else {
                tasks.append(Download(dir: cssDir, name: asset.name, url: try absURL(origin, asset.href), sha256: nil))
            }
        }
        locked { total = tasks.count }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var queue = tasks.makeIterator()
            for _ in 0..<AssetSync.maxParallel {
                guard let t = queue.next() else { break }
                group.addTask { try await self.download(t) }
            }
            while try await group.next() != nil {
                locked { done += 1 }
                if let t = queue.next() { group.addTask { try await self.download(t) } }
            }
        }

        let data = try JSONSerialization.data(withJSONObject: describe)
        try data.write(to: dir.appendingPathComponent("describe.json"))
        _ = fm.createFile(atPath: dir.appendingPathComponent(".ready").path, contents: Data())
        log.info("Asset sync complete: \(tasks.count) downloaded, \(reused) reused for \(origin)")
    }

    /** Downloads one asset, verifying its SHA-256 first, and stores it atomically. */
    private func download(_ t: Download) async throws {
        let bytes = try await api.downloadBytes(t.url)
        if let expected = t.sha256 {
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw AppError("SHA-256 mismatch for \(t.name)")
            }
        }
        try bytes.write(to: t.dir.appendingPathComponent(t.name), options: .atomic)
    }

    private func parseJS(_ describe: [String: Any]) throws -> [(name: String, hash: String, href: String)] {
        guard let targets = ManifestVerifier.targets(describe) else { throw AppError("Server has no asset manifest") }
        return targets.compactMap { name, value in
            guard name.hasSuffix(".js") || name.hasSuffix(".mjs"),
                  let o = value as? [String: Any],
                  let hash = (o["hashes"] as? [String: Any])?["sha256"] as? String, !hash.isEmpty,
                  let href = (o["custom"] as? [String: Any])?["href"] as? String, !href.isEmpty
            else { return nil }
            return (name, hash, href)
        }
    }

    private func parseCSS(_ describe: [String: Any]) -> [(name: String, href: String)] {
        ((describe["cssManifest"] as? [[String: Any]]) ?? []).enumerated().compactMap { i, attrs in
            (attrs["href"] as? String).map { (AssetCache.cssName(i, $0), $0) }
        }
    }

    private func absURL(_ origin: String, _ href: String) throws -> URL {
        let s = href.hasPrefix("http://") || href.hasPrefix("https://") ? href : origin + href
        guard let url = URL(string: s) else { throw AppError("Bad asset URL: \(href)") }
        return url
    }

    private func setState(_ status: String, error: String? = nil) {
        locked {
            self.status = status
            if let error { self.error = error }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
