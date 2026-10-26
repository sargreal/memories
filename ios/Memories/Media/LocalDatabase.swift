import Foundation
import SQLite3

/** One indexed device asset. IDs follow the server: auid/buid are content-derived, dayid is the epoch day. */
struct LocalPhoto {
    var localId: Int64 = 0
    var assetId: String
    var auid: String
    var buid: String
    var mtime: Int64
    var dateTaken: Int64
    var epoch: Int64
    var dayId: Int64
    var basename: String
    var mimetype: String
    var width: Int
    var height: Int
    var size: Int64
    var isVideo: Bool
    var duration: Double
    var hasRemote: Bool = false
}

/**
 * SQLite index of device media. Photos have stable integer ids (the
 * timeline's fileid); albums are many-to-many, unlike Android buckets.
 * All access is serialized by one recursive lock.
 */
final class LocalDatabase {
    private var db: OpaquePointer?
    /** Recursive so a transaction can hold it across its statements. */
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("photos.sqlite").path
        if sqlite3_open(path, &db) != SQLITE_OK {
            log.error("Failed to open database at \(path)")
        }
        _ = try? run("PRAGMA journal_mode=WAL")
        _ = try? run("PRAGMA synchronous=NORMAL")
        let schema = [
            """
            CREATE TABLE IF NOT EXISTS photos (
              local_id INTEGER PRIMARY KEY AUTOINCREMENT,
              asset_id TEXT NOT NULL UNIQUE,
              auid TEXT NOT NULL,
              buid TEXT NOT NULL,
              mtime INTEGER NOT NULL,
              date_taken INTEGER NOT NULL,
              epoch INTEGER NOT NULL,
              dayid INTEGER NOT NULL,
              basename TEXT NOT NULL,
              mimetype TEXT NOT NULL,
              w INTEGER NOT NULL,
              h INTEGER NOT NULL,
              size INTEGER NOT NULL,
              isvideo INTEGER NOT NULL,
              duration REAL NOT NULL,
              has_remote INTEGER NOT NULL DEFAULT 0,
              flag INTEGER NOT NULL DEFAULT 0
            )
            """,
            "CREATE INDEX IF NOT EXISTS photos_auid ON photos(auid)",
            "CREATE INDEX IF NOT EXISTS photos_buid ON photos(buid)",
            "CREATE INDEX IF NOT EXISTS photos_dayid ON photos(dayid)",
            "CREATE TABLE IF NOT EXISTS albums (id TEXT PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL)",
            "CREATE TABLE IF NOT EXISTS album_photos (album_id TEXT NOT NULL, local_id INTEGER NOT NULL, PRIMARY KEY (album_id, local_id))",
            "CREATE INDEX IF NOT EXISTS album_photos_local ON album_photos(local_id)",
        ]
        for sql in schema { _ = try? run(sql) }
    }

    // MARK: Photos

    /** asset_id → (local_id, mtime) for the sync diff. */
    func indexState() -> [String: (localId: Int64, mtime: Int64)] {
        var out: [String: (Int64, Int64)] = [:]
        for row in (try? query("SELECT asset_id, local_id, mtime FROM photos")) ?? [] {
            out[row.string(0)] = (row.int(1), row.int(2))
        }
        return out
    }

    /** Inserts or replaces by asset id; local_id stays stable for an asset across updates. */
    func upsert(_ p: LocalPhoto) throws {
        try run("""
            INSERT INTO photos (asset_id, auid, buid, mtime, date_taken, epoch, dayid, basename, mimetype, w, h, size, isvideo, duration, flag)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(asset_id) DO UPDATE SET
              auid=excluded.auid, buid=excluded.buid, mtime=excluded.mtime, date_taken=excluded.date_taken,
              epoch=excluded.epoch, dayid=excluded.dayid, basename=excluded.basename, mimetype=excluded.mimetype,
              w=excluded.w, h=excluded.h, size=excluded.size, isvideo=excluded.isvideo, duration=excluded.duration, flag=0
            """, [p.assetId, p.auid, p.buid, p.mtime, p.dateTaken, p.epoch, p.dayId, p.basename, p.mimetype,
                  p.width, p.height, p.size, p.isVideo, p.duration])
    }

    func flagAll() throws { try run("UPDATE photos SET flag=1") }
    func unflag(_ localId: Int64) throws { try run("UPDATE photos SET flag=0 WHERE local_id=?", [localId]) }

    /** Deletes rows unseen during the sweep; returns how many. */
    func deleteFlagged() throws -> Int {
        let n = try query("SELECT COUNT(*) FROM photos WHERE flag=1").first?.int(0) ?? 0
        try run("DELETE FROM album_photos WHERE local_id IN (SELECT local_id FROM photos WHERE flag=1)")
        try run("DELETE FROM photos WHERE flag=1")
        return Int(n)
    }

    func delete(localIds: [Int64]) throws {
        guard !localIds.isEmpty else { return }
        let list = placeholders(localIds.count)
        try run("DELETE FROM album_photos WHERE local_id IN (\(list))", localIds)
        try run("DELETE FROM photos WHERE local_id IN (\(list))", localIds)
    }

    /** Days with photos in [albums]; "all" means the whole library. */
    func days(albums: [String]) throws -> [(dayId: Int64, count: Int64)] {
        guard !albums.isEmpty else { return [] }
        let rows = albums.contains(MediaIndexer.allAlbumId)
            ? try query("SELECT dayid, COUNT(*) FROM photos GROUP BY dayid ORDER BY dayid DESC")
            : try query("""
                SELECT dayid, COUNT(*) FROM photos WHERE local_id IN
                  (SELECT local_id FROM album_photos WHERE album_id IN (\(placeholders(albums.count))))
                GROUP BY dayid ORDER BY dayid DESC
                """, albums)
        return rows.map { ($0.int(0), $0.int(1)) }
    }

    func photos(dayId: Int64, albums: [String]) throws -> [LocalPhoto] {
        guard !albums.isEmpty else { return [] }
        if albums.contains(MediaIndexer.allAlbumId) {
            return try selectPhotos("WHERE dayid=? ORDER BY date_taken DESC", [dayId])
        }
        return try selectPhotos("""
            WHERE dayid=? AND local_id IN (SELECT local_id FROM album_photos WHERE album_id IN (\(placeholders(albums.count))))
            ORDER BY date_taken DESC
            """, [dayId as Any?] + albums.map { $0 as Any? })
    }

    func photos(localIds: [Int64]) throws -> [LocalPhoto] {
        guard !localIds.isEmpty else { return [] }
        return try selectPhotos("WHERE local_id IN (\(placeholders(localIds.count)))", localIds)
    }

    func photos(auids: [String]) throws -> [LocalPhoto] {
        guard !auids.isEmpty else { return [] }
        return try selectPhotos("WHERE auid IN (\(placeholders(auids.count)))", auids)
    }

    /** Marks files already on the server; either id kind may be empty. */
    func setHasRemote(auids: [String], buids: [String], value: Bool) throws {
        var conds: [String] = []
        if !auids.isEmpty { conds.append("auid IN (\(placeholders(auids.count)))") }
        if !buids.isEmpty { conds.append("buid IN (\(placeholders(buids.count)))") }
        guard !conds.isEmpty else { return }
        try run("UPDATE photos SET has_remote=? WHERE " + conds.joined(separator: " OR "), [value as Any?] + (auids + buids).map { $0 as Any? })
    }

    // MARK: Albums

    func replaceAlbums(_ albums: [(id: String, name: String, localIds: [Int64])]) throws {
        try transaction {
            try run("DELETE FROM albums")
            try run("DELETE FROM album_photos")
            for (pos, album) in albums.enumerated() {
                try run("INSERT INTO albums (id, name, position) VALUES (?, ?, ?)", [album.id, album.name, pos])
                for id in album.localIds {
                    try run("INSERT OR IGNORE INTO album_photos (album_id, local_id) VALUES (?, ?)", [album.id, id])
                }
            }
        }
    }

    func albums() throws -> [(id: String, name: String)] {
        try query("SELECT id, name FROM albums ORDER BY position").map { ($0.string(0), $0.string(1)) }
    }

    // MARK: SQLite plumbing

    struct Row {
        let values: [Any?]
        func int(_ i: Int) -> Int64 { (values[i] as? Int64) ?? Int64((values[i] as? Double) ?? 0) }
        func double(_ i: Int) -> Double { (values[i] as? Double) ?? Double((values[i] as? Int64) ?? 0) }
        func string(_ i: Int) -> String { (values[i] as? String) ?? "" }
    }

    func transaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try run("BEGIN")
        do {
            try body()
            try run("COMMIT")
        } catch {
            _ = try? run("ROLLBACK")
            throw error
        }
    }

    private func selectPhotos(_ clause: String, _ args: [Any?]) throws -> [LocalPhoto] {
        try query("""
            SELECT local_id, asset_id, auid, buid, mtime, date_taken, epoch, dayid, basename, mimetype,
                   w, h, size, isvideo, duration, has_remote FROM photos
            """ + " " + clause, args).map { r in
            LocalPhoto(localId: r.int(0), assetId: r.string(1), auid: r.string(2), buid: r.string(3), mtime: r.int(4),
                       dateTaken: r.int(5), epoch: r.int(6), dayId: r.int(7), basename: r.string(8), mimetype: r.string(9),
                       width: Int(r.int(10)), height: Int(r.int(11)), size: r.int(12), isVideo: r.int(13) != 0,
                       duration: r.double(14), hasRemote: r.int(15) != 0)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func placeholders(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }

    @discardableResult
    private func run(_ sql: String, _ args: [Any?] = []) throws -> Int {
        try locked {
            let stmt = try prepare(sql, args)
            defer { sqlite3_finalize(stmt) }
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw dbError() }
            return Int(sqlite3_changes(db))
        }
    }

    private func query(_ sql: String, _ args: [Any?] = []) throws -> [Row] {
        try locked {
            let stmt = try prepare(sql, args)
            defer { sqlite3_finalize(stmt) }
            var rows: [Row] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw dbError() }
                let n = sqlite3_column_count(stmt)
                rows.append(Row(values: (0..<n).map { i -> Any? in
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: return sqlite3_column_int64(stmt, i)
                    case SQLITE_FLOAT: return sqlite3_column_double(stmt, i)
                    case SQLITE_TEXT: return sqlite3_column_text(stmt, i).map { String(cString: $0) }
                    default: return nil
                    }
                }))
            }
            return rows
        }
    }

    private func prepare(_ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw dbError() }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case nil: sqlite3_bind_null(stmt, idx)
            case let v as Bool: sqlite3_bind_int64(stmt, idx, v ? 1 : 0)
            case let v as Int: sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Int64: sqlite3_bind_int64(stmt, idx, v)
            case let v as Double: sqlite3_bind_double(stmt, idx, v)
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, LocalDatabase.transient)
            default: sqlite3_bind_text(stmt, idx, "\(arg!)", -1, LocalDatabase.transient)
            }
        }
        return stmt
    }

    private func dbError() -> Error {
        AppError("SQLite: " + String(cString: sqlite3_errmsg(db)))
    }
}
